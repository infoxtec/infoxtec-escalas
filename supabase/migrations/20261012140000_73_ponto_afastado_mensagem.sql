-- Migration 73 (12/10/2026): texto da marcação recusada no afastamento (pedido do responsável).
-- Antes: "Para voltar antes, use o app do ponto, aba Ajuste." Agora orienta a ter a liberação médica em
-- mãos e falar com o gestor. A regra não muda (decisão 60). Base: definição atual da homologação.

create or replace function fn_ponto_bloquear_afastado()
returns trigger language plpgsql set search_path to 'public', 'extensions' as $function$
declare v_ate date; v_fuso text;
begin
  select coalesce(e.fuso, 'America/Bahia') into v_fuso from empresas e where e.id = new.empresa_id;
  v_ate := fn_ponto_afastado_ate(new.tecnico_id, (new.momento at time zone coalesce(v_fuso, 'America/Bahia'))::date);
  if v_ate is not null then
    raise exception 'Você está afastado até %. Para voltar antes, tenha a liberação médica em mãos e entre em contato com seu gestor.',
      to_char(v_ate, 'DD/MM');
  end if;
  return new;
end $function$;

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
