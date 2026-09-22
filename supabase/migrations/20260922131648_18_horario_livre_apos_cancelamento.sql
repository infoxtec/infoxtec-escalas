-- 18 | Escala cancelada libera o horario: a trava de "mesmo tecnico, mesmo dia e hora"
--      passa a valer so para escalas nao canceladas.

alter table escalas drop constraint if exists escalas_tecnico_id_data_servico_hora_inicio_key;

create unique index if not exists escalas_horario_ativo_unico
  on escalas (tecnico_id, data_servico, hora_inicio)
  where status <> 'cancelada';

-- Reativar uma cancelada quando ja existe outra ativa no mesmo horario: mensagem clara
create or replace function fn_mudar_status(p_ator text, p_escala_id text, p_status text)
returns text
language plpgsql volatile
set search_path = public, extensions as $$
begin
  perform fn_exigir_papel(p_ator, array['admin', 'gestor']);
  perform set_config('app.ator', coalesce(nullif(p_ator, ''), 'painel'), false);
  update escalas set status = p_status::escala_status where id = p_escala_id::uuid;
  if not found then
    raise exception 'Escala % nao encontrada', p_escala_id;
  end if;
  return p_status;
exception when unique_violation then
  raise exception 'Já existe outra escala ativa para este técnico no mesmo dia e horário.';
end $$;

revoke execute on function fn_mudar_status(text, text, text) from public, anon, authenticated;
