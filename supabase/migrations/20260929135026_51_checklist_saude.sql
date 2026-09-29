-- 51. Administração do Sistema > Checklist: estado de saúde da plataforma num só lugar.
-- Só leitura de metadados e contagens (nenhum dado de técnico sai daqui), só para admin.
-- O teste ao vivo da Evolution vai pelo pg_net: app_checklist_testar() enfileira a chamada e
-- app_checklist_saude() lê a resposta na atualização seguinte.

create table if not exists saude_testes (
  id         bigserial primary key,
  alvo       text not null,
  req_id     bigint,
  erro       text,
  criado_em  timestamptz not null default now(),
  criado_por text
);
alter table saude_testes enable row level security;

create or replace function app_checklist_testar()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_req  bigint;
  v_erro text;
begin
  perform app_exigir(array['admin']);
  if exists (select 1 from saude_testes where criado_em > now() - interval '10 seconds') then
    return jsonb_build_object('enfileirado', false, 'erro', 'Aguarde alguns segundos entre um teste e outro.');
  end if;
  begin
    v_req := fn_evo_get('/instance/connectionState/' || fn_config('evolution_instancia'));
  exception when others then
    v_erro := left(sqlerrm, 200);
  end;
  insert into saude_testes (alvo, req_id, erro, criado_por) values ('evolution', v_req, v_erro, app_email());
  -- guarda só os 20 testes mais recentes
  delete from saude_testes where id not in (select id from saude_testes order by id desc limit 20);
  return jsonb_build_object('enfileirado', v_req is not null, 'erro', v_erro);
end $$;

create or replace function app_checklist_saude()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_itens  jsonb := '[]'::jsonb;
  v_fuso   text := coalesce(fn_config('fuso'), 'America/Bahia');
  v_n      int;
  v_m      int;
  v_txt    text;
  v_ts     timestamptz;
  v_motor  motor_estado;
  v_teste  saude_testes;
  v_resp   record;
  v_estado text;
  v_mb     int;
  v_lim_mb int := coalesce(fn_config_int('banco_alerta_mb'), 400);
