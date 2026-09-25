-- 35 | Indicadores contam apenas escalas ATIVAS da equipe de campo.
-- Ficam de fora: canceladas, escalas de teste, tecnicos de perfil de teste e supervisores.

create or replace function app_resumo(p_inicio date, p_fim date)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  select jsonb_build_object(
    'total', count(*),
    'confirmadas', count(*) filter (where e.status = 'confirmada'),
    'recusadas', count(*) filter (where e.status = 'recusada'),
    'aguardando', count(*) filter (where e.status = 'notificada'),
    'nao_enviadas', count(*) filter (where e.status = 'agendada'),
    'criticas', count(*) filter (where e.supervisor_avisado_em is not null),
    'pct_confirmacao', coalesce(round(100.0 * count(*) filter (where e.status = 'confirmada')
                        / nullif(count(*) filter (where e.status <> 'rascunho'), 0)), 0)
  ) into v
  from escalas e join tecnicos t on t.id = e.tecnico_id
  where e.data_servico between p_inicio and p_fim
    and e.status <> 'cancelada' and not e.teste
    and not t.perfil_teste and not t.is_supervisor;
  return v;
end $$;

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
    where e.data_servico = p_data and e.status <> 'cancelada'
      and not e.teste and not t.perfil_teste and not t.is_supervisor
    group by l.id, l.nome, l.endereco, l.link_maps
  ) s
$$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
