-- 30 | Escala sempre no futuro (minimo 5 min) + escala de teste fora das estatisticas
-- Obs.: app_criar_escalas desta migration foi corrigida na 31 (ver motivo la).

alter table escalas add column if not exists teste boolean not null default false;
insert into config (chave, valor, descricao) values
  ('antecedencia_minima_min', '5', 'Minutos minimos entre agora e o inicio da escala')
on conflict (chave) do nothing;

create or replace function fn_marcar_escala_teste()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if exists (select 1 from tecnicos where id = new.tecnico_id and perfil_teste) then
    new.teste := true;
  end if;
  return new;
end $$;
drop trigger if exists trg_escalas_teste on escalas;
create trigger trg_escalas_teste before insert on escalas
  for each row execute function fn_marcar_escala_teste();

create or replace function fn_validar_inicio(p_data date, p_hora time)
returns void language plpgsql stable set search_path = public, extensions as $$
declare
  v_agora timestamp := now() at time zone fn_config('fuso');
  v_min int := coalesce(fn_config_int('antecedencia_minima_min'), 5);
begin
  if (p_data + p_hora) < v_agora + make_interval(mins => v_min) then
    raise exception 'A escala precisa começar pelo menos % minutos à frente. Agora são %, e foi informado % às %.',
      v_min, to_char(v_agora, 'DD/MM HH24:MI'), to_char(p_data, 'DD/MM'), to_char(p_hora, 'HH24:MI');
  end if;
end $$;

create or replace function fn_criar_escala(
  p_ator text, p_tecnico_id text, p_local_id text, p_data text, p_hora text, p_tarefa text,
  p_duracao_min text default '240', p_prioridade text default 'normal', p_enviar text default 'true'
) returns uuid language plpgsql volatile set search_path = public, extensions as $$
declare v_id uuid;
begin
  perform fn_exigir_papel(p_ator, array['admin', 'gestor']);
  perform fn_validar_inicio(p_data::date, p_hora::time);
  perform set_config('app.ator', coalesce(nullif(p_ator, ''), 'painel'), false);
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio,
    duracao_prevista_min, descricao_tarefa, prioridade, status, criado_por)
  values (p_tecnico_id::uuid, nullif(p_local_id, '')::uuid, p_data::date, p_hora::time,
    coalesce(nullif(p_duracao_min, '')::int, 240), p_tarefa,
    coalesce(nullif(p_prioridade, ''), 'normal'),
    case when p_enviar::boolean then 'agendada'::escala_status else 'rascunho'::escala_status end,
    coalesce(nullif(p_ator, ''), 'painel'))
  returning id into v_id;
  return v_id;
end $$;

drop function if exists app_criar_escalas(uuid[], uuid, date, time, text, int, text, boolean, uuid);

create or replace function app_resumo(p_inicio date, p_fim date)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  select jsonb_build_object(
    'total', count(*), 'confirmadas', count(*) filter (where e.status = 'confirmada'),
    'recusadas', count(*) filter (where e.status = 'recusada'),
    'aguardando', count(*) filter (where e.status = 'notificada'),
    'nao_enviadas', count(*) filter (where e.status = 'agendada'),
    'criticas', count(*) filter (where e.supervisor_avisado_em is not null),
    'pct_confirmacao', coalesce(round(100.0 * count(*) filter (where e.status = 'confirmada')
                        / nullif(count(*) filter (where e.status <> 'rascunho'), 0)), 0)
  ) into v
  from escalas e join tecnicos t on t.id = e.tecnico_id
  where e.data_servico between p_inicio and p_fim and e.status <> 'cancelada'
    and not t.perfil_teste and not e.teste;
  return v;
end $$;

create or replace function fn_pendencias_escala(p_data date)
returns jsonb language sql stable set search_path = public, extensions as $$
  with alvo as (
    select t.id, t.nome, t.funcao from tecnicos t
    where t.ativo and not t.perfil_teste
      and (coalesce(fn_config('sem_escala_incluir_supervisores'), 'false')::boolean or not t.is_supervisor)
  ),
  sem as (
    select a.* from alvo a
    where not exists (select 1 from escalas e
                      where e.tecnico_id = a.id and e.data_servico = p_data
                        and e.status <> 'cancelada' and not e.teste)
  )
  select jsonb_build_object(
    'data', p_data, 'total_tecnicos', (select count(*) from alvo),
    'sem_escala', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'funcao', funcao) order by nome) from sem), '[]'::jsonb),
    'rascunhos', (select count(*) from escalas where data_servico = p_data and status = 'rascunho' and not teste),
    'prazo', fn_config('alerta_escala_prazo'),
    'exige_escala', extract(isodow from p_data)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))
  )
$$;

