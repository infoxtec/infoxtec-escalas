-- 09 | Exclusao definitiva de tecnico + criacao de escala para varios tecnicos
-- (fn_excluir_tecnico recebe a trava de papel na migration 14)

create table if not exists log_exclusoes (
  id                uuid primary key default gen_random_uuid(),
  entidade          text not null,
  entidade_id       uuid not null,
  ator              text not null,
  escalas_removidas int  not null default 0,
  created_at        timestamptz not null default now()
);
alter table log_exclusoes enable row level security;

create or replace function fn_excluir_tecnico(p_ator text, p_tecnico_id text)
returns jsonb language plpgsql volatile as $$
declare
  v_id      uuid := p_tecnico_id::uuid;
  v_ator    text := coalesce(nullif(p_ator,''), 'painel');
  v_sup     boolean;
  v_outros  int;
  v_abertas int;
  v_total   int;
  v_hoje    date := (now() at time zone fn_config('fuso'))::date;
begin
  perform set_config('app.ator', v_ator, false);
  select is_supervisor into v_sup from tecnicos where id = v_id;
  if not found then raise exception 'Técnico não encontrado.'; end if;
  if v_sup then
    select count(*) into v_outros from tecnicos where is_supervisor and ativo and id <> v_id;
    if v_outros = 0 then
      raise exception 'Não é possível excluir o único supervisor ativo. Cadastre outro supervisor antes.';
    end if;
  end if;
  select count(*) into v_abertas from escalas
  where tecnico_id = v_id and data_servico >= v_hoje
    and status in ('agendada','notificada','confirmada','reagendada','em_execucao');
  if v_abertas > 0 then
    raise exception 'Este técnico tem % escala(s) em aberto a partir de hoje. Cancele ou conclua antes de excluir.', v_abertas;
  end if;
  select count(*) into v_total from escalas where tecnico_id = v_id;
  delete from escalas  where tecnico_id = v_id;
  delete from tecnicos where id = v_id;
  insert into log_exclusoes (entidade, entidade_id, ator, escalas_removidas)
  values ('tecnico', v_id, v_ator, v_total);
  return jsonb_build_object('excluido', true, 'escalas_removidas', v_total);
end $$;

create or replace function fn_criar_escalas_lote(
  p_ator text, p_tecnico_ids text, p_local_id text, p_data text, p_hora text, p_tarefa text,
  p_duracao_min text default '240', p_prioridade text default 'normal', p_enviar text default 'true'
) returns table (tecnico_id uuid, tecnico text, escala_id uuid, resultado text)
language plpgsql volatile as $$
declare
  v_tid text;
begin
  if p_tecnico_ids is null
     or jsonb_typeof(p_tecnico_ids::jsonb) <> 'array'
     or jsonb_array_length(p_tecnico_ids::jsonb) = 0 then
    raise exception 'Selecione pelo menos um técnico.';
  end if;
  for v_tid in select distinct x from jsonb_array_elements_text(p_tecnico_ids::jsonb) as x loop
    tecnico_id := v_tid::uuid;
    select t.nome into tecnico from tecnicos t where t.id = tecnico_id;
    begin
      escala_id := fn_criar_escala(p_ator, v_tid, p_local_id, p_data, p_hora, p_tarefa,
                                   p_duracao_min, p_prioridade, p_enviar);
      resultado := 'criada';
    exception
      when unique_violation then
        escala_id := null; resultado := 'conflito: já tem escala nesse dia e horário';
      when foreign_key_violation then
        escala_id := null; resultado := 'erro: técnico ou local não encontrado';
    end;
    return next;
  end loop;
end $$;
