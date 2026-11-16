-- 158: relógio do app do ponto (Portaria MTP 671/2021, Anexo IX, item 3: todo coletor exibe relógio não analógico com
-- horas, minutos e segundos no momento da marcação). A hora exibida é a do servidor — a mesma que grava a marcação —,
-- não a do aparelho: o app pergunta a hora aqui, mede o atraso da ida e volta e corrige o relógio do celular.
-- Só a hora e o fuso da empresa do funcionário da sessão; nenhum dado pessoal.

create or replace function public.ponto_hora(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = interno, public, extensions, pg_temp
as $function$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  return jsonb_build_object(
    'agora_ms', floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
    'fuso', (select coalesce(e.fuso, 'America/Bahia') from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = v_tec));
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
