-- Migration 80 (12/10/2026): pendências das migrations 78 e 79.
-- 1. Checklist Sistema, grupo "Erros em tabelas", ganha "Supervisores e técnicos sem empresa" (decisão 69): supervisor ou técnico
--    ativo sem empresa vira falha quando houver mais de uma empresa ativa (antes disso, só informa).
-- 2. alerta_certificacoes_dow: a validação aceitava 0 a 6, mas o alerta compara com o dia ISO (1 = segunda
--    a 7 = domingo) e 0 desliga o alerta (docs/banco-de-dados.md). Passa a aceitar 0 a 7: o domingo vira
--    possível e nenhum valor gravado muda de sentido. Base: definições atuais da homologação.

create or replace function fn_validar_config()
returns trigger language plpgsql set search_path to 'public', 'extensions' as $function$
declare
  v text := coalesce(new.valor, '');
begin
  begin
    if new.chave in ('envios_por_execucao','max_tentativas','avisar_supervisor_na','intervalo_reenvio_min',
                     'timeout_entrega_min','motor_alerta_min','jornada_min','intervalo_min','intervalo_apos_min',
                     'antecedencia_minima_min','certificacao_aviso_dias','documento_tamanho_max_mb',
                     'ligacao_apos_tentativas','ligacao_intervalo_min','ligacao_max_por_escala',
                     'ligacao_por_execucao','voz_timeout_dtmf','retencao_webhook_dias','retencao_cron_dias',
                     'retencao_documentos_anos','retencao_payload_dias','conclusao_automatica_min',
                     'banco_alerta_mb','alerta_certificacoes_dow') then
      if v !~ '^\d+$' then raise exception 'inteiro'; end if;
      -- 0 desliga; 1 (segunda) a 7 (domingo), o mesmo dia ISO que fn_alerta_certificacoes compara como
      -- texto: um dígito só ('07' passaria no inteiro e nunca dispararia)
      if new.chave = 'alerta_certificacoes_dow' and v !~ '^[0-7]$' then raise exception 'dia'; end if;
    elsif new.chave = 'hora_noturna_min' then
      if v::numeric <= 0 then raise exception 'positivo'; end if;
    elsif new.chave in ('janela_envio_inicio','janela_envio_fim','alerta_escala_aviso','alerta_escala_prazo',
                        'alerta_certificacoes_hora','ligacao_janela_inicio','ligacao_janela_fim',
                        'noturno_inicio','noturno_fim') then
      if v !~ '^\d{2}:\d{2}$' then raise exception 'hora'; end if;
      perform v::time;
    elsif new.chave in ('webhook_ativo','usar_botoes','ligacao_ativa','sem_escala_incluir_supervisores') then
      if v not in ('true','false') then raise exception 'booleano'; end if;
    elsif new.chave = 'fuso' then
      if not exists (select 1 from pg_timezone_names where name = v) then raise exception 'fuso'; end if;
    elsif new.chave = 'alerta_dias_semana' then
      if v !~ '^[1-7](,[1-7])*$' then raise exception 'dias'; end if;
    elsif new.chave = 'alerta_tecnico_telefones' then
      if v <> '' and v !~ '^\d{12,13}(\s*,\s*\d{12,13})*$' then raise exception 'telefones'; end if;
    elsif new.chave = 'monitor_ping_url' then
      if v <> '' and v !~ '^https://' then raise exception 'url'; end if;
    end if;
  exception when others then
    raise exception 'Valor inválido para %: "%"', new.chave, new.valor
      using hint = case new.chave
        when 'alerta_dias_semana' then 'Use dias de 1 (segunda) a 7, separados por vírgula: 1,2,3,4,5'
        when 'alerta_certificacoes_dow' then 'Use 1 (segunda) a 7 (domingo); 0 desliga o alerta'
        when 'alerta_tecnico_telefones' then 'Use telefones com DDI e DDD, só números, separados por vírgula: 5571999999999'
        when 'fuso' then 'Use um fuso válido, por exemplo America/Bahia'
        else 'Confira o formato: inteiro, hora HH:MM ou true/false' end;
  end;
  return new;
end $function$;

