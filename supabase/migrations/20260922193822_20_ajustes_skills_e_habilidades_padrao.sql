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

-- Permissoes por laco: toda funcao app_* fica executavel por usuario logado.
-- Lista fixa de assinaturas quebra quando a assinatura muda ao longo do historico.
do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
