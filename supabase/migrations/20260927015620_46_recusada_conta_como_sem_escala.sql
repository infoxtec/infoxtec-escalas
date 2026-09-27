-- 46 | Técnico que recusou volta a aparecer como "sem escala" (decisão 31)
-- Complementa a migration 45: a recusa libera o horário, então o técnico que só tem escala
-- recusada no dia entra na lista "Técnicos sem escala" e no alerta das 18h, para o gestor
-- escalar de novo. Partindo da definição atual da homologação.

CREATE OR REPLACE FUNCTION public.fn_pendencias_escala(p_data date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  with alvo as (
    select t.id, t.nome, t.funcao from tecnicos t
    where t.ativo and not t.perfil_teste
      and (coalesce(fn_config('sem_escala_incluir_supervisores'), 'false')::boolean or not t.is_supervisor)
  ),
  sem as (
    select a.* from alvo a
    where not exists (select 1 from escalas e
                      where e.tecnico_id = a.id and e.data_servico = p_data
                        and e.status not in ('cancelada', 'recusada') and not e.teste)
  )
  select jsonb_build_object(
    'data', p_data, 'total_tecnicos', (select count(*) from alvo),
    'sem_escala', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'funcao', funcao) order by nome) from sem), '[]'::jsonb),
    'rascunhos', (select count(*) from escalas where data_servico = p_data and status = 'rascunho' and not teste),
    'prazo', fn_config('alerta_escala_prazo'),
    'exige_escala', extract(isodow from p_data)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))
  )
$function$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
