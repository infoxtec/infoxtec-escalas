-- 31 | Correcao: tipo de atividade e marcacao de teste nao eram gravados.
-- Causa: o UPDATE ficava numa CTE da mesma instrucao que inseria as escalas, e CTEs
-- compartilham o snapshot inicial — as linhas novas eram invisiveis para o UPDATE.
-- Agora o laco em plpgsql atualiza cada escala depois de criada.

create or replace function app_criar_escalas(
  p_tecnicos uuid[], p_local uuid, p_data date, p_hora time, p_tarefa text,
  p_duracao int default 240, p_prioridade text default 'normal', p_enviar boolean default true,
  p_tipo uuid default null, p_teste boolean default false
) returns table (tecnico_id uuid, tecnico text, escala_id uuid, resultado text)
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  r record;
begin
  if coalesce(trim(p_tarefa), '') = '' then raise exception 'Descreva a tarefa.'; end if;
  perform fn_validar_inicio(p_data, p_hora);

  for r in
    select * from fn_criar_escalas_lote(
      v_email, to_jsonb(p_tecnicos)::text, p_local::text, p_data::text,
      to_char(p_hora, 'HH24:MI'), p_tarefa, p_duracao::text,
      coalesce(p_prioridade, 'normal'), p_enviar::text)
  loop
    if r.escala_id is not null then
      update escalas set
        tipo_atividade_id = coalesce(p_tipo, tipo_atividade_id),
        teste = teste or coalesce(p_teste, false)
      where id = r.escala_id;
    end if;
    tecnico_id := r.tecnico_id; tecnico := r.tecnico;
    escala_id := r.escala_id;   resultado := r.resultado;
    return next;
  end loop;
end $$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
