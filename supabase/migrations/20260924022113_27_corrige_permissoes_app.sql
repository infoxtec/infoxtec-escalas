-- 27 | Permissoes por laco: toda funcao app_* recebe execute para usuario logado.
-- Motivo: a migration 26 revogou tudo e concedeu apenas as duas funcoes novas,
-- derrubando o acesso ao painel. Lista manual nao se repete.

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in
    select p.oid::regprocedure as assinatura
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'app\_%'
  loop
    execute format('grant execute on function %s to authenticated', f.assinatura);
  end loop;
end $$;