begin
  perform app_exigir(array['admin']);

  -- ---------------------------------------------------------------- Supabase
  v_mb := (pg_database_size(current_database()) / 1024 / 1024)::int;
  -- dinâmico: o esquema supabase_migrations só existe nos projetos Supabase (não no banco do CI)
  begin
    execute 'select max(version) from supabase_migrations.schema_migrations' into v_txt;
  exception when undefined_table or invalid_schema_name then
    v_txt := 'desconhecida';
  end;
  v_itens := v_itens || jsonb_build_object('grupo', 'Supabase', 'item', 'Banco de dados',
    'estado', case when v_mb >= v_lim_mb then 'atencao' else 'ok' end,
    'detalhe', format('Respondendo. %s MB usados (alerta em %s MB). Última migration: %s.', v_mb, v_lim_mb, v_txt));

  select * into v_motor from motor_estado where id;
  v_n := floor(extract(epoch from now() - v_motor.ultima_execucao_ok) / 60)::int;
  v_itens := v_itens || jsonb_build_object('grupo', 'Supabase', 'item', 'Motor de envio',
    'estado', case when v_motor.ultima_execucao_ok is null then 'atencao'
                   when v_n <= coalesce(fn_config_int('motor_alerta_min'), 5) then 'ok' else 'falha' end,
    'detalhe', case when v_motor.ultima_execucao_ok is null then 'Nunca executou neste ambiente.'
                    else format('Última execução completa há %s min.', v_n) end);

  select count(*) filter (where active), count(*) into v_n, v_m from cron.job;
  select count(*) into v_txt from cron.job_run_details
   where status = 'failed' and start_time > now() - interval '24 hours';
  v_itens := v_itens || jsonb_build_object('grupo', 'Supabase', 'item', 'Tarefas agendadas (cron)',
    'estado', case when v_m = 0 then 'info' when v_txt::int > 0 then 'atencao' else 'ok' end,
    'detalhe', format('%s de %s tarefas ativas; %s execuções com falha nas últimas 24 h.', v_n, v_m, v_txt));

  select count(*) filter (where error_msg is not null or status_code >= 400), count(*)
    into v_n, v_m from net._http_response where created > now() - interval '1 hour';
  v_itens := v_itens || jsonb_build_object('grupo', 'Supabase', 'item', 'Chamadas externas (pg_net)',
    'estado', case when v_n = 0 then 'ok' when v_n * 2 < v_m then 'atencao' else 'falha' end,
    'detalhe', format('%s de %s chamadas com erro na última hora.', v_n, v_m));

  -- ---------------------------------------------------------------- Evolution
  v_itens := v_itens || jsonb_build_object('grupo', 'Evolution (WhatsApp)', 'item', 'Configuração',
    'estado', case when fn_config('evolution_url') is not null and fn_config('evolution_instancia') is not null
                    and exists (select 1 from vault.secrets where name = 'EVOLUTION_API_KEY') then 'ok' else 'falha' end,
    'detalhe', format('Endereço %s, instância %s, chave no Vault: %s.',
                 coalesce(fn_config('evolution_url'), '(vazio)'), coalesce(fn_config('evolution_instancia'), '(vazia)'),
                 case when exists (select 1 from vault.secrets where name = 'EVOLUTION_API_KEY') then 'sim' else 'não' end));

  select * into v_teste from saude_testes where alvo = 'evolution' order by id desc limit 1;
  if v_teste.id is null then
    v_itens := v_itens || jsonb_build_object('grupo', 'Evolution (WhatsApp)', 'item', 'Conexão da instância',
      'estado', 'info', 'detalhe', 'Ainda não testada. Use "Testar Evolution agora".');
  elsif v_teste.erro is not null then
    v_itens := v_itens || jsonb_build_object('grupo', 'Evolution (WhatsApp)', 'item', 'Conexão da instância',
      'estado', 'falha', 'detalhe', format('Teste de %s não saiu: %s', to_char(v_teste.criado_em at time zone v_fuso, 'DD/MM HH24:MI'), v_teste.erro));
  else
    select status_code, error_msg, content into v_resp
      from net._http_response where id = v_teste.req_id;
    -- só o código HTTP e o campo state: o corpo cru nunca vai para a tela
    begin
      v_estado := v_resp.content::jsonb #>> '{instance,state}';
    exception when others then
      v_estado := null;
    end;
    v_itens := v_itens || jsonb_build_object('grupo', 'Evolution (WhatsApp)', 'item', 'Conexão da instância',
      'estado', case when v_resp is null then 'info'
                     when v_resp.status_code = 200 and v_estado = 'open' then 'ok' else 'falha' end,
      'detalhe', format('Teste de %s: %s', to_char(v_teste.criado_em at time zone v_fuso, 'DD/MM HH24:MI'),
                   case when v_resp is null and v_teste.criado_em < now() - interval '5 minutes'
                          then 'resposta expirada; teste de novo.'
                        when v_resp is null then 'aguardando resposta (atualize em alguns segundos).'
                        when v_resp.status_code = 200 and v_estado = 'open' then 'instância conectada (open).'
                        when v_resp.status_code is null then format('sem resposta do servidor (%s).', coalesce(v_resp.error_msg, 'erro de rede'))
                        else format('HTTP %s, estado %s.', v_resp.status_code, coalesce(v_estado, 'desconhecido')) end));
  end if;

  select max(recebido_em) into v_ts from webhook_eventos;
  v_itens := v_itens || jsonb_build_object('grupo', 'Evolution (WhatsApp)', 'item', 'Webhook (mensagens recebidas)',
    'estado', case when v_ts > now() - interval '24 hours' then 'ok' else 'atencao' end,
    'detalhe', case when v_ts is null then 'Nenhum evento recebido.'
                    else format('Último evento em %s.', to_char(v_ts at time zone v_fuso, 'DD/MM HH24:MI')) end);

  select count(*) filter (where status_envio = 'falha'), count(*) into v_n, v_m
    from notificacoes where created_at > now() - interval '24 hours';
  v_itens := v_itens || jsonb_build_object('grupo', 'Evolution (WhatsApp)', 'item', 'Envios nas últimas 24 h',
    'estado', case when v_n = 0 then 'ok' when v_n * 2 < v_m then 'atencao' else 'falha' end,
    'detalhe', format('%s envios, %s com falha.', v_m, v_n));

  -- ---------------------------------------------------------------- Erros em tabelas
  select count(*) into v_n from escalas e
   where e.status = 'agendada' and not e.teste
     and ((e.data_servico + e.hora_inicio) at time zone v_fuso) < now()
     and not exists (select 1 from notificacoes n where n.escala_id = e.id);
  v_itens := v_itens || jsonb_build_object('grupo', 'Erros em tabelas', 'item', 'Escalas vencidas sem envio',
    'estado', case when v_n = 0 then 'ok' else 'atencao' end,
    'detalhe', format('%s escalas agendadas com início no passado e nenhuma mensagem enviada.', v_n));

  select count(*), max(erro_codigo) into v_n, v_txt from notificacoes
   where status_envio = 'falha' and created_at > now() - interval '7 days';
  v_itens := v_itens || jsonb_build_object('grupo', 'Erros em tabelas', 'item', 'Notificações com falha (7 dias)',
    'estado', case when v_n = 0 then 'ok' else 'atencao' end,
    'detalhe', case when v_n = 0 then 'Nenhuma.' else format('%s falhas (código mais alto: %s).', v_n, v_txt) end);

  select count(*) into v_n from webhook_eventos
   where recebido_em > now() - interval '24 hours' and resultado ilike '%erro%';
  v_itens := v_itens || jsonb_build_object('grupo', 'Erros em tabelas', 'item', 'Webhook com erro (24 h)',
    'estado', case when v_n = 0 then 'ok' else 'atencao' end,
    'detalhe', format('%s eventos recebidos que o banco não conseguiu tratar.', v_n));

  -- ---------------------------------------------------------------- Twilio
  select count(*) into v_n from vault.secrets where name in ('TWILIO_ACCOUNT_SID', 'TWILIO_AUTH_TOKEN', 'VOZ_TOKEN');
  v_itens := v_itens || jsonb_build_object('grupo', 'Twilio (ligações)', 'item', 'Configuração',
    'estado', case when coalesce(fn_config('ligacao_ativa'), 'false') <> 'true' then 'info'
                   when v_n = 3 then 'ok' else 'falha' end,
    'detalhe', format('Ligações %s; %s de 3 credenciais no Vault.',
                 case when coalesce(fn_config('ligacao_ativa'), 'false') = 'true' then 'ligadas' else 'desligadas' end, v_n));

  select count(*) filter (where erro is not null or status in ('failed', 'busy', 'no-answer', 'canceled')),
         count(*), max(criada_em)
    into v_n, v_m, v_ts from ligacoes where criada_em > now() - interval '7 days';
  v_itens := v_itens || jsonb_build_object('grupo', 'Twilio (ligações)', 'item', 'Ligações (7 dias)',
    'estado', case when v_m = 0 or v_n = 0 then 'ok' when v_n * 2 < v_m then 'atencao' else 'falha' end,
    'detalhe', case when v_m = 0 then 'Nenhuma ligação nos últimos 7 dias.'
                    else format('%s ligações, %s sem sucesso. Última em %s.', v_m, v_n, to_char(v_ts at time zone v_fuso, 'DD/MM HH24:MI')) end);

  return jsonb_build_object('gerado_em', now(), 'evolution_url', fn_config('evolution_url'), 'itens', v_itens);
end $$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
