-- 114: "Recebi o código do meu gestor" também avisa CPF inválido e CPF não encontrado (pedido do responsável, 25/10),
-- com o mesmo freio da migration 113 (decisão 111). O freio sai de ponto_pedir_codigo para fn_ponto_cpf_aviso_liberado,
-- usado pelas duas. ponto_entrar e ponto_pedir_codigo partiram da definição da homologação (migration 113 aplicada).

-- freio dos avisos de CPF num lugar só: 3 por rede (IPv6 pelo /64) por hora e no máximo ponto_max_avisos_hora (30) no
-- total; devolve true e registra o aviso quando ainda pode avisar; sem IP, nunca
create or replace function public.fn_ponto_cpf_aviso_liberado(p_ip text)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_rede text;
begin
  begin
    v_rede := case when family(p_ip::inet) = 6 then network(set_masklen(p_ip::inet, 64))::text else host(p_ip::inet) end;
  exception when others then v_rede := null;
  end;
  if v_rede is null then return false; end if;
  perform pg_advisory_xact_lock(hashtextextended('cpf_aviso:' || v_rede, 0));
  if (select count(*) from ponto_acessos where tipo = 'cpf_aviso' and momento > now() - interval '1 hour')
       >= coalesce(fn_config_int('ponto_max_avisos_hora'), 30) then
    perform fn_ponto_alerta_teto('avisos');
    return false;
  end if;
  if (select count(*) from ponto_acessos where ip = v_rede and tipo = 'cpf_aviso'
        and momento > now() - interval '1 hour') >= 3 then
    return false;
  end if;
  insert into ponto_acessos (tipo, ip) values ('cpf_aviso', v_rede);
  return true;
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
    if fn_ponto_cpf_aviso_liberado(v_ip) then
      return jsonb_build_object('ok', false, 'mensagem', v_aviso);
    end if;
    return v_resp;
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

create or replace function public.ponto_entrar(p_cpf text, p_codigo text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_cpf    text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_codigo text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
  v_ip     text := fn_ponto_ip();
  v_tec    record;
  v_c      record;
  v_desde  timestamptz;
  v_token  text;
  v_restrito boolean := false;
  v_erro   jsonb := jsonb_build_object('erro', 'Não foi possível entrar. Confira o CPF e o código, ou peça um código novo.');
begin
  -- Teto total ou do IP estourado: só o código do gestor entra (ninguém trava a empresa inteira)
  if (select count(*) from ponto_acessos where tipo = 'entrar_erro' and momento > now() - interval '1 hour')
       >= coalesce(fn_config_int('ponto_max_erros_hora'), 300) then
    v_restrito := true;
    perform fn_ponto_alerta_teto('erros');
  end if;
  if v_ip is not null and (select count(*) from ponto_acessos where ip = v_ip and tipo = 'entrar_erro'
                            and momento > now() - interval '1 hour') >= 20 then
    v_restrito := true;
  end if;

  select t.id, t.nome, e.razao_social, e.nome_fantasia into v_tec
    from tecnicos t left join empresas e on e.id = t.empresa_id
   where fn_cpf_valido(v_cpf) and v_codigo ~ '^[0-9]{6}$' and t.cpf = v_cpf and t.ativo;
  if v_tec.id is null then
    insert into ponto_acessos (tipo, ip) values ('entrar_erro', v_ip);
    -- migration 114: os mesmos avisos do pedido de código, com o mesmo freio (decisão 111)
    if not fn_cpf_valido(v_cpf) then
      return jsonb_build_object('erro', 'CPF inválido. Confira os 11 números.');
    end if;
    if not exists (select 1 from tecnicos where cpf = v_cpf and ativo) and fn_ponto_cpf_aviso_liberado(v_ip) then
      return jsonb_build_object('erro', 'CPF não encontrado. Confira os números ou fale com o seu gestor.');
    end if;
    return v_erro;
  end if;

  -- uma tentativa por vez por funcionário: sem corrida entre requisições paralelas
  perform pg_advisory_xact_lock(hashtextextended(v_tec.id::text, 0));

  -- 10 erros na hora (contados depois do último código do gestor): só o código do gestor entra
  select max(created_at) into v_desde from ponto_codigos where tecnico_id = v_tec.id and origem = 'gestor';
  if (select count(*) from ponto_acessos where tecnico_id = v_tec.id and tipo = 'entrar_erro'
        and momento > greatest(now() - interval '1 hour', coalesce(v_desde, '-infinity'))) >= 10 then
    v_restrito := true;
  end if;

  select * into v_c from ponto_codigos
   where tecnico_id = v_tec.id and usado_em is null and expira_em > clock_timestamp() and tentativas < 5
     and codigo_hash = fn_sha256(id::text || ':' || v_codigo) and (not v_restrito or origem = 'gestor')
   order by created_at desc limit 1 for update;
  if v_c.id is null then
    -- erro gasta as tentativas só do código de WhatsApp: ninguém esgota o código do gestor de fora
    -- (ele vale 15 min e continua sob os limites por IP e total)
    update ponto_codigos set tentativas = tentativas + 1,
           expira_em = case when tentativas + 1 >= 5 then now() else expira_em end
     where tecnico_id = v_tec.id and origem = 'whatsapp' and usado_em is null and expira_em > clock_timestamp();
    insert into ponto_acessos (tipo, ip, tecnico_id) values ('entrar_erro', v_ip, v_tec.id);
    return v_erro;
  end if;

  update ponto_codigos set usado_em = now() where id = v_c.id;
  update ponto_sessoes set encerrada_em = now(), motivo = 'novo login'
   where tecnico_id = v_tec.id and encerrada_em is null;
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into ponto_sessoes (tecnico_id, token_hash, expira_em, codigo_id, criado_por, login_origem)
  values (v_tec.id, fn_sha256(v_token), now() + interval '12 hours', v_c.id, v_c.criado_por, v_c.origem);
  insert into ponto_acessos (tipo, ip, tecnico_id) values ('entrar_ok', v_ip, v_tec.id);

  return jsonb_build_object('token', v_token, 'nome', v_tec.nome,
    'empresa', coalesce(v_tec.nome_fantasia, v_tec.razao_social), 'expira_em', now() + interval '12 hours');
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
