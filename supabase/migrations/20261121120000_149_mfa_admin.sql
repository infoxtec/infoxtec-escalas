-- Migration 149 (06/11/2026): verificação em duas etapas obrigatória para administrador (B2 da sprint 04–17/11; D1,
-- decisão 131 item 7). Desenho revisado antes do código pelo seguranca e pelo arquiteto-dados (decisão 133):
--   * a regra é da PESSOA, não da conta: quem é administrador ativo de qualquer conta ativa, ou da plataforma, só usa o
--     painel com a sessão confirmada (aal2) — senha roubada de admin não vale nem como gestor de outra conta;
--   * interruptor de emergência `mfa_obrigatorio_admin` (só muda por migration aprovada; nenhuma app_* escreve em config)
--     vale só para o administrador de conta: a plataforma é sempre obrigada;
--   * a recusa leva código próprio (TRMFA), para o painel pedir o código na hora em vez de mostrar só a mensagem;
--   * gestor e leitura não mudam (continuam pelo `mfa_obrigatorio` global, hoje desligado).
-- Recriadas a partir da definição da homologação (06/11), trocando só a condição do MFA.
set lock_timeout = '5s';

insert into interno.config (chave, valor, descricao) values
  ('mfa_obrigatorio_admin', 'true',
   'Administrador de conta precisa da verificação em duas etapas (migration 149). Interruptor de emergência: só muda por migration. A plataforma é sempre obrigada.')
on conflict (chave) do nothing;

-- quem precisa da sessão confirmada (aal2): todos, se o global estiver ligado; a plataforma, sempre; o administrador ativo
-- de qualquer conta ativa, enquanto o interruptor estiver ligado. Chave primária de plataforma_admins e índice por
-- e-mail de conta_membros (migration 116).
create or replace function interno.fn_mfa_exigido(p_email text)
 returns boolean
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(interno.fn_config('mfa_obrigatorio'), 'false') = 'true'
      or exists (select 1 from interno.plataforma_admins pa where pa.email = lower(btrim(p_email)))
      or (coalesce(interno.fn_config('mfa_obrigatorio_admin'), 'true') = 'true'
          and exists (select 1 from interno.conta_membros m join interno.contas c on c.id = m.conta_id
                       where m.email = lower(btrim(p_email)) and m.ativo and m.papel = 'admin' and c.ativa))
$function$;

CREATE OR REPLACE FUNCTION public.app_exigir(p_papeis text[])
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_email();
  v_conta uuid;
begin
  if v_email is null then
    raise exception 'Sessão expirada. Entre novamente.';
  end if;
  -- quem já está em aal2 não consulta nada; o painel reconhece o código TRMFA e pede o autenticador (migration 149)
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' and interno.fn_mfa_exigido(v_email) then
    raise exception using errcode = 'TRMFA', message = 'Confirme o código do aplicativo autenticador para continuar.';
  end if;
  v_conta := interno.fn_conta_atual();
  if v_conta is null then
    raise exception 'Sem permissão para esta ação.';
  end if;
  -- papel na conta da sessão (multiempresa F2a); falta de escopo nega
  if coalesce((select m.papel from interno.conta_membros m
                where m.conta_id = v_conta and m.email = v_email and m.ativo), '') <> all (p_papeis) then
    raise exception 'Sem permissão para esta ação.';
  end if;
  return v_email;
end $function$;

CREATE OR REPLACE FUNCTION public.app_meu_acesso()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_email();
  v_conta uuid;
  m interno.conta_membros;
begin
  begin
    v_conta := interno.fn_conta_atual();
  exception when raise_exception then   -- só as recusas de fn_conta_de (sem escolha, sem acesso, inválida)
    v_conta := null;
  end;
  select * into m from interno.conta_membros where conta_id = v_conta and email = v_email and ativo;
  return jsonb_build_object(
    'email', v_email,
    'conta', v_conta,
    'papel', m.papel,
    'nome', m.nome,
    've_saude', coalesce(m.ve_saude and m.papel in ('admin', 'gestor'), false),
    'rh_folhas', coalesce(m.rh_folhas and m.papel in ('admin', 'gestor'), false),
    -- da pessoa, não da conta escolhida (migration 149): admin de qualquer conta ou plataforma
    'mfa_obrigatorio', coalesce(interno.fn_mfa_exigido(v_email), false),
    -- F3c: mostra a tela Contas (a guarda de cada função continua no banco)
    'plataforma', exists (select 1 from interno.plataforma_admins pa where pa.email = v_email),
    'contas', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'papel', cm.papel) order by c.nome)
                          from interno.conta_membros cm join interno.contas c on c.id = cm.conta_id
                         where cm.email = v_email and cm.ativo and c.ativa), '[]'::jsonb)
  );
end $function$;

