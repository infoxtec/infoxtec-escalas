-- Migration 62 (09/10/2026): nenhuma função interna executável pelo service_role (decisão 51).
--
-- Achado na reavaliação do pacote do DeepSeek (08/10), confirmado pelo dev-banco, fullstack e QA:
-- o bloco de permissões revogava de public, anon e authenticated, mas não do service_role — e o
-- Supabase concede execute ao service_role em toda função nova (default privileges do postgres).
-- Com a chave service_role, alguém chamaria fn_ponto_registrar (que recebe o funcionário como
-- parâmetro) e marcaria ponto por qualquer funcionário, ou fn_segredo e leria o Vault.
--
-- Nada legítimo usa o service_role: o painel chama app_* com a sessão do usuário, o app do ponto
-- chama ponto_* como anon, e as Edge Functions, o pg_cron e o backup entram como postgres.
--
-- 1. Função nova já nasce sem execute para ninguém além do dono (default privileges).
-- 2. Revoga de public, anon, authenticated e service_role em todas as funções do schema public e
--    devolve só o que a API precisa: app_* para authenticated, ponto_* para anon e authenticated.
-- O CI confere isso a cada PR (passo "Permissões das funções").

-- o execute do PUBLIC em função nova vem do padrão global (não do schema): os dois são revogados
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated, service_role;

-- Permissões por laço (decisões 12, 49 e 51) -------------------------------------------------------
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
