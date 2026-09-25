-- 06 | RPCs do painel com parametros texto
-- O driver do Retool envia parametros como texto; a conversao acontece aqui dentro.

drop function if exists fn_criar_escala(text, uuid, uuid, date, time, text, int, text, boolean);
drop function if exists fn_mudar_status(text, uuid, escala_status);

create or replace function fn_criar_escala(
  p_ator        text,
  p_tecnico_id  text,
  p_local_id    text,
  p_data        text,
  p_hora        text,
  p_tarefa      text,
  p_duracao_min text default '240',
  p_prioridade  text default 'normal',
  p_enviar      text default 'true'
) returns uuid
language plpgsql volatile as $$
declare
  v_id uuid;
begin
  perform set_config('app.ator', coalesce(nullif(p_ator,''), 'painel'), false);
  insert into escalas (
    tecnico_id, local_id, data_servico, hora_inicio,
    duracao_prevista_min, descricao_tarefa, prioridade, status, criado_por
  ) values (
    p_tecnico_id::uuid,
    nullif(p_local_id,'')::uuid,
    p_data::date,
    p_hora::time,
    coalesce(nullif(p_duracao_min,'')::int, 240),
    p_tarefa,
    coalesce(nullif(p_prioridade,''), 'normal'),
    case when p_enviar::boolean then 'agendada'::escala_status
         else 'rascunho'::escala_status end,
    coalesce(nullif(p_ator,''), 'painel')
  )
  returning id into v_id;
  return v_id;
end $$;

create or replace function fn_mudar_status(
  p_ator      text,
  p_escala_id text,
  p_status    text
) returns text
language plpgsql volatile as $$
begin
  perform set_config('app.ator', coalesce(nullif(p_ator,''), 'painel'), false);
  update escalas set status = p_status::escala_status where id = p_escala_id::uuid;
  if not found then
    raise exception 'Escala % nao encontrada', p_escala_id;
  end if;
  return p_status;
end $$;
