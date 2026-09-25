-- 05 | RPCs do painel (versao inicial, com tipos nativos)
-- SUBSTITUIDA pela 06. Mantida aqui porque foi aplicada no banco.

create or replace function fn_criar_escala(
  p_ator        text,
  p_tecnico_id  uuid,
  p_local_id    uuid,
  p_data        date,
  p_hora        time,
  p_tarefa      text,
  p_duracao_min int     default 240,
  p_prioridade  text    default 'normal',
  p_enviar      boolean default true
) returns uuid
language plpgsql volatile as $$
declare
  v_id uuid;
begin
  perform set_config('app.ator', coalesce(p_ator, 'painel'), false);
  insert into escalas (
    tecnico_id, local_id, data_servico, hora_inicio,
    duracao_prevista_min, descricao_tarefa, prioridade, status, criado_por
  ) values (
    p_tecnico_id, p_local_id, p_data, p_hora,
    p_duracao_min, p_tarefa, p_prioridade,
    case when p_enviar then 'agendada'::escala_status else 'rascunho'::escala_status end,
    coalesce(p_ator, 'painel')
  )
  returning id into v_id;
  return v_id;
end $$;

create or replace function fn_mudar_status(
  p_ator      text,
  p_escala_id uuid,
  p_status    escala_status
) returns escala_status
language plpgsql volatile as $$
begin
  perform set_config('app.ator', coalesce(p_ator, 'painel'), false);
  update escalas set status = p_status where id = p_escala_id;
  if not found then
    raise exception 'Escala % nao encontrada', p_escala_id;
  end if;
  return p_status;
end $$;
