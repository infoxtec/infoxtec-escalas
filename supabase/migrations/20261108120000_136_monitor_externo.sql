-- Monitor externo pelo painel (etapa 10c, decisão 34): o endereço de ping do healthchecks.io é colado pela
-- plataforma na aba Contas, sem SQL na produção. O motor já chama o endereço a cada minuto (migration 81); se o
-- Supabase ou o motor param, o healthchecks.io avisa por e-mail. A validação do formato continua no gatilho da config.

set lock_timeout = '5s';

alter table interno.plataforma_log drop constraint plataforma_log_acao_check;
alter table interno.plataforma_log add constraint plataforma_log_acao_check
  check (acao in ('criar_conta', 'alterar_conta', 'monitor_externo'));

-- se está ligado e o fim do endereço (o endereço inteiro é como uma senha: quem tem pode marcar o check como vivo)
create or replace function public.app_plataforma_monitor()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v text;
begin
  perform interno.fn_exigir_plataforma();
  v := coalesce((select valor from interno.config where chave = 'monitor_ping_url'), '');
  return jsonb_build_object('ligado', v <> '', 'final', case when v <> '' then right(v, 4) end);
end $function$;

create or replace function public.app_plataforma_salvar_monitor(p_url text)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator text := interno.fn_exigir_plataforma();
  v_url  text := lower(btrim(coalesce(p_url, '')));
begin
  if v_url <> '' and v_url !~ '^https://hc-ping\.com/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'Use o endereço de ping do healthchecks.io: https://hc-ping.com/... (ou deixe vazio para desligar).';
  end if;
  insert into interno.config (chave, valor, descricao)
  values ('monitor_ping_url', v_url, 'Endereço de ping do healthchecks.io, chamado pelo motor a cada minuto (vazio desliga)')
  on conflict (chave) do update set valor = excluded.valor;
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'monitor_externo', '00000000-0000-0000-0000-000000000001',
          jsonb_build_object('ligado', v_url <> '', 'final', case when v_url <> '' then right(v_url, 4) end));
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
