-- 03 | Triggers, views do painel e do motor de escalonamento, RLS

create trigger trg_escalas_updated
  before update on escalas
  for each row execute function fn_touch_updated_at();

create trigger trg_escalas_confirmacao
  before update on escalas
  for each row execute function fn_carimba_confirmacao();

create trigger trg_escalas_evento
  after insert or update on escalas
  for each row execute function fn_log_escala_evento();

create or replace view vw_escalas_painel as
select
  e.id,
  e.data_servico,
  e.hora_inicio,
  t.nome            as tecnico,
  t.telefone_e164   as telefone,
  coalesce(l.nome, '-')    as local,
  coalesce(l.endereco, '') as endereco,
  l.link_maps,
  e.descricao_tarefa,
  e.status,
  e.prioridade,
  n.tipo            as ultimo_envio_tipo,
  n.tentativa,
  n.status_envio,
  n.enviada_em,
  n.entregue_em,
  n.lida_em,
  r.tipo            as resposta,
  r.recebida_em     as respondida_em,
  e.supervisor_avisado_em,
  case
    when e.status in ('confirmada','concluida','em_execucao') then 'verde'
    when e.status in ('recusada','cancelada')                 then 'vermelho'
    when e.supervisor_avisado_em is not null                  then 'vermelho'
    when e.status = 'notificada'                              then 'ambar'
    else 'cinza'
  end as semaforo
from escalas e
join tecnicos t on t.id = e.tecnico_id
left join locais l on l.id = e.local_id
left join lateral (
  select * from notificacoes where escala_id = e.id
  order by created_at desc limit 1
) n on true
left join lateral (
  select * from respostas where escala_id = e.id
  order by recebida_em desc limit 1
) r on true;

create or replace view vw_acoes_pendentes as
with agora as (
  select (now() at time zone fn_config('fuso')) as local_ts
),
alvo as (
  select
    e.id as escala_id,
    e.status,
    e.supervisor_avisado_em,
    t.nome as tecnico,
    t.telefone_e164 as telefone,
    n.id as notificacao_id,
    n.tentativa,
    n.status_envio,
    n.enviada_em
  from escalas e
  join tecnicos t on t.id = e.tecnico_id and t.ativo and t.opt_in
  left join lateral (
    select * from notificacoes where escala_id = e.id
    order by created_at desc limit 1
  ) n on true
  where e.status in ('agendada','notificada')
    and (e.data_servico + e.hora_inicio) > now()
)
select
  a.escala_id,
  a.status,
  a.tecnico,
  a.telefone,
  a.notificacao_id,
  a.tentativa,
  a.status_envio,
  a.enviada_em,
  case
    when a.notificacao_id is null
      then 'enviar_primeira'
    when a.tentativa >= fn_config_int('max_tentativas')
      then 'escalonar'
    when a.status_envio = 'falha'
      then 'reenviar_falha'
    when a.status_envio = 'enviada'
         and a.enviada_em < now() - make_interval(mins => fn_config_int('timeout_entrega_min'))
      then 'nao_recebeu'
    when a.status_envio in ('entregue','lida')
         and a.enviada_em < now() - make_interval(mins => fn_config_int('intervalo_reenvio_min'))
      then 'reenviar'
  end as acao,
  case
    when a.status_envio = 'lida'     then 'leu e nao respondeu'
    when a.status_envio = 'entregue' then 'recebeu e nao leu'
    when a.status_envio = 'enviada'  then 'nao recebeu'
    when a.status_envio = 'falha'    then 'falha no envio'
  end as diagnostico,
  (a.tentativa >= fn_config_int('avisar_supervisor_na')
   and a.supervisor_avisado_em is null) as avisar_supervisor
from alvo a, agora g
where g.local_ts::time between fn_config('janela_envio_inicio')::time
                           and fn_config('janela_envio_fim')::time;

comment on view vw_acoes_pendentes is
  'Linhas com acao nao nula precisam de tratamento pelo motor de escalonamento.';

alter table tecnicos       enable row level security;
alter table locais         enable row level security;
alter table escalas        enable row level security;
alter table notificacoes   enable row level security;
alter table respostas      enable row level security;
alter table ocorrencias    enable row level security;
alter table escala_eventos enable row level security;
alter table config         enable row level security;
