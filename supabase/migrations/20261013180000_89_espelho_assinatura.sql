-- Migration 89 (13/10/2026): espelho de ponto mensal, parte B — envio pelo WhatsApp e assinatura do
-- funcionário (decisão 82). O gestor envia o link; o funcionário abre no app do ponto (sessão pelo CPF e
-- código), confere o espelho congelado, desenha a assinatura e confirma. A assinatura vale para AQUELA versão:
-- o hash amarra o hash do espelho, a imagem, a hora e a origem (revisão do seguranca na parte A), e o
-- funcionário só assina se o hash do que viu na tela for o da versão vigente.

insert into config (chave, valor, descricao) values
  ('app_url', 'https://infoxtec-escalas.vercel.app', 'Endereço do painel e do app do ponto, usado nos links enviados pelo WhatsApp')
on conflict (chave) do nothing;

-- Hash da assinatura: espelho + imagem + hora (UTC, microssegundos) + IP + aparelho, tudo como texto (não
-- depende da forma do jsonb, que pode mudar entre versões do Postgres)
create or replace function fn_ponto_assinatura_hash(p_sha_espelho text, p_png text, p_assinado_em timestamptz, p_origem jsonb)
returns text language sql immutable set search_path = public, extensions as $function$
  select encode(sha256(convert_to(
    p_sha_espelho || '|' || p_png || '|' || to_char(p_assinado_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    || '|' || coalesce(p_origem ->> 'ip', '') || '|' || coalesce(p_origem ->> 'aparelho', ''), 'UTF8')), 'hex')
$function$;

-- Envio do link pelo WhatsApp (painel). Sem p_espelho: os pendentes do mês. Com p_espelho: reenvia aquele,
-- mesmo já enviado (a mensagem pode não ter chegado); enviado_em guarda só o primeiro envio. Desligado não
-- recebe: não consegue entrar no app (a sessão exige funcionário ativo) e recebe o espelho em papel.
create or replace function app_ponto_enviar_espelhos(p_competencia date, p_espelho uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_url   text := rtrim(coalesce(nullif(fn_config('app_url'), ''), 'https://infoxtec-escalas.vercel.app'), '/');
  e       record;
  v_req   bigint;
  v_env   int := 0; v_sem int := 0; v_falha int := 0; v_desl int := 0;
begin
  for e in select p.id, p.enviado_em, t.nome, t.telefone_e164, t.opt_in, t.ativo, to_char(p.competencia, 'MM/YYYY') as mes
             from ponto_espelhos p join tecnicos t on t.id = p.tecnico_id
            where p.competencia = date_trunc('month', p_competencia)::date and p.substituido_em is null
              and p.assinado_em is null
              and (p.id = p_espelho or (p_espelho is null and p.enviado_em is null))
            order by t.nome
              for update of p loop
    if not e.ativo then v_desl := v_desl + 1; continue; end if;
    if not e.opt_in or e.telefone_e164 is null or not fn_pode_enviar(e.telefone_e164) then
      v_sem := v_sem + 1; continue;
    end if;
    begin
      v_req := fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', e.telefone_e164,
          'text', 'Trilha Ponto: ' || split_part(trim(e.nome), ' ', 1) || ', o seu espelho de ponto de ' || e.mes
                  || ' está pronto para conferir e assinar: ' || v_url || '/ponto?espelho=' || e.id
                  || chr(10) || 'Entre com o seu CPF e o código. Se algo estiver errado, peça o ajuste antes de assinar.'));
      -- nulo: envio barrado pela trava da homologação; o pedido ao WhatsApp é assíncrono (pg_net)
      if v_req is null then v_sem := v_sem + 1; continue; end if;
      if e.enviado_em is null then update ponto_espelhos set enviado_em = now() where id = e.id; end if;
      v_env := v_env + 1;
    exception when others then
      v_falha := v_falha + 1;
    end;
  end loop;
  return jsonb_build_object('enviados', v_env, 'sem_whatsapp', v_sem, 'falhas', v_falha, 'desligados', v_desl);
end $function$;

-- Espelho completo para o gestor (ver e imprimir com a assinatura) ---------------------------------------
create or replace function app_ponto_espelho_ver(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
declare
  v jsonb;
begin
  perform app_exigir(array['admin','gestor']);
  select jsonb_build_object('id', e.id, 'registro', e.registro, 'versao', e.versao, 'codigo', e.codigo, 'sha256', e.sha256,
           'emitido_em', e.emitido_em, 'substituido', e.substituido_em is not null, 'conteudo', e.conteudo,
           'assinado_em', e.assinado_em, 'assinatura_png', e.assinatura_png)
    into v from ponto_espelhos e where e.id = p_id;
  if v is null then raise exception 'Espelho não encontrado.'; end if;
  return v;
end $function$;

-- App do funcionário: os seus espelhos vigentes -------------------------------------------------------
-- volatile: fn_ponto_sessao grava o último uso da sessão (stable rodaria em transação só de leitura no PostgREST)
create or replace function ponto_meus_espelhos(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'competencia', to_char(e.competencia, 'MM/YYYY'),
                                     'registro', e.registro, 'assinado_em', e.assinado_em) order by e.competencia desc)
                     from ponto_espelhos e where e.tecnico_id = v_tec and e.substituido_em is null), '[]'::jsonb);
