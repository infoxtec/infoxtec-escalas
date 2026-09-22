-- 04 | Views de apoio ao painel (KPIs e linha do tempo) + fn_set_ator

create or replace view vw_resumo_dia as
select
  e.data_servico,
  count(*)                                            as total,
  count(*) filter (where e.status = 'confirmada')     as confirmadas,
  count(*) filter (where e.status = 'recusada')       as recusadas,
  count(*) filter (where e.status = 'notificada')     as aguardando,
  count(*) filter (where e.status = 'agendada')       as nao_enviadas,
  count(*) filter (where e.supervisor_avisado_em is not null) as criticas,
  round(
    100.0 * count(*) filter (where e.status = 'confirmada')
    / nullif(count(*) filter (where e.status <> 'rascunho'), 0)
  , 0) as pct_confirmacao
from escalas e
where e.status <> 'cancelada'
group by e.data_servico;

create or replace view vw_linha_do_tempo as
select
  ev.escala_id,
  ev.created_at,
  ev.evento,
  ev.status_anterior,
  ev.status_novo,
  ev.ator
from escala_eventos ev
union all
select n.escala_id, n.enviada_em, 'mensagem_enviada', null, null, 'sistema'
  from notificacoes n where n.enviada_em is not null
union all
select n.escala_id, n.entregue_em, 'entregue_no_aparelho', null, null, 'whatsapp'
  from notificacoes n where n.entregue_em is not null
union all
select n.escala_id, n.lida_em, 'lida', null, null, 'whatsapp'
  from notificacoes n where n.lida_em is not null
union all
select r.escala_id, r.recebida_em, 'resposta_' || r.tipo::text, null, null, 'tecnico'
  from respostas r;

create or replace function fn_set_ator(p_ator text)
returns void language sql volatile as $$
  select set_config('app.ator', p_ator, false)
$$;
