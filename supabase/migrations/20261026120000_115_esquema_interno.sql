-- 115: esquema privado (backlog 074, decisão 76; primeira etapa do multiempresa, decisão 108). Tabelas, views,
-- sequências e funções fn_* saem do `public` (o esquema que a API do Supabase expõe) para `interno`, que a API não
-- expõe e onde anon, authenticated e service_role não têm nem USAGE. No `public` ficam só as funções app_* (painel)
-- e ponto_* (app do funcionário) e os tipos enum usados nas assinaturas delas. Um erro futuro de permissão ou de RLS
-- deixa de expor dado. Mudança mecânica: nenhum corpo de função muda (nenhum cita `public.`; conferido no catálogo
-- da homologação em 26/10); o caminho de busca das funções e do papel postgres (pg_cron, Edge Functions, scripts)
-- passa a incluir `interno`.

create schema if not exists interno;
revoke all on schema interno from public, anon, authenticated, service_role;

do $$
declare r record;
begin
  -- views antes das tabelas (dependências não importam para set schema, mas a ordem deixa o log legível)
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('v', 'm') loop
    execute format('alter view public.%I set schema interno', r.relname);
  end loop;
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'p') loop
    execute format('alter table public.%I set schema interno', r.relname);  -- leva índices, gatilhos e sequências próprias
  end loop;
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'S' loop
    execute format('alter sequence public.%I set schema interno', r.relname);
  end loop;
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname !~ '^(app|ponto)_'
             and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') loop
    execute format('alter function %s set schema interno', r.f);
  end loop;
  -- caminho de busca de todas as funções nossas (as duas que não tinham, fn_titulo_escala e fn_msg_supervisor, ganham)
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname in ('public', 'interno')
             and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') loop
    execute format('alter function %s set search_path = interno, public, extensions', r.f);
  end loop;
end $$;

-- pg_cron (jobs como postgres, "select fn_...()"), Edge Functions (SUPABASE_DB_URL) e scripts entram como postgres.
-- `interno` vem antes de `public`: um "create or replace function fn_x" sem esquema substitui a interna em vez de
-- criar uma cópia no public (que a API veria e que ganharia da interna). Migration nova escreve sempre o esquema:
-- public.app_*, public.ponto_*, interno.fn_*, interno.<tabela> (CLAUDE.md); o CI (T55) recusa o resto no public.
alter role postgres set search_path = "$user", interno, public, extensions;

-- objetos novos criados em `interno` nascem sem privilégio para os papéis da API (como no public, migrations 62 e 63)
alter default privileges in schema interno revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema interno revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema interno revoke execute on functions from public, anon, authenticated, service_role;

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
