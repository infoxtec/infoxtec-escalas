-- 10 | Dispatcher reescrito: texto completo, confirmacao da Evolution, falhas e supervisor
-- Nesta copia, fn_msg_escala e fn_dispatcher_whatsapp aparecem so na migration 11, que as substituiu.

alter table notificacoes add column if not exists http_req_id bigint;
create index if not exists idx_notif_enfileirada
  on notificacoes (http_req_id) where status_envio = 'enfileirada';

insert into config (chave, valor, descricao) values
  ('webhook_ativo', 'false',
   'false: so primeiro envio e reenvio por falha da API. true: lembretes por falta de resposta e alerta ao supervisor na 2a tentativa'),
  ('envios_por_execucao', '3',
   'Maximo de mensagens por execucao do dispatcher (roda 1x por minuto): espaca os envios')
on conflict (chave) do nothing;

-- Falha da API so e reenviada depois do timeout de entrega
create or replace view vw_acoes_pendentes as
with agora as (
  select (now() at time zone fn_config('fuso')) as local_ts
),
alvo as (
  select
    e.id as escala_id, e.status, e.supervisor_avisado_em,
    t.nome as tecnico, t.telefone_e164 as telefone,
    n.id as notificacao_id, n.tentativa, n.status_envio, n.enviada_em
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
  a.escala_id, a.status, a.tecnico, a.telefone, a.notificacao_id,
  a.tentativa, a.status_envio, a.enviada_em,
  case
    when a.notificacao_id is null then 'enviar_primeira'
    when a.tentativa >= fn_config_int('max_tentativas') then 'escalonar'
    when a.status_envio = 'falha'
         and a.enviada_em < now() - make_interval(mins => fn_config_int('timeout_entrega_min'))
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

create or replace function fn_fmt_duracao(p_min int)
returns text language sql immutable as $$
  select case
    when p_min is null or p_min <= 0 then null
    when p_min < 60        then p_min || 'min'
    when p_min % 60 = 0    then (p_min / 60) || 'h'
    else (p_min / 60) || 'h' || lpad((p_min % 60)::text, 2, '0')
  end
$$;

create or replace function fn_msg_supervisor(p_escala_id uuid, p_diagnostico text, p_tentativa int)
returns text language plpgsql stable as $$
declare
  r record;
begin
  select e.data_servico, e.hora_inicio, t.nome as tecnico, t.telefone_e164,
         coalesce(l.nome, 'local a confirmar') as local_nome
    into r
  from escalas e
  join tecnicos t on t.id = e.tecnico_id
  left join locais l on l.id = e.local_id
  where e.id = p_escala_id;

  return '⚠️ *ESCALA SEM CONFIRMAÇÃO*' || E'\n\n'
    || 'Ligar para: ' || r.tecnico || ' — ' || r.telefone_e164 || E'\n'
    || 'Escala: ' || to_char(r.data_servico, 'DD/MM') || ' às ' || to_char(r.hora_inicio, 'HH24:MI')
    || ' — ' || r.local_nome || E'\n'
    || 'Situação: ' || coalesce(p_diagnostico, 'sem resposta') || E'\n'
    || 'Tentativas: ' || coalesce(p_tentativa, 0);
end $$;
