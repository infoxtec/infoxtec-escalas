-- 13 | Fixa o search_path de todas as funcoes do schema public (linter do Supabase)
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c where c like 'search_path=%'
      )
  loop
    execute format('alter function %s set search_path = public, extensions', f.assinatura);
  end loop;
end $$;