update config set descricao = 'Dia da semana do alerta de documentos (ISO: 1 = segunda a 7 = domingo; 0 desliga)'
 where chave = 'alerta_certificacoes_dow';

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
  v_st     record;
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
  -- tarefas obrigatórias (supabase/setup/cron.sql): faltar uma não quebra o deploy, quebra a operação
  -- (a limpeza-logs ficou sem agendar na produção até 11/10). A homologação não tem cron: só informa
  select string_agg(t.nome, ', ' order by t.nome) into v_estado
    from unnest(array['dispatcher-whatsapp', 'vigia-motor', 'limpeza-logs', 'ponto-lembrete-almoco', 'ponto-geo']) t(nome)
   where not exists (select 1 from cron.job j where j.jobname = t.nome and j.active);
  v_itens := v_itens || jsonb_build_object('grupo', 'Supabase', 'item', 'Tarefas agendadas (cron)',
    'estado', case when v_m = 0 and coalesce(fn_config('ambiente'), 'producao') <> 'producao' then 'info'
                   when v_estado is not null then 'falha'
                   when v_txt::int > 0 then 'atencao' else 'ok' end,
    'detalhe', format('%s de %s tarefas ativas; %s execuções com falha nas últimas 24 h.', v_n, v_m, v_txt)
               || case when v_estado is not null then ' Faltando (ver supabase/setup/cron.sql): ' || v_estado || '.' else '' end);
  v_estado := null;

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
      'estado', 'info', 'detalhe', 'Ainda não testada. Use "Testar agora".');
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

  -- ---------------------------------------------------------------- Páginas públicas de status
  for v_st in select * from (values
      ('status_supabase', 'Supabase', 'Página de status do Supabase'),
      ('status_twilio',   'Twilio (ligações)', 'Página de status da Twilio'),
      ('status_github',   'GitHub', 'Página de status do GitHub'),
      ('status_vercel',   'Vercel', 'Página de status da Vercel')) as t(alvo, grupo, item)
  loop
    v_estado := null; v_txt := null;
    -- sem linha, o "select into" deixa as variáveis nulas: nada sobra da volta anterior do laço
    select * into v_teste from saude_testes where alvo = v_st.alvo order by id desc limit 1;
    select status_code, content into v_resp from net._http_response where id = v_teste.req_id;
    begin
      v_estado := v_resp.content::jsonb #>> '{status,indicator}';
      v_txt    := left(v_resp.content::jsonb #>> '{status,description}', 80);
    exception when others then
      v_estado := null;
    end;
    v_itens := v_itens || jsonb_build_object('grupo', v_st.grupo, 'item', v_st.item,
      'estado', case v_estado when 'none' then 'ok' when 'minor' then 'atencao'
                              when 'major' then 'falha' when 'critical' then 'falha' else 'info' end,
      'detalhe', case when v_teste.id is null then 'Ainda não consultada. Use "Testar agora".'
                      when v_estado = 'none' then 'Todos os sistemas operando.'
                      when v_estado is not null then coalesce(v_txt, 'Incidente em andamento.')
                      when v_resp is null then 'Aguardando resposta ou resposta expirada; teste de novo.'
                      else format('Não foi possível ler a página (HTTP %s).', coalesce(v_resp.status_code::text, '-')) end);
  end loop;

  -- ---------------------------------------------------------------- Cadastro sem empresa (decisão 69)
  -- supervisor sem empresa recebe avisos de todas; técnico sem empresa avisa todos os supervisores.
  -- Com uma empresa só, não vaza nada (informa); com duas ou mais, nomes de um cliente chegam ao outro
  -- supervisor de teste também recebe os avisos (fn_avisar_supervisores não filtra perfil_teste): conta
  select count(*) filter (where is_supervisor), count(*) filter (where not is_supervisor and not perfil_teste)
    into v_n, v_m from tecnicos where ativo and empresa_id is null;
  v_itens := v_itens || jsonb_build_object('grupo', 'Erros em tabelas', 'item', 'Supervisores e técnicos sem empresa',
    'estado', case when v_n + v_m = 0 then 'ok'
                   when (select count(*) from empresas where ativo) > 1 then 'falha' else 'info' end,
    'detalhe', case when v_n + v_m = 0 then 'Todos os supervisores e técnicos ativos têm empresa.'
                    else format('%s supervisor(es) e %s técnico(s) ativos sem empresa. Cadastre antes do 2º cliente: '
                                || 'supervisor sem empresa recebe avisos de todas.', v_n, v_m) end);

  return jsonb_build_object('gerado_em', now(), 'itens', v_itens);
end $$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