-- Storage (políticas do bucket documentos usam estas duas): o aal vem primeiro, para quem está em aal2 não consultar nada
CREATE OR REPLACE FUNCTION public.app_pode_gerir_documento(p_nome text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(fn_papel_na_conta() in ('admin','gestor'), false)
     and (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' or not interno.fn_mfa_exigido(app_email()))
     and exists (select 1 from tecnicos t
                  where t.id::text = split_part(coalesce(p_nome, ''), '/', 1) and t.conta_id = fn_conta_atual())
     -- arquivo de saúde (ASO) só abre para quem tem ve_saude
     and (fn_ve_saude(app_email()) or not exists (select 1 from documentos d join tipos_documento tp on tp.id = d.tipo_documento_id
                                                  where d.caminho = p_nome and tp.saude))
$function$;

CREATE OR REPLACE FUNCTION public.app_pode_gerir_documentos()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(fn_papel_na_conta() in ('admin','gestor'), false)
     and (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' or not interno.fn_mfa_exigido(app_email()))
$function$;

-- Edge Functions convidar-usuario e excluir-usuario passam o nível da sessão em p_aal (não há auth.jwt() aqui)
CREATE OR REPLACE FUNCTION interno.fn_convite_autorizar(p_autor text, p_aal text, p_conta uuid, p_email text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_autor text := lower(btrim(p_autor));
  v_email text := lower(btrim(p_email));
  v_plataforma boolean;
  v_id bigint;
begin
  if not exists (select 1 from contas where id = p_conta and ativa) then
    raise exception 'Conta não encontrada.';
  end if;
  if not exists (select 1 from conta_membros where conta_id = p_conta and email = v_email and ativo) then
    raise exception 'Cadastre o usuário na conta antes de convidar.';
  end if;
  v_plataforma := exists (select 1 from plataforma_admins where email = v_autor);
  if v_plataforma then
    if coalesce(p_aal, 'aal1') <> 'aal2' then
      raise exception 'Ative e confirme a verificação em duas etapas para convidar.';
    end if;
  elsif not exists (select 1 from conta_membros where conta_id = p_conta and email = v_autor and ativo and papel = 'admin') then
    raise exception 'Sem permissão para esta ação.';
  elsif coalesce(p_aal, 'aal1') <> 'aal2' and interno.fn_mfa_exigido(v_autor) then
    raise exception 'Confirme o código do aplicativo autenticador para continuar.';
  end if;
  -- pedidos simultâneos do mesmo autor ou para o mesmo e-mail esperam um ao outro (limites sem corrida)
  perform pg_advisory_xact_lock(hashtext('convite:' || v_autor));
  perform pg_advisory_xact_lock(hashtext('convite:' || p_conta || ':' || v_email));
  -- retenção (LGPD): o registro do convite vale 90 dias
  delete from convites where em < now() - interval '90 days';
  if (select count(*) from convites where autor = v_autor and em > now() - interval '1 hour') >= 20 then
    raise exception 'Muitos convites na última hora. Tente mais tarde.';
  end if;
  if exists (select 1 from convites where conta_id = p_conta and email = v_email and em > now() - interval '10 minutes'
               and resultado in ('pendente', 'enviado')) then
    raise exception 'Convite já enviado há pouco para este e-mail. Aguarde alguns minutos.';
  end if;
  insert into convites (conta_id, email, autor) values (p_conta, v_email, v_autor) returning id into v_id;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION interno.fn_usuario_excluir(p_autor text, p_aal text, p_conta uuid, p_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_autor text := lower(btrim(p_autor));
  v_email text := lower(btrim(p_email));
  v_plataforma boolean;
  m conta_membros;
  v_resta boolean;
  v_login uuid;
  v_id bigint;
begin
  if not exists (select 1 from contas where id = p_conta) then
    raise exception 'Conta não encontrada.';
  end if;
  v_plataforma := exists (select 1 from plataforma_admins where email = v_autor);
  if v_plataforma then
    if coalesce(p_aal, 'aal1') <> 'aal2' then
      raise exception 'Ative e confirme a verificação em duas etapas para excluir.';
    end if;
  elsif not exists (select 1 from conta_membros where conta_id = p_conta and email = v_autor and ativo and papel = 'admin') then
    raise exception 'Sem permissão para esta ação.';
  elsif coalesce(p_aal, 'aal1') <> 'aal2' and interno.fn_mfa_exigido(v_autor) then
    raise exception 'Confirme o código do aplicativo autenticador para continuar.';
  end if;
  if v_email = v_autor then
    raise exception 'Você não pode excluir o próprio usuário.';
  end if;

  -- o último administrador ativo não sai (linhas travadas: duas exclusões ao mesmo tempo)
  perform 1 from conta_membros where conta_id = p_conta and papel = 'admin' and ativo order by email for update;
  select * into m from conta_membros where conta_id = p_conta and email = v_email for update;
  if not found then raise exception 'Usuário não encontrado nesta conta.'; end if;
  if m.papel = 'admin' and m.ativo
     and (select count(*) from conta_membros where conta_id = p_conta and papel = 'admin' and ativo) = 1 then
    raise exception 'Este é o único administrador ativo. Cadastre outro administrador antes.';
  end if;

  -- retenção (LGPD, legítimo interesse: prova de quem tirou o acesso): o registro da exclusão vale 5 anos
  delete from usuarios_excluidos where em < now() - interval '5 years';
  delete from conta_membros where conta_id = p_conta and email = v_email;

  -- o login só some se a pessoa não for de outra conta nem da plataforma
  v_resta := exists (select 1 from conta_membros where email = v_email)
             or exists (select 1 from plataforma_admins where email = v_email);
  if not v_resta then
    select u.id into v_login from auth.users u where lower(u.email) = v_email limit 1;
  end if;
  insert into usuarios_excluidos (conta_id, email, papel, autor, situacao, login_id)
  values (p_conta, v_email, m.papel, v_autor, case when v_login is null then 'mantido' else 'pendente' end, v_login)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'login', v_login, 'email', v_email, 'plataforma', v_plataforma);
end $function$;

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