create or replace function fn_remover_escala(p_ator text, p_escala_id text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_id uuid := p_escala_id::uuid; v_ator text := coalesce(nullif(p_ator, ''), 'painel');
  v_esc record; v_saiu boolean; v_aviso boolean := false;
begin
  perform fn_exigir_papel(p_ator, array['admin', 'gestor']);
  select e.id, e.status, e.teste, e.data_servico, e.hora_inicio, t.telefone_e164, t.ativo, t.opt_in,
         coalesce(l.nome, 'local a confirmar') as local_nome into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id
  left join locais l on l.id = e.local_id where e.id = v_id;
  if not found then raise exception 'Escala não encontrada.'; end if;

  if not v_esc.teste then
    if v_esc.status in ('confirmada','recusada','em_execucao','concluida')
       or exists (select 1 from respostas where escala_id = v_id) then
      raise exception 'O técnico já respondeu esta escala. Use Cancelar para manter o histórico.';
    end if;
    if exists (select 1 from notificacoes where escala_id = v_id
                 and (status_envio in ('entregue','lida') or entregue_em is not null)) then
      raise exception 'O técnico já recebeu esta escala no WhatsApp. Use Cancelar para manter o histórico.';
    end if;
  end if;

  v_saiu := exists (select 1 from notificacoes where escala_id = v_id and status_envio in ('enfileirada','enviada'));
  if v_saiu and v_esc.ativo and not v_esc.teste then
    perform fn_wa_texto(v_esc.telefone_e164,
      '❌ A escala de ' || to_char(v_esc.data_servico, 'DD/MM') || ' às '
      || to_char(v_esc.hora_inicio, 'HH24:MI') || ' — ' || v_esc.local_nome
      || ' foi *cancelada*. Desconsidere a mensagem anterior.');
    v_aviso := true;
  end if;

  perform set_config('app.ator', v_ator, false);
  delete from escalas where id = v_id;
  insert into log_exclusoes (entidade, entidade_id, ator, escalas_removidas)
  values (case when v_esc.teste then 'escala_teste' else 'escala' end, v_id, v_ator, 1);
  return jsonb_build_object('removida', true, 'aviso_enviado', v_aviso, 'teste', v_esc.teste);
end $$;

-- fn_painel_locais: ignora escalas de teste (corpo igual a migration 20, com o filtro extra)
create or replace function fn_painel_locais(p_data date)
returns jsonb language sql stable set search_path = public, extensions as $$
  select coalesce(jsonb_agg(x order by x->>'primeira_hora' nulls last, x->>'local'), '[]'::jsonb) from (
    select jsonb_build_object(
      'local_id', l.id, 'local', coalesce(l.nome, 'Sem local definido'),
      'endereco', l.endereco, 'link_maps', l.link_maps,
      'primeira_hora', to_char(min(e.hora_inicio), 'HH24:MI'), 'total', count(*),
      'confirmadas', count(*) filter (where e.status in ('confirmada','em_execucao','concluida')),
      'aguardando', count(*) filter (where e.status in ('agendada','notificada')),
      'recusadas', count(*) filter (where e.status = 'recusada'),
      'em_execucao', count(*) filter (where e.status = 'em_execucao'),
      'concluidas', count(*) filter (where e.status = 'concluida'),
      'criticas', count(*) filter (where e.supervisor_avisado_em is not null),
      'pct_aceite', round(100.0 * count(*) filter (where e.status in ('confirmada','em_execucao','concluida')) / count(*)),
      'pct_conclusao', round(100.0 * count(*) filter (where e.status = 'concluida') / count(*)),
      'tecnicos', jsonb_agg(jsonb_build_object(
          'escala_id', e.id, 'tecnico', t.nome, 'telefone', t.telefone_e164,
          'hora', to_char(e.hora_inicio, 'HH24:MI'), 'fim', to_char(e.hora_fim_prevista, 'HH24:MI'),
          'status', e.status::text,
          'status_envio', (select n.status_envio::text from notificacoes n
                           where n.escala_id = e.id order by n.created_at desc limit 1),
          'tarefa', e.descricao_tarefa, 'tipo', ta.nome) order by e.hora_inicio, t.nome)
    ) as x
    from escalas e
    join tecnicos t on t.id = e.tecnico_id
    left join locais l on l.id = e.local_id
    left join tipos_atividade ta on ta.id = e.tipo_atividade_id
    where e.data_servico = p_data and e.status <> 'cancelada' and not e.teste and not t.perfil_teste
    group by l.id, l.nome, l.endereco, l.link_maps
  ) s
$$;

-- vw_escalas_painel: expoe a marca de teste e libera a remocao de escalas de teste
create or replace view vw_escalas_painel as
select
  e.id, e.data_servico, e.hora_inicio, t.nome as tecnico, t.telefone_e164 as telefone,
  coalesce(l.nome, '-') as local, coalesce(l.endereco, '') as endereco, l.link_maps,
  e.descricao_tarefa, e.status, e.prioridade,
  n.tipo as ultimo_envio_tipo, n.tentativa, n.status_envio, n.enviada_em, n.entregue_em, n.lida_em,
  r.tipo as resposta, r.recebida_em as respondida_em, e.supervisor_avisado_em,
  case
    when e.status in ('confirmada','concluida','em_execucao') then 'verde'
    when e.status in ('recusada','cancelada')                 then 'vermelho'
    when e.supervisor_avisado_em is not null                  then 'vermelho'
    when e.status = 'notificada'                              then 'ambar'
    else 'cinza' end as semaforo,
  (e.teste or (e.status not in ('confirmada','recusada','em_execucao','concluida')
   and r.tipo is null
   and not exists (select 1 from notificacoes x where x.escala_id = e.id
                     and (x.status_envio in ('entregue','lida') or x.entregue_em is not null)))
  ) as pode_remover,
  e.turno, e.hora_fim_prevista, e.duracao_prevista_min, e.intervalo_min, e.minutos_noturnos,
  e.teste, t.perfil_teste
from escalas e
join tecnicos t on t.id = e.tecnico_id
left join locais l on l.id = e.local_id
left join lateral (select * from notificacoes where escala_id = e.id order by created_at desc limit 1) n on true
left join lateral (select * from respostas where escala_id = e.id order by recebida_em desc limit 1) r on true;
revoke all on vw_escalas_painel from anon, authenticated;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
