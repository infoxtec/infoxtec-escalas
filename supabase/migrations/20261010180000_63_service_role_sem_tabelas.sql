-- Migration 63 (10/10/2026): o service_role não alcança tabela, view nem sequência do schema public
-- (decisão 51, pendência da revisão do seguranca; tarefa T08 da sprint de 13 a 23/10).
--
-- A migration 62 tirou do service_role o execute das funções, mas ele seguia com acesso total a 33 das
-- 42 tabelas e views (e ignora o RLS): com a chave service_role, alguém leria tecnicos (CPF, telefone)
-- ou se gravaria em painel_usuarios como admin. Nada legítimo usa esse papel: o painel chama app_* como
-- authenticated, o app do ponto chama ponto_* como anon, e as Edge Functions, o pg_cron e o backup
-- entram como postgres (conferido no código em 10/10). As tabelas do ponto já estavam fechadas
-- (migrations 54 a 58).
--
-- Também fecha as três sequências do public, que o padrão antigo do Supabase deixava abertas para anon e
-- authenticated (uso, leitura e nextval), e faz tabela e sequência novas já nascerem fechadas.
-- O acesso aos dados continua só pelas funções security definer, que rodam como postgres.

revoke all on all tables in schema public from anon, authenticated, service_role;
revoke all on all sequences in schema public from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, service_role;

-- Trava: se sobrar qualquer acesso (concessão de outro papel, por coluna ou objeto de outro dono, que o
-- revoke acima não alcança), a migration falha e nada é aplicado.
do $$
declare v text;
begin
  select string_agg(r.rolname || ':' || c.relname, ', ') into v
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join (values ('anon'), ('authenticated'), ('service_role')) r(rolname)
   where n.nspname = 'public' and c.relkind in ('r','p','v','m','f','S')
     and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
     and case when c.relkind = 'S' then has_sequence_privilege(r.rolname, c.oid, 'usage,select,update')
              else has_table_privilege(r.rolname, c.oid, 'select,insert,update,delete,truncate,references,trigger')
                   or has_any_column_privilege(r.rolname, c.oid, 'select,insert,update,references') end;
  if v is not null then raise exception 'migration 63: papel da API ainda alcança %', v; end if;
end $$;
