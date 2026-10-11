-- Migration 77 (11/10/2026): feriado e afastado fora da cobrança de escala; verificação em duas etapas
-- (MFA) no painel — decisões 65 e 67.
--
-- 1. fn_pendencias_escala (painel "Técnicos sem escala", contador da Agenda e alerta das 16h/18h): dia
--    de feriado não exige escala (decisão 65) e técnico afastado no dia (decisão 60) não conta como "sem
--    escala". Devolve também o nome do feriado e quantos estão afastados.
-- 2. MFA (backlog 037, P0): o painel passa a cadastrar e pedir o código do aplicativo autenticador
--    (TOTP do Supabase Auth). Com config.mfa_obrigatorio = 'true', toda função app_* exige a sessão
--    confirmada com o código (aal2). Nasce desligado: o responsável liga depois de cadastrar o próprio
--    código, para ninguém ficar sem acesso.

insert into config (chave, valor, descricao) values
  ('mfa_obrigatorio', 'false', 'true: o painel exige o código do aplicativo autenticador (MFA) em toda função app_* (decisão 67)')
on conflict (chave) do nothing;

create or replace function fn_pendencias_escala(p_data date)
returns jsonb language sql stable set search_path to 'public', 'extensions' as $function$
  with alvo as (
    select t.id, t.nome, t.funcao from tecnicos t
    where t.ativo and not t.perfil_teste
      and (coalesce(fn_config('sem_escala_incluir_supervisores'), 'false')::boolean or not t.is_supervisor)
  ),
  afastados as (
    select a.id from alvo a where fn_ponto_afastado_ate(a.id, p_data) is not null
  ),
  sem as (
    select a.* from alvo a
    where not exists (select 1 from escalas e
                      where e.tecnico_id = a.id and e.data_servico = p_data
                        and e.status not in ('cancelada', 'recusada') and not e.teste)
      and not exists (select 1 from afastados x where x.id = a.id)
  )
  select jsonb_build_object(
    'data', p_data, 'total_tecnicos', (select count(*) from alvo) - (select count(*) from afastados),
    'sem_escala', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'funcao', funcao) order by nome) from sem), '[]'::jsonb),
    'rascunhos', (select count(*) from escalas where data_servico = p_data and status = 'rascunho' and not teste),
    'prazo', fn_config('alerta_escala_prazo'),
    'feriado', (select f.nome from feriados f where f.data = p_data),
    'afastados', (select count(*) from afastados),
    'exige_escala', extract(isodow from p_data)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))
                    and not exists (select 1 from feriados f where f.data = p_data)
  )
$function$;

-- Toda app_* passa por aqui: com o MFA obrigatório, só sessão confirmada com o código (aal2) ----------------
create or replace function app_exigir(p_papeis text[])
returns text language plpgsql stable set search_path to 'public', 'extensions' as $function$
declare
  v_email text := app_email();
begin
  if v_email is null then
    raise exception 'Sessão expirada. Entre novamente.';
  end if;
  if coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true' and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'Confirme o código do aplicativo autenticador para continuar.';
  end if;
  perform fn_exigir_papel(v_email, p_papeis);
  return v_email;
end $function$;

-- Storage dos documentos dos técnicos (ASO, NR, CNH): as políticas do bucket usam esta função, que não
-- passa por app_exigir. Com o MFA obrigatório, também exige a sessão confirmada (revisão seguranca, alto)
create or replace function app_pode_gerir_documentos()
returns boolean language sql stable security definer set search_path to 'public', 'extensions' as $function$
  select coalesce(fn_papel(app_email()) in ('admin','gestor'), false)
     and (coalesce(fn_config('mfa_obrigatorio'), 'false') <> 'true' or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2')
$function$;

-- O painel precisa saber se o MFA é obrigatório antes de liberar as telas (não passa por app_exigir) -------
create or replace function app_meu_acesso()
returns jsonb language sql stable security definer set search_path to 'public', 'extensions' as $function$
  select jsonb_build_object(
    'email', app_email(),
    'papel', (select papel from painel_usuarios where email = app_email() and ativo),
    'nome',  (select nome  from painel_usuarios where email = app_email()),
    've_saude', fn_ve_saude(app_email()),
    'mfa_obrigatorio', coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true'
  )
$function$;

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