end $function$;

create or replace function ponto_meu_espelho(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
  v     jsonb;
begin
  -- só o próprio; versão substituída devolve aviso em vez do conteúdo
  select jsonb_build_object('id', e.id, 'registro', e.registro, 'versao', e.versao, 'codigo', e.codigo, 'sha256', e.sha256,
           'emitido_em', e.emitido_em, 'substituido', e.substituido_em is not null,
           'conteudo', case when e.substituido_em is null then e.conteudo end,
           'assinado_em', e.assinado_em, 'assinatura_png', e.assinatura_png)
    into v from ponto_espelhos e where e.id = p_id and e.tecnico_id = v_tec;
  if v is null then raise exception 'Espelho não encontrado.'; end if;
  return v;
end $function$;

-- App do funcionário: assinar ---------------------------------------------------------------------------
create or replace function ponto_assinar_espelho(p_token text, p_id uuid, p_sha256 text, p_assinatura text, p_ciente boolean)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_tec    uuid := fn_ponto_sessao(p_token);
  v_e      record;
  v_agora  timestamptz;
  v_origem jsonb;
begin
  if p_ciente is not true then raise exception 'Confirme que conferiu o espelho antes de assinar.'; end if;
  if p_assinatura is null or length(p_assinatura) > 300000 then raise exception 'Assinatura inválida ou grande demais: desenhe de novo.'; end if;
  -- data URL de PNG, e os bytes começam com a assinatura de arquivo PNG
  if p_assinatura !~ '^data:image/png;base64,[A-Za-z0-9+/=]+$'
     or substr(decode(split_part(p_assinatura, ',', 2), 'base64'), 1, 8) <> '\x89504e470d0a1a0a'::bytea then
    raise exception 'Assinatura inválida: desenhe de novo.';
  end if;
  select e.id, e.sha256, e.substituido_em, e.assinado_em into v_e from ponto_espelhos e
   where e.id = p_id and e.tecnico_id = v_tec for update;
  if not found then raise exception 'Espelho não encontrado.'; end if;
  if v_e.assinado_em is not null then raise exception 'Este espelho já foi assinado.'; end if;
  if v_e.substituido_em is not null or v_e.sha256 is distinct from p_sha256 then
    raise exception 'O espelho mudou depois que você abriu: abra de novo e confira antes de assinar.';
  end if;
  v_agora := now();
  v_origem := jsonb_build_object('ip', fn_ponto_ip(),
                'aparelho', left(coalesce(current_setting('request.headers', true)::jsonb ->> 'user-agent', ''), 300));
  update ponto_espelhos
     set assinado_em = v_agora, assinatura_png = p_assinatura, assinatura_origem = v_origem,
         assinatura_sha256 = fn_ponto_assinatura_hash(v_e.sha256, p_assinatura, v_agora, v_origem)
   where id = p_id;
  return jsonb_build_object('assinado_em', to_char(v_agora at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'));
end $function$;

-- Conferência pública: a assinatura confere pelo hash amarrado à versão ---------------------------------
create or replace function ponto_verificar_espelho(p_codigo text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
declare
  v record;
begin
  select e.registro, e.versao, e.competencia, e.emitido_em, e.substituido_em, e.assinado_em, e.sha256,
         e.assinatura_png, e.assinatura_sha256, e.assinatura_origem,
         encode(sha256(convert_to(e.conteudo_texto, 'UTF8')), 'hex') as sha_atual, m.razao_social, m.cnpj
    into v
    from ponto_espelhos e join empresas m on m.id = e.empresa_id
   where e.codigo = upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z2-7]', '', 'g'));
  if not found then return jsonb_build_object('encontrado', false); end if;
  return jsonb_build_object(
    'encontrado', true, 'registro', v.registro, 'versao', v.versao,
    'empresa', v.razao_social, 'cnpj', v.cnpj, 'competencia', to_char(v.competencia, 'MM/YYYY'),
    'emitido_em', to_char(v.emitido_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
    'substituido', v.substituido_em is not null,
    'integro', v.sha_atual = v.sha256,
    'assinado_em', to_char(v.assinado_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
    'assinatura_integra', case when v.assinado_em is null then null
                               else fn_ponto_assinatura_hash(v.sha256, v.assinatura_png, v.assinado_em, v.assinatura_origem)
                                    = v.assinatura_sha256 end,
    'sha256', v.sha256);
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
