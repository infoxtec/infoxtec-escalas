-- Recuperação da verificação em duas etapas (decisão 128, pedido do responsável em 30/10 depois de perder o autenticador).
-- Quem perdeu o celular entra com a senha e, na tela do código, pede "Perdi meu autenticador": recebe um código de 6
-- dígitos por e-mail (o do login) ou pelo WhatsApp (cadastrado na tela Usuários). Administrador da plataforma precisa
-- dos dois. Com o código certo, a Edge Function recuperar-duas-etapas apaga o autenticador antigo e o painel pede o novo.
-- Toda recuperação avisa a pessoa e a plataforma por e-mail e fica registrada.

set lock_timeout = '5s';

-- WhatsApp de recuperação do usuário do painel (opcional; um por pessoa em cada conta)
alter table interno.conta_membros add column telefone_e164 text check (telefone_e164 ~ '^[0-9]{12,13}$');

-- códigos de recuperação e o registro das recuperações feitas (guarda de 1 ano)
create table interno.mfa_recuperacoes (
  id uuid primary key default gen_random_uuid(),
  email text not null check (email = lower(btrim(email))),
  canal text not null check (canal in ('email', 'whatsapp')),
  codigo_hash text not null,
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null,
  tentativas int not null default 0,
  usado_em timestamptz
);
alter table interno.mfa_recuperacoes enable row level security;
create index mfa_recuperacoes_email_idx on interno.mfa_recuperacoes (email, criado_em desc);

-- e-mail para um destinatário escolhido (o código vai só para a pessoa); texto sensível é apagado depois de enviado
alter table interno.alertas_email add column para text[], add column sensivel boolean not null default false;

drop function interno.fn_alerta_email(text, text);
create or replace function interno.fn_alerta_email(p_assunto text, p_texto text, p_para text[] default null,
                                                   p_sensivel boolean default false)
 returns bigint
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_url text := nullif(trim(coalesce(fn_config('alerta_email_url'), '')), '');
  v_tok text;
  v_id  bigint;
