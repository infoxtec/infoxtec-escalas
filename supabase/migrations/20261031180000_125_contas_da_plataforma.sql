-- Multiempresa F3c (decisão 117): contas de cliente criadas e mantidas só pela plataforma (plataforma_admins).
-- Toda operação exige a verificação em duas etapas (aal2), mesmo que a conta não a exija, e fica registrada em
-- plataforma_log. O primeiro administrador entra na conta nova como membro; o login dele é o convite do Supabase Auth.
-- Enquanto a trava da 117 existir (até a F3d), criar conta com administrador é recusado pelo banco.

set lock_timeout = '5s';

create table interno.plataforma_log (
  id bigint generated always as identity primary key,
  em timestamptz not null default now(),
  autor text not null,
  acao text not null check (acao in ('criar_conta', 'alterar_conta')),
  conta_alvo uuid not null references interno.contas (id),   -- não é conta_id: a tabela é da plataforma (T56)
  detalhe jsonb not null default '{}'::jsonb
);
alter table interno.plataforma_log enable row level security;
create index plataforma_log_conta_idx on interno.plataforma_log (conta_alvo, em desc);

-- nome de conta único sem diferenciar maiúsculas nem espaços nas pontas (a função só dá a mensagem antes)
create unique index contas_nome_uq on interno.contas (lower(btrim(nome)));

-- guarda das funções da plataforma: sessão, lista da plataforma e duas etapas (fora da API, em interno)
create or replace function interno.fn_exigir_plataforma()
 returns text language plpgsql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_email();
begin
  if v_email is null then
    raise exception 'Sessão expirada. Entre novamente.';
  end if;
  if not exists (select 1 from interno.plataforma_admins where email = v_email) then
    raise exception 'Sem permissão para esta ação.';
  end if;
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'Ative e confirme a verificação em duas etapas para administrar contas.';
  end if;
  return v_email;
end $function$;

create or replace function public.app_plataforma_contas()
 returns jsonb language plpgsql stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform interno.fn_exigir_plataforma();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'nome', c.nome, 'ativa', c.ativa, 'criada_em', c.criada_em,
      'membros', (select count(*) from interno.conta_membros m where m.conta_id = c.id and m.ativo),
      'admins', coalesce((select jsonb_agg(m.email order by m.email) from interno.conta_membros m
                           where m.conta_id = c.id and m.ativo and m.papel = 'admin'), '[]'::jsonb),
      'modulos', coalesce((select jsonb_agg(cm.modulo order by cm.modulo) from interno.conta_modulos cm
                            where cm.conta_id = c.id and cm.ativo), '[]'::jsonb))
    order by c.criada_em) from interno.contas c), '[]'::jsonb);
end $function$;

create or replace function public.app_plataforma_criar_conta(p_nome text, p_admin_email text, p_admin_nome text,
                                                             p_modulos text[])
 returns uuid language plpgsql security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator  text := interno.fn_exigir_plataforma();
  v_nome  text := btrim(p_nome);
  v_email text := lower(btrim(p_admin_email));
  v_id    uuid;
begin
  if v_nome is null or length(v_nome) not between 2 and 120 then
    raise exception 'Informe o nome da conta (2 a 120 caracteres).';
  end if;
  if exists (select 1 from interno.contas where lower(nome) = lower(v_nome)) then
    raise exception 'Já existe uma conta com este nome.';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+$' then
    raise exception 'Informe um e-mail válido para o administrador.';
  end if;
  if coalesce(cardinality(p_modulos), 0) = 0 or not (p_modulos <@ array['escala', 'ponto']) then
    raise exception 'Escolha os módulos da conta (escala, ponto).';
  end if;

  begin
    insert into interno.contas (nome) values (v_nome) returning id into v_id;
  exception when unique_violation then
    raise exception 'Já existe uma conta com este nome.';
  end;
  insert into interno.conta_modulos (conta_id, modulo) select v_id, m from unnest(p_modulos) m group by m;
  insert into interno.conta_membros (conta_id, email, nome, papel, criado_por)
  values (v_id, v_email, nullif(btrim(p_admin_nome), ''), 'admin', v_ator);
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'criar_conta', v_id, jsonb_build_object('nome', v_nome, 'admin', v_email, 'modulos', p_modulos));
  return v_id;
end $function$;

create or replace function public.app_plataforma_salvar_conta(p_id uuid, p_nome text, p_ativa boolean, p_modulos text[])
 returns void language plpgsql security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator text := interno.fn_exigir_plataforma();
  v_nome text := btrim(p_nome);
  c      interno.contas;
begin
  select * into c from interno.contas where id = p_id for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if v_nome is null or length(v_nome) not between 2 and 120 then
    raise exception 'Informe o nome da conta (2 a 120 caracteres).';
  end if;
  if exists (select 1 from interno.contas where lower(nome) = lower(v_nome) and id <> p_id) then
    raise exception 'Já existe uma conta com este nome.';
  end if;
  -- a operadora não se desliga (o motor e os alertas da plataforma rodam nela)
  if p_id = '00000000-0000-0000-0000-000000000001' and not coalesce(p_ativa, true) then
    raise exception 'A conta da operadora não pode ser desativada.';
  end if;
  if coalesce(cardinality(p_modulos), 0) = 0 or not (p_modulos <@ array['escala', 'ponto']) then
    raise exception 'Escolha os módulos da conta (escala, ponto).';
  end if;

  begin
    update interno.contas set nome = v_nome, ativa = coalesce(p_ativa, ativa) where id = p_id;
  exception when unique_violation then
    raise exception 'Já existe uma conta com este nome.';
  end;
  insert into interno.conta_modulos (conta_id, modulo, ativo)
  select p_id, m, m = any (p_modulos) from unnest(array['escala', 'ponto']) m
  on conflict (conta_id, modulo) do update
     set ativo = excluded.ativo,
         desde = case when conta_modulos.ativo <> excluded.ativo then now() else conta_modulos.desde end;
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'alterar_conta', p_id, jsonb_build_object(
    'nome', case when c.nome <> v_nome then jsonb_build_array(c.nome, v_nome) end,
    'ativa', case when c.ativa <> coalesce(p_ativa, c.ativa) then p_ativa end,
    'modulos', p_modulos));
end $function$;

create or replace function public.app_meu_acesso()
 returns jsonb language plpgsql stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
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
    'mfa_obrigatorio', coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true',
    -- F3c: mostra a tela Contas (a guarda de cada função continua no banco)
    'plataforma', exists (select 1 from interno.plataforma_admins pa where pa.email = v_email),
    'contas', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'papel', cm.papel) order by c.nome)
                          from interno.conta_membros cm join interno.contas c on c.id = cm.conta_id
                         where cm.email = v_email and cm.ativo and c.ativa), '[]'::jsonb)
  );
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
