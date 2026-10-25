-- 113: o pedido de código do app do ponto avisa quando o CPF não é encontrado ou o WhatsApp não foi autorizado
-- (pedido do responsável, 25/10). Antes a resposta era sempre a mesma, para ninguém descobrir quem é funcionário
-- testando CPFs; agora o aviso específico vale para as 3 primeiras respostas desse tipo por IP na última hora (IPv6
-- contado pelo bloco /64) e para no máximo `ponto_max_avisos_hora` (30) no total — depois disso, e sem IP, volta a
-- resposta única. CPF inválido é avisado sempre (não revela ninguém). Revisão do `seguranca` aplicada.
-- O aviso não traz nome, empresa nem telefone. Partiu da definição da homologação (igual à migration 55).

alter table ponto_acessos drop constraint ponto_acessos_tipo_check;
alter table ponto_acessos add constraint ponto_acessos_tipo_check
  check (tipo = any (array['pedir_codigo', 'entrar_erro', 'entrar_ok', 'cpf_aviso']));

-- alerta do teto ganha o texto dos avisos de CPF (partiu da definição da homologação)
create or replace function public.fn_ponto_alerta_teto(p_qual text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  s record;
begin
  insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
  values ('ponto_teto_' || p_qual || '_' || to_char(now() at time zone 'America/Bahia', 'HH24'),
          (now() at time zone 'America/Bahia')::date, now(), true, jsonb_build_object('teto', p_qual))
  on conflict do nothing;
  if not found then return; end if;
  raise warning 'app do ponto: teto de % por hora atingido', p_qual;
  for s in select telefone_e164 from tecnicos where is_supervisor and ativo and opt_in and not perfil_teste loop
    begin
      perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', s.telefone_e164,
          'text', case when p_qual = 'avisos'
            then 'Trilha Ponto: muitos CPFs não encontrados no app do ponto nesta hora (possível tentativa de descobrir '
                 || 'funcionários). O app voltou à resposta única até a próxima hora; o código continua chegando para quem é cadastrado.'
            else 'Trilha Ponto: o limite de ' || case when p_qual = 'erros' then 'tentativas de login'
                  else 'códigos por WhatsApp' end || ' por hora foi atingido (possível ataque). '
                  || 'Enquanto durar, o funcionário entra com o código gerado pelo gestor no painel.' end));
    exception when others then null;
    end;
  end loop;
end $function$;

create or replace function public.ponto_pedir_codigo(p_cpf text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_cpf  text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_ip   text := fn_ponto_ip();
  v_tec  record;
  v_cod  text;
  v_id   uuid := gen_random_uuid();
  v_resp jsonb := jsonb_build_object('ok', true, 'mensagem',
    'Se o CPF estiver cadastrado, você recebe o código no WhatsApp em instantes. Ele vale por 5 minutos.');
  v_aviso text;
  v_rede  text;
begin
  insert into ponto_acessos (tipo, ip) values ('pedir_codigo', v_ip);
  if v_ip is not null and (select count(*) from ponto_acessos where ip = v_ip and tipo = 'pedir_codigo'
                            and momento > now() - interval '1 hour') > 10 then
    return v_resp;
  end if;
  if (select count(*) from ponto_codigos where origem = 'whatsapp' and created_at > now() - interval '1 hour')
       >= coalesce(fn_config_int('ponto_max_codigos_hora'), 60) then
    perform fn_ponto_alerta_teto('codigos');
    return v_resp;
  end if;
  if not fn_cpf_valido(v_cpf) then
    return jsonb_build_object('ok', false, 'mensagem', 'CPF inválido. Confira os 11 números.');
  end if;
  select id, telefone_e164, opt_in into v_tec from tecnicos where cpf = v_cpf and ativo;
  if v_tec.id is null then
    v_aviso := 'CPF não encontrado. Confira os números ou fale com o seu gestor.';
  elsif not v_tec.opt_in then
    v_aviso := 'Seu WhatsApp ainda não foi autorizado para receber o código. Fale com o seu gestor.';
  end if;
  if v_aviso is not null then
    -- aviso específico só nas 3 primeiras vezes por rede na hora (IPv6 pelo /64) e até o teto geral:
    -- depois, a resposta única
    begin
      v_rede := case when family(v_ip::inet) = 6 then network(set_masklen(v_ip::inet, 64))::text else host(v_ip::inet) end;
    exception when others then v_rede := null;
    end;
    if v_rede is null then return v_resp; end if;
    perform pg_advisory_xact_lock(hashtextextended('cpf_aviso:' || v_rede, 0));
    if (select count(*) from ponto_acessos where tipo = 'cpf_aviso' and momento > now() - interval '1 hour')
         >= coalesce(fn_config_int('ponto_max_avisos_hora'), 30) then
      perform fn_ponto_alerta_teto('avisos');
      return v_resp;
    end if;
    if (select count(*) from ponto_acessos where ip = v_rede and tipo = 'cpf_aviso'
          and momento > now() - interval '1 hour') >= 3 then
      return v_resp;
    end if;
    insert into ponto_acessos (tipo, ip) values ('cpf_aviso', v_rede);
    return jsonb_build_object('ok', false, 'mensagem', v_aviso);
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_tec.id::text, 0));
  if (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
        and created_at > now() - interval '15 minutes') >= 3
     or (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
        and created_at > now() - interval '1 day') >= 6 then
    return v_resp;
  end if;

  -- só vence os códigos de WhatsApp anteriores: o código do gestor continua valendo
  update ponto_codigos set expira_em = now()
   where tecnico_id = v_tec.id and origem = 'whatsapp' and usado_em is null and expira_em > now();
  v_cod := fn_ponto_novo_codigo();
  insert into ponto_codigos (id, tecnico_id, codigo_hash, origem, expira_em)
  values (v_id, v_tec.id, fn_sha256(v_id::text || ':' || v_cod), 'whatsapp', now() + interval '5 minutes');

  begin
    perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
      jsonb_build_object('number', v_tec.telefone_e164,
        'text', 'Trilha Ponto: seu código de acesso é ' || v_cod || '. Vale por 5 minutos. Não compartilhe com ninguém.'));
  exception when others then
    -- sem Evolution (homologação) ou fora do ar: o gestor gera o código de contingência no painel
    raise warning 'ponto_pedir_codigo: envio do código falhou (%)', sqlerrm;
  end;
  return v_resp;
end $function$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
