-- 20 | Remove a versao antiga de app_criar_escalas (evita ambiguidade na chamada),
--      corrige o painel por local para usar IDs, e cadastra as habilidades padrao.

drop function if exists app_criar_escalas(uuid[], uuid, date, time, text, int, text, boolean);

create or replace function fn_painel_locais(p_data date)
returns jsonb language sql stable set search_path = public, extensions as $$
  select coalesce(jsonb_agg(x order by x->>'primeira_hora' nulls last, x->>'local'), '[]'::jsonb) from (
    select jsonb_build_object(
      'local_id', l.id,
      'local', coalesce(l.nome, 'Sem local definido'),
      'endereco', l.endereco, 'link_maps', l.link_maps,
      'primeira_hora', to_char(min(e.hora_inicio), 'HH24:MI'),
      'total', count(*),
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
          'tarefa', e.descricao_tarefa, 'tipo', ta.nome
        ) order by e.hora_inicio, t.nome)
    ) as x
    from escalas e
    join tecnicos t on t.id = e.tecnico_id
    left join locais l on l.id = e.local_id
    left join tipos_atividade ta on ta.id = e.tipo_atividade_id
    where e.data_servico = p_data and e.status <> 'cancelada'
    group by l.id, l.nome, l.endereco, l.link_maps
  ) s
$$;

insert into habilidades (nome, categoria, exige_validade, descricao) values
  ('CFTV',                   'tecnica',     false, 'Instalação e manutenção de câmeras e gravadores'),
  ('Fibra óptica',           'tecnica',     false, 'Fusão, certificação e lançamento de fibra'),
  ('Cabeamento estruturado', 'tecnica',     false, 'Rede estruturada, racks e certificação de pontos'),
  ('Controle de acesso',     'tecnica',     false, 'Catracas, fechaduras, biometria e controladoras'),
  ('Link de internet',       'tecnica',     false, 'Instalação e ativação de links'),
  ('Alarme e cerca elétrica','tecnica',     false, 'Centrais de alarme, sensores e cerca elétrica'),
  ('NR-10',                  'seguranca',   true,  'Segurança em instalações e serviços com eletricidade'),
  ('NR-35',                  'seguranca',   true,  'Trabalho em altura'),
  ('NR-33',                  'seguranca',   true,  'Espaço confinado'),
  ('CNH B',                  'habilitacao', true,  'Habilitação para dirigir veículo da empresa')
on conflict (nome) do nothing;

insert into tipos_atividade (nome, descricao) values
  ('Instalação CFTV',        'Instalação de câmeras e gravadores'),
  ('Manutenção CFTV',        'Manutenção preventiva ou corretiva de CFTV'),
  ('Fusão de fibra',         'Fusão e certificação de fibra óptica'),
  ('Cabeamento estruturado', 'Lançamento e certificação de pontos de rede'),
  ('Controle de acesso',     'Instalação ou manutenção de controle de acesso'),
  ('Ativação de link',       'Ativação ou manutenção de link de internet')
on conflict (nome) do nothing;

insert into tipo_atividade_requisitos (tipo_id, habilidade_id, nivel_minimo)
select ta.id, h.id, req.nivel
from (values
  ('Instalação CFTV',        'CFTV',                   'intermediario'),
  ('Instalação CFTV',        'NR-35',                  'basico'),
  ('Manutenção CFTV',        'CFTV',                   'basico'),
  ('Fusão de fibra',         'Fibra óptica',           'avancado'),
  ('Cabeamento estruturado', 'Cabeamento estruturado', 'intermediario'),
  ('Controle de acesso',     'Controle de acesso',     'intermediario'),
  ('Ativação de link',       'Link de internet',       'basico')
) as req(tipo, habilidade, nivel)
join tipos_atividade ta on ta.nome = req.tipo
join habilidades h on h.nome = req.habilidade
on conflict do nothing;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  app_meu_acesso(), app_escalas(date, date), app_resumo(date, date), app_linha_do_tempo(uuid),
  app_tecnicos(), app_locais(), app_pendencias(date), app_config(), app_simular_jornada(time),
  app_criar_escalas(uuid[], uuid, date, time, text, int, text, boolean, uuid),
  app_mudar_status(uuid, text), app_remover_escala(uuid), app_reenviar_escala(uuid),
  app_salvar_tecnico(jsonb), app_excluir_tecnico(uuid), app_salvar_local(jsonb),
  app_usuarios(), app_salvar_usuario(text, text, text, boolean),
  app_habilidades(), app_salvar_habilidade(jsonb), app_tecnico_habilidades(),
  app_salvar_tecnico_habilidade(jsonb), app_remover_tecnico_habilidade(uuid, uuid),
  app_tipos_atividade(), app_salvar_tipo_atividade(jsonb), app_aptidao(uuid),
  app_painel_locais(date)
to authenticated;
