-- 39 | Fuso do motor, acesso aos documentos, exposicao de view e limpeza de logs
--
-- 1. Fuso: data_servico + hora_inicio e hora local da Bahia, mas era comparada com now() como
--    se fosse UTC (o servidor roda em UTC). Efeito: o motor considerava a escala "no passado"
--    3 horas antes do inicio. Escala criada para as proximas 3 horas nunca era enviada, e
--    lembretes, alerta ao supervisor e ligacao paravam 3 horas antes.
-- 2. Documentos: as politicas do bucket chamavam fn_papel, que o usuario logado nao pode
--    executar (e que, sem security definer, nao enxerga painel_usuarios). Resultado num banco
--    montado pelo repositorio: "permission denied for function fn_papel" ao abrir ou enviar.
-- 3. vw_ligacoes_pendentes tinha permissao para anon e authenticated (nome e telefone de
--    tecnicos). So nao vazava porque a view chama fn_config_int, que eles nao executam.
-- 4. Tabelas: RLS sem politica ja bloqueia leitura e escrita pela API, mas os privilegios
--    padrao do Supabase (inclusive TRUNCATE, que ignora RLS) continuavam concedidos.
-- 5. Limpeza: webhook_eventos, alertas_enviados e o historico do pg_cron cresciam sem limite.
--    A funcao e agendada em supabase/setup/cron.sql (uma vez por projeto).

-- 1. Comparar hora local com hora local ----------------------------------------------------
-- A hora atual no fuso da operacao e calculada uma vez (CTE agora) e comparada com a data e
-- a hora da escala, que ja sao locais. A Bahia nao tem horario de verao.

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
    and (e.data_servico + e.hora_inicio) > (select local_ts from agora)
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

create or replace view vw_ligacoes_pendentes as
with agora as (select (now() at time zone fn_config('fuso')) as local_ts)
select
  e.id as escala_id, t.id as tecnico_id, t.nome as tecnico, t.telefone_e164 as telefone,
  coalesce(n.tentativa, 0) as tentativas_whatsapp,
  (select count(*) from ligacoes l where l.escala_id = e.id) as ligacoes_feitas
from escalas e
join tecnicos t on t.id = e.tecnico_id and t.ativo and t.opt_in and not t.perfil_teste
left join lateral (select * from notificacoes where escala_id = e.id order by created_at desc limit 1) n on true
cross join agora g
where e.status = 'notificada'
  and (e.data_servico + e.hora_inicio) > g.local_ts
  and coalesce(n.tentativa, 0) >= fn_config_int('ligacao_apos_tentativas')
  and n.status_envio in ('enviada','entregue','lida')
  and not exists (select 1 from respostas r where r.escala_id = e.id)
  and (select count(*) from ligacoes l where l.escala_id = e.id) < fn_config_int('ligacao_max_por_escala')
  and not exists (select 1 from ligacoes l where l.escala_id = e.id
                    and (l.status in ('criada','discando')
                         or l.criada_em > now() - make_interval(mins => fn_config_int('ligacao_intervalo_min'))))
  and g.local_ts::time between fn_config('ligacao_janela_inicio')::time and fn_config('ligacao_janela_fim')::time;

-- 2. Acesso aos documentos pelo papel do usuario logado --------------------------------------

create or replace function app_pode_gerir_documentos()
returns boolean language sql stable security definer
set search_path = public, extensions as $$
  select coalesce(fn_papel(app_email()) in ('admin','gestor'), false)
$$;

drop policy if exists documentos_leitura on storage.objects;
drop policy if exists documentos_escrita on storage.objects;
drop policy if exists documentos_exclusao on storage.objects;
create policy documentos_leitura on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and app_pode_gerir_documentos());
create policy documentos_escrita on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and app_pode_gerir_documentos());
create policy documentos_exclusao on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and app_pode_gerir_documentos());

-- 3 e 4. Nada do schema public e acessivel direto pela API; o painel usa so funcoes app_* ------

revoke all on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;

-- 5. Limpeza de logs --------------------------------------------------------------------------

insert into config (chave, valor, descricao) values
  ('retencao_webhook_dias', '30', 'Dias de guarda do log de webhook (conteudo das mensagens recebidas)'),
  ('retencao_cron_dias',    '7',  'Dias de guarda do historico de execucao do pg_cron')
on conflict (chave) do nothing;

create or replace function fn_limpeza_logs()
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare v_webhook int; v_alertas int; v_cron int;
begin
  delete from webhook_eventos
   where recebido_em < now() - make_interval(days => coalesce(fn_config_int('retencao_webhook_dias'), 30));
  get diagnostics v_webhook = row_count;
  delete from alertas_enviados where data_ref < current_date - 90;
  get diagnostics v_alertas = row_count;
  delete from cron.job_run_details
   where end_time < now() - make_interval(days => coalesce(fn_config_int('retencao_cron_dias'), 7));
  get diagnostics v_cron = row_count;
  return jsonb_build_object('webhook_eventos', v_webhook, 'alertas_enviados', v_alertas, 'cron', v_cron);
end $$;

-- Permissoes: so as funcoes app_* ficam acessiveis ao usuario logado (decisao 12) -----------

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