begin
  delete from alertas_email where criado_em < now() - interval '90 days';
  insert into alertas_email (assunto, texto, para, sensivel)
  values (left(p_assunto, 150), left(p_texto, 4000), p_para, coalesce(p_sensivel, false)) returning id into v_id;
  if v_url is null then return v_id; end if;
  perform pg_advisory_xact_lock(hashtext('alerta_email_token'));
  v_tok := fn_segredo('ALERTA_EMAIL_TOKEN');
  if v_tok is null then
    v_tok := encode(extensions.gen_random_bytes(32), 'hex');
    perform fn_segredo_gravar('ALERTA_EMAIL_TOKEN', v_tok);
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-alerta-token', v_tok),
    body := jsonb_build_object('id', v_id),
    timeout_milliseconds := 30000);
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION interno.fn_alerta_email_dados(p_token text, p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare a alertas_email;
begin
  if not fn_alerta_email_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into a from alertas_email where id = p_id for update;
  if not found or a.enviado_em is not null or a.tentativas >= 3 then return null; end if;
  update alertas_email set tentativas = tentativas + 1 where id = p_id;
  return jsonb_build_object(
    'assunto', a.assunto, 'texto', a.texto,
    -- destinatário escolhido (o código de recuperação vai só para a pessoa); sem ele, a plataforma
    'para', case when a.para is not null then to_jsonb(a.para) else
            (select coalesce(jsonb_agg(distinct e), '[]'::jsonb) from (
               select lower(btrim(email)) e from plataforma_admins
               union select lower(btrim(x)) from unnest(string_to_array(coalesce(fn_config('alerta_emails'), ''), ',')) x
                      where btrim(x) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') d) end,
    'smtp', jsonb_build_object('host', fn_config('alerta_smtp_host'), 'porta', fn_config('alerta_smtp_porta'),
                               'usuario', fn_config('alerta_smtp_usuario')));
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_alerta_email_resultado(p_token text, p_id bigint, p_ok boolean, p_erro text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
begin
  if not fn_alerta_email_token_ok(p_token) then raise exception 'token inválido'; end if;
  update alertas_email set enviado_em = case when p_ok then now() end, erro = case when p_ok then null else left(p_erro, 300) end
   where id = p_id and enviado_em is null;
  -- o código de recuperação não fica guardado: some do texto depois do envio ou da última tentativa
  update alertas_email set texto = '(conteúdo sensível removido depois do envio)'
   where id = p_id and sensivel and (enviado_em is not null or tentativas >= 3);
end $function$
;


-- pede um código: só quem é usuário ativo de alguma conta ou da plataforma; limites por hora e por dia
create or replace function interno.fn_mfa_recuperacao_pedir(p_email text, p_canal text)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_tels text[];
  v_conta uuid;
  v_cod text;
  v_id uuid := gen_random_uuid();
begin
  if p_canal not in ('email', 'whatsapp') then raise exception 'Escolha e-mail ou WhatsApp.'; end if;
  if not exists (select 1 from conta_membros where email = v_email and ativo)
     and not exists (select 1 from plataforma_admins where email = v_email) then
    raise exception 'Usuário sem acesso ao painel.';
  end if;
  perform pg_advisory_xact_lock(hashtext('mfa_recuperacao:' || v_email));
  delete from mfa_recuperacoes where criado_em < now() - interval '1 year';
  if (select count(*) from mfa_recuperacoes where email = v_email and criado_em > now() - interval '1 day') >= 6 then
    raise exception 'Muitos pedidos hoje. Tente amanhã ou fale com o suporte.';
  end if;
  if exists (select 1 from mfa_recuperacoes where email = v_email and canal = p_canal and criado_em > now() - interval '1 minute') then
    raise exception 'Código enviado há pouco. Aguarde um minuto.';
  end if;
  if p_canal = 'whatsapp' then
    select array_agg(distinct telefone_e164) into v_tels from conta_membros
     where email = v_email and ativo and telefone_e164 is not null;
    if v_tels is null then raise exception 'Nenhum WhatsApp cadastrado para você. Use o e-mail ou peça ao administrador.'; end if;
    if cardinality(v_tels) > 1 then raise exception 'Há mais de um WhatsApp cadastrado para você. Use o e-mail.'; end if;
    select conta_id into v_conta from conta_membros where email = v_email and ativo and telefone_e164 = v_tels[1]
     order by conta_id = '00000000-0000-0000-0000-000000000001' desc limit 1;
  end if;
  v_cod := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into mfa_recuperacoes (id, email, canal, codigo_hash, expira_em)
  values (v_id, v_email, p_canal, encode(extensions.digest(v_id::text || ':' || v_cod, 'sha256'), 'hex'), now() + interval '10 minutes');
  if p_canal = 'email' then
    perform fn_alerta_email('Trilha: código para trocar a verificação em duas etapas',
      'Seu código para trocar a verificação em duas etapas do Trilha é ' || v_cod || '. Ele vale por 10 minutos.' || E'\n\n'
      || 'Se não foi você quem pediu, ignore este e-mail e troque a sua senha: alguém pode estar tentando entrar com ela.',
      array[v_email], true);
  else
    perform fn_wa_texto_na_conta(v_conta, v_tels[1],
      '🔐 Trilha: seu código para trocar a verificação em duas etapas é *' || v_cod || '* (vale 10 minutos). '
      || 'Se não foi você, troque a sua senha.');
  end if;
  return jsonb_build_object('enviado', p_canal,
    'destino', case when p_canal = 'email' then regexp_replace(v_email, '^(.)[^@]*', '\1***')
                    else '***' || right(v_tels[1], 4) end);
end $function$;

-- confere os códigos e devolve o id do login para a Edge Function apagar o autenticador; plataforma precisa dos dois.
-- Recusa volta como {erro} (sem exceção), para a tentativa errada continuar contada
create or replace function interno.fn_mfa_recuperacao_confirmar(p_email text, p_codigo_email text, p_codigo_whatsapp text)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_plat boolean := exists (select 1 from plataforma_admins where email = v_email);
  v_ok_email boolean := false;
  v_ok_whats boolean := false;
  v_user uuid;
  v_canais text;
  v_fuso text := coalesce(fn_config('fuso'), 'America/Bahia');
begin
  perform pg_advisory_xact_lock(hashtext('mfa_recuperacao:' || v_email));
  v_ok_email := fn_mfa_codigo_ok(v_email, 'email', p_codigo_email);
  v_ok_whats := fn_mfa_codigo_ok(v_email, 'whatsapp', p_codigo_whatsapp);
  if v_plat and not (v_ok_email and v_ok_whats) then
    return jsonb_build_object('erro', 'Administrador da plataforma: confirme os dois códigos, do e-mail e do WhatsApp.');
  end if;
  if not (v_ok_email or v_ok_whats) then return jsonb_build_object('erro', 'Código errado ou vencido.'); end if;
  select id into v_user from auth.users where lower(email) = v_email limit 1;
  if v_user is null then return jsonb_build_object('erro', 'Usuário sem acesso ao painel.'); end if;
  update mfa_recuperacoes set usado_em = now()
   where email = v_email and usado_em is null and expira_em > now()
     and ((canal = 'email' and v_ok_email) or (canal = 'whatsapp' and v_ok_whats));
  v_canais := concat_ws(' e ', case when v_ok_email then 'e-mail' end, case when v_ok_whats then 'WhatsApp' end);
  -- aviso à pessoa e à plataforma: se não foi ela, dá para agir
  perform fn_alerta_email('Trilha: sua verificação em duas etapas foi trocada',
    'A verificação em duas etapas do seu login no Trilha (' || v_email || ') foi removida às '
    || to_char(now() at time zone v_fuso, 'DD/MM HH24:MI') || ', com código pelo ' || v_canais || '.' || E'\n\n'
    || 'Cadastre o aplicativo autenticador novo no próximo acesso. Se não foi você, troque a senha e avise o suporte agora.',
    array[v_email]);
  perform fn_alerta_email('Trilha: verificação em duas etapas trocada (' || left(v_email, 80) || ')',
    'O login ' || v_email || ' removeu a verificação em duas etapas às ' || to_char(now() at time zone v_fuso, 'DD/MM HH24:MI')
    || ', com código pelo ' || v_canais || '.');
  return jsonb_build_object('usuario', v_user);
end $function$;

-- um código: o último pedido ainda válido do canal; 5 tentativas erradas e ele vence
create or replace function interno.fn_mfa_codigo_ok(p_email text, p_canal text, p_codigo text)
 returns boolean
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare r mfa_recuperacoes;
begin
  if coalesce(p_codigo, '') !~ '^[0-9]{6}$' then return false; end if;
  select * into r from mfa_recuperacoes
   where email = p_email and canal = p_canal and usado_em is null and expira_em > now() and tentativas < 5
   order by criado_em desc limit 1 for update;
  if not found then return false; end if;
  if r.codigo_hash = encode(extensions.digest(r.id::text || ':' || p_codigo, 'sha256'), 'hex') then return true; end if;
  update mfa_recuperacoes set tentativas = tentativas + 1 where id = r.id;
  return false;
end $function$;


-- WhatsApp de recuperação de um usuário da conta (tela Usuários): só o administrador; a pessoa é avisada por e-mail
create or replace function public.app_definir_telefone_usuario(p_email text, p_telefone text)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator  text := app_exigir(array['admin']);
  v_conta uuid := fn_conta_atual();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_tel   text := nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), '');
  v_antes text;
begin
  if v_tel is not null and v_tel !~ '^[0-9]{12,13}$' then
    raise exception 'WhatsApp inválido: use DDI e DDD, só números. Ex: 5571981776307';
  end if;
  select telefone_e164 into v_antes from conta_membros where conta_id = v_conta and email = v_email for update;
  if not found then raise exception 'Usuário não encontrado nesta conta.'; end if;
  if v_antes is not distinct from v_tel then return; end if;
  update conta_membros set telefone_e164 = v_tel, atualizado_em = now() where conta_id = v_conta and email = v_email;
  perform fn_alerta_email('Trilha: WhatsApp de recuperação alterado',
    'O WhatsApp de recuperação da verificação em duas etapas do seu login (' || v_email || ') foi '
    || case when v_tel is null then 'removido' else 'alterado para o final ' || right(v_tel, 4) end
    || ' por ' || v_ator || '. Se você não esperava essa mudança, avise o suporte.',
    array[v_email]);
end $function$;

drop function public.app_usuarios();
CREATE OR REPLACE FUNCTION public.app_usuarios()
 RETURNS TABLE(email text, nome text, papel text, ativo boolean, criado_por text, created_at timestamp with time zone, updated_at timestamp with time zone, ve_saude boolean, rh_folhas boolean, telefone_e164 text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_conta uuid;
begin
  perform app_exigir(array['admin']);
  v_conta := fn_conta_atual();
  return query select m.email, m.nome, m.papel, m.ativo, m.criado_por, m.criado_em, m.atualizado_em, m.ve_saude, m.rh_folhas,
                      m.telefone_e164
                 from interno.conta_membros m
                where m.conta_id = v_conta
                order by coalesce(m.nome, m.email);
end $function$
;


do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  execute 'revoke execute on all functions in schema interno from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
