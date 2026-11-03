-- Matriz de acesso única (auditoria de 01/11, itens 1, 4, 6 e 8; reunião de 03/11). Exportação por lista branca: só
-- sai a tabela classificada em fn_exportar_tabelas, e o espelho assinado (conteúdo, assinatura e PDF) só para quem tem
-- rh_folhas; a plataforma e a exportação final do encerramento levam só o pacote comum. O ASO passa a ser documento de
-- saúde (tipos_documento.saude): o arquivo só abre para quem tem ve_saude, o papel leitura não o vê, o texto lido dele
-- não vai no pacote comum e o arquivo vai só no pacote de saúde. O checklist (volumes, cron, Vault e Evolution de todas
-- as contas) passa a ser só da plataforma. Os pacotes gerados antes desta correção vencem agora e são apagados.

set lock_timeout = '5s';

alter table interno.conta_exportacoes add column com_folha boolean not null default false;
alter table interno.tipos_documento add column saude boolean not null default false;

-- ASO é saúde: os que existem e os que forem cadastrados com esse nome (o painel ainda não tem a opção)
update interno.tipos_documento set saude = true where nome ~* '(^|[^a-z])aso([^a-z]|$)|atestado de sa[uú]de';
create or replace function interno.fn_tipo_documento_saude()
 returns trigger
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if new.nome ~* '(^|[^a-z])aso([^a-z]|$)|atestado de sa[uú]de' then new.saude := true; end if;
  return new;
end $function$;
create trigger tg_tipo_documento_saude before insert or update of nome on interno.tipos_documento
  for each row execute function interno.fn_tipo_documento_saude();

-- pacotes gerados antes da matriz: vencem agora (o motor manda apagar)
update interno.conta_exportacoes set expira_em = now() where estado = 'pronta';

CREATE OR REPLACE FUNCTION public.app_checklist_saude()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  perform interno.fn_exigir_plataforma();   -- volumes, cron, Vault e Evolution de todas as contas (auditoria, item 1)

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
  v_itens := v_itens || jsonb_build_object('grupo', 'Erros em tabelas', 'item', 'Programações vencidas sem envio',
    'estado', case when v_n = 0 then 'ok' else 'atencao' end,
    'detalhe', format('%s programações agendadas com início no passado e nenhuma mensagem enviada.', v_n));

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
end $function$
;

CREATE OR REPLACE FUNCTION public.app_checklist_testar()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_req  bigint;
  v_erro text;
begin
  perform interno.fn_exigir_plataforma();
  if exists (select 1 from saude_testes where criado_em > now() - interval '10 seconds') then
    -- teste recente: não repete a chamada externa, só devolve o que já está sendo lido
    return jsonb_build_object('enfileirado', false, 'recente', true, 'erro', null);
  end if;
  begin
    v_req := fn_evo_get('/instance/connectionState/' || fn_config('evolution_instancia'));
  exception when others then
    v_erro := left(sqlerrm, 200);
  end;
  insert into saude_testes (alvo, req_id, erro, criado_por) values ('evolution', v_req, v_erro, app_email());

  -- páginas públicas de status (Atlassian Statuspage): sem chave, só o campo status.indicator é lido
  insert into saude_testes (alvo, req_id, criado_por)
  select alvo, net.http_get(url := url, timeout_milliseconds := 5000), app_email()
    from (values ('status_supabase', 'https://status.supabase.com/api/v2/status.json'),
                 ('status_twilio',   'https://status.twilio.com/api/v2/status.json'),
                 ('status_github',   'https://www.githubstatus.com/api/v2/status.json'),
                 ('status_vercel',   'https://www.vercel-status.com/api/v2/status.json')) as t(alvo, url);

  -- guarda só os 20 testes mais recentes (5 linhas por teste)
  delete from saude_testes where id not in (select id from saude_testes order by id desc limit 100);
  return jsonb_build_object('enfileirado', v_req is not null, 'erro', v_erro);
end $function$
;

CREATE OR REPLACE FUNCTION public.app_documentos(p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_email text := app_exigir(array['admin','gestor','leitura']); v_papel text := fn_papel_na_conta(); v_saude boolean;
begin
  v_saude := fn_ve_saude(v_email);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', d.id, 'tecnico_id', d.tecnico_id, 'tecnico', t.nome,
    'tipo_documento_id', d.tipo_documento_id, 'documento', tp.nome,
    -- documento de saúde (ASO): sem ve_saude, a linha aparece sem o caminho do arquivo
    'caminho', case when coalesce(tp.saude, false) and not v_saude then null else d.caminho end,
    'restrito', coalesce(tp.saude, false) and not v_saude,
    'nome_arquivo', d.nome_arquivo, 'mime', d.mime, 'tamanho_bytes', d.tamanho_bytes,
    'validade', d.validade, 'enviado_por', d.enviado_por, 'created_at', d.created_at)
    order by d.created_at desc)
    from documentos d join tecnicos t on t.id = d.tecnico_id
    left join tipos_documento tp on tp.id = d.tipo_documento_id
    where (p_tecnico is null or d.tecnico_id = p_tecnico) and t.conta_id = fn_conta_atual()
      and not (v_papel = 'leitura' and coalesce(tp.saude, false))), '[]'::jsonb);   -- leitura não vê ASO (auditoria, item 8)
end $function$
;

CREATE OR REPLACE FUNCTION public.app_pode_gerir_documento(p_nome text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
  select coalesce(fn_papel_na_conta() in ('admin','gestor'), false)
     and (coalesce(fn_config('mfa_obrigatorio'), 'false') <> 'true' or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2')
     and exists (select 1 from tecnicos t
                  where t.id::text = split_part(coalesce(p_nome, ''), '/', 1) and t.conta_id = fn_conta_atual())
     -- arquivo de saúde (ASO) só abre para quem tem ve_saude
     and (fn_ve_saude(app_email()) or not exists (select 1 from documentos d join tipos_documento tp on tp.id = d.tipo_documento_id
                                                  where d.caminho = p_nome and tp.saude))
$function$
;

drop function interno.fn_exportar_tabelas();
CREATE OR REPLACE FUNCTION interno.fn_exportar_tabelas()
 RETURNS TABLE(tabela text, colunas text[], chave text[], folha text[])
 LANGUAGE sql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
  -- lista branca (auditoria de 01/11): só entra a tabela listada aqui; tabela nova com conta_id fica fora até ser
  -- classificada nesta lista (o T85 recusa tabela de conta sem classificação). 'folha' são as colunas que só saem para
  -- quem tem rh_folhas (o espelho assinado); para os outros, vão vazias
  with lista(tabela) as (values
      ('alertas_enviados'),
      ('carga_aceites'),
      ('carga_atribuicoes'),
      ('cargas_horarias'),
      ('conta_canais'),
      ('conta_exportacao_baixas'),
      ('conta_exportacoes'),
      ('conta_membros'),
      ('conta_modulos'),
      ('convites'),
      ('documentos'),
      ('dossie_geracoes'),
      ('empresas'),
      ('escala_eventos'),
      ('escalas'),
      ('habilidades'),
      ('ligacoes'),
      ('locais'),
      ('log_exclusoes'),
      ('notificacoes'),
      ('ocorrencias'),
      ('painel_mfa_log'),
      ('painel_rh_folhas_log'),
      ('painel_ve_saude_log'),
      ('ponto_abonos'),
      ('ponto_acessos'),
      ('ponto_afd_geracoes'),
      ('ponto_ajustes'),
      ('ponto_anexo_acessos'),
      ('ponto_anexos_descartados'),
      ('ponto_ciencias'),
      ('ponto_codigos'),
      ('ponto_conversas'),
      ('ponto_documento_registros'),
      ('ponto_documento_sequencia'),
      ('ponto_documento_verificacoes'),
      ('ponto_espelho_acessos'),
      ('ponto_espelho_pdfs'),
      ('ponto_espelho_sequencia'),
      ('ponto_espelhos'),
      ('ponto_folha_fechamentos'),
      ('ponto_he_autorizacoes'),
      ('ponto_justificativa_anexos'),
      ('ponto_justificativas'),
      ('ponto_marcacoes'),
      ('ponto_nsr'),
      ('ponto_sessoes'),
      ('programacao_aceites'),
      ('respostas'),
      ('tecnico_documentos'),
      ('tecnico_habilidades'),
      ('tecnicos'),
      ('times'),
      ('tipo_atividade_documentos'),
      ('tipo_atividade_requisitos'),
      ('tipos_atividade'),
      ('tipos_documento'),
      ('usuarios_excluidos'),
      ('webhook_eventos'))
  select c.relname::text,
         array(select a.attname::text from pg_attribute a
                where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                  and a.atttypid <> 'bytea'::regtype
                  and a.attname not in ('segredo', 'webhook_segredo', 'token_hash', 'codigo_hash', 'assinatura_chave',
                                        'envio_req', 'http_req_id', 'webhook_req', 'vig_req')
                  and not (c.relname = 'ponto_conversas' and a.attname = 'dados')   -- pedido em andamento (pode ser de saúde)
                  and not (c.relname = 'conta_canais' and a.attname in ('url', 'instancia'))   -- endereço do nosso servidor
                order by a.attnum),
         array(select a.attname::text from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
                where i.indrelid = c.oid and i.indisprimary order by array_position(i.indkey::int2[], a.attnum)),
         case when c.relname = 'ponto_espelhos'
              then array['conteudo', 'conteudo_texto', 'assinatura_png', 'assinatura_origem', 'assinatura_sha256']
              else '{}'::text[] end
    from lista l join pg_class c on c.relname = l.tabela and c.relnamespace = 'interno'::regnamespace
   where c.relkind in ('r', 'p') and not c.relispartition
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'conta_id' and not a.attisdropped)
   order by 1;
$function$
;

CREATE OR REPLACE FUNCTION interno.fn_exportar_csv(p_token text, p_id uuid, p_tabela text, p_offset integer, p_limite integer)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_conta uuid;
  v_folha boolean;
  t record;
  v text;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select conta_id, com_folha into v_conta, v_folha from conta_exportacoes where id = p_id and estado = 'gerando';
  if v_conta is null then raise exception 'exportação fora de andamento'; end if;
  select * into t from fn_exportar_tabelas() x where x.tabela = p_tabela;
  if not found then raise exception 'tabela fora da exportação'; end if;
  -- saúde com a máscara do painel: o motivo vira 'saude' e os textos da justificativa ficam vazios
  execute format('select string_agg(l, E''\n'' order by n) from (select row_number() over () as n, concat_ws('','', %s) as l
                    from (select * from interno.%I where conta_id = $1 order by %s limit $2 offset $3) z) y',
                 (select string_agg(case
                     -- espelho assinado: só para quem tem rh_folhas
                     when c = any (t.folha) and not v_folha then '''""'''
                     -- texto lido do documento de saúde (ASO): fora do pacote comum
                     when p_tabela = 'documentos' and c = 'ocr_texto'
                       then 'interno.fn_csv(case when exists (select 1 from interno.tipos_documento tp where tp.id = z.tipo_documento_id and tp.saude) then null else interno.fn_csv_texto(z.ocr_texto) end)'
                     when p_tabela = 'ponto_justificativas' and c = 'motivo'
                       then 'interno.fn_csv(case when interno.fn_motivo_saude(z.motivo) then ''saude'' else z.motivo end)'
                     when p_tabela = 'ponto_justificativas' and c in ('observacao', 'resposta', 'alerta_limite')
                       then format('interno.fn_csv(case when interno.fn_motivo_saude(z.motivo) then null else z.%I::text end)', c)
                     -- texto livre: célula que começa com = + - @ (ou tab, CR) ganha um apóstrofo, para a planilha não executar
                     when exists (select 1 from pg_attribute a where a.attrelid = ('interno.' || p_tabela)::regclass and a.attname = c
                                    and a.atttypid in ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype))
                       then format('interno.fn_csv(interno.fn_csv_texto(z.%I))', c)
                     else format('interno.fn_csv(z.%I::text)', c) end, ', ') from unnest(t.colunas) c),
                 p_tabela,
                 (select string_agg(format('%I', c), ', ') from unnest(t.chave) c))
    into v using v_conta, least(greatest(coalesce(p_limite, 5000), 1), 20000), greatest(coalesce(p_offset, 0), 0);
  return v;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_exportar_arquivos(p_token text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare e conta_exportacoes;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id and estado = 'gerando';
  if not found then raise exception 'exportação fora de andamento'; end if;
  return jsonb_build_object(
    'espelhos', coalesce((select jsonb_agg(jsonb_build_object('id', p.espelho_id,
        'nome', 'espelhos/' || to_char(s.competencia, 'YYYY-MM') || '_' || regexp_replace(lower(translate(t.nome, 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ', 'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')), '[^a-z0-9]+', '_', 'g')
                || '_v' || s.versao || '_' || left(s.id::text, 8) || '.pdf') order by s.competencia, t.nome)
      from ponto_espelho_pdfs p join ponto_espelhos s on s.id = p.espelho_id join tecnicos t on t.id = s.tecnico_id
     where p.conta_id = e.conta_id and p.pdf is not null and e.com_folha), '[]'::jsonb),   -- espelho assinado: só com rh_folhas
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('caminho', d.caminho,
        'nome', 'documentos/' || left(d.id::text, 8) || '_' || regexp_replace(coalesce(d.nome_arquivo, 'arquivo'), '[^A-Za-z0-9._-]+', '_', 'g'))
        order by d.created_at)
      from documentos d where d.conta_id = e.conta_id and d.caminho is not null
       and not exists (select 1 from tipos_documento tp where tp.id = d.tipo_documento_id and tp.saude)), '[]'::jsonb),
    -- documento de saúde (ASO): só no pacote de saúde
    'documentos_saude', case when e.com_saude then coalesce((select jsonb_agg(jsonb_build_object('caminho', d.caminho,
        'nome', 'saude/documentos/' || left(d.id::text, 8) || '_' || regexp_replace(coalesce(d.nome_arquivo, 'arquivo'), '[^A-Za-z0-9._-]+', '_', 'g'))
        order by d.created_at)
      from documentos d join tipos_documento tp on tp.id = d.tipo_documento_id
     where d.conta_id = e.conta_id and d.caminho is not null and tp.saude), '[]'::jsonb) else '[]'::jsonb end,
    'afd', coalesce((select jsonb_agg(m.id order by m.razao_social) from empresas m
                      where m.conta_id = e.conta_id and m.empregadora
                        and exists (select 1 from ponto_marcacoes k where k.empresa_id = m.id)), '[]'::jsonb),
    'anexos', case when e.com_saude then coalesce((select jsonb_agg(jsonb_build_object('id', x.id,
        'nome', 'saude/anexos/' || left(x.justificativa_id::text, 8) || '_' || left(x.id::text, 8) || '.' ||
                case x.tipo when 'application/pdf' then 'pdf' when 'image/png' then 'png' else 'jpg' end) order by x.created_at)
      from ponto_justificativa_anexos x where x.conta_id = e.conta_id), '[]'::jsonb) else '[]'::jsonb end);
end $function$
;

drop function interno.fn_exportar_pedir(uuid, text, text, boolean);
CREATE OR REPLACE FUNCTION interno.fn_exportar_pedir(p_conta uuid, p_autor text, p_origem text, p_com_saude boolean, p_com_folha boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext('exportacao:' || p_conta));
  -- o encerramento nunca é barrado pela exportação: a final sai sempre
  if p_origem <> 'encerramento' and exists (select 1 from conta_exportacoes where conta_id = p_conta and estado in ('pendente', 'gerando')
               and criado_em > now() - interval '30 minutes') then
    raise exception 'Já há uma exportação desta conta em andamento. Aguarde alguns minutos.';
  end if;
  if p_origem = 'admin' and exists (select 1 from conta_exportacoes where conta_id = p_conta and origem = 'admin'
                                      and estado = 'pronta' and criado_em > now() - interval '1 day') then
    raise exception 'Já há uma exportação de hoje. Baixe a que está pronta ou peça de novo amanhã.';
  end if;
  insert into conta_exportacoes (conta_id, pedido_por, origem, com_saude, com_folha)
  values (p_conta, p_autor, p_origem, coalesce(p_com_saude, false), coalesce(p_com_folha, false))
    returning id into v_id;
  perform fn_exportacao_chamar(jsonb_build_object('id', v_id));
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.app_conta_exportar()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_email text := app_exigir(array['admin']);
begin
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'Ative e confirme a verificação em duas etapas para exportar os dados da conta.';
  end if;
  return interno.fn_exportar_pedir(interno.fn_conta_atual(), v_email, 'admin', interno.fn_ve_saude(v_email), interno.fn_rh_folhas(v_email));
end $function$
;

CREATE OR REPLACE FUNCTION public.app_plataforma_exportar_conta(p_conta uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_ator text := interno.fn_exigir_plataforma();
begin
  if not exists (select 1 from interno.contas where id = p_conta and estado in ('ativa', 'encerrada')) then
    raise exception 'Conta não encontrada ou já apagada.';
  end if;
  -- a plataforma leva só o pacote comum: nem espelho assinado nem saúde (são do cliente)
  return interno.fn_exportar_pedir(p_conta, v_ator, 'plataforma', false, false);
end $function$
;

CREATE OR REPLACE FUNCTION public.app_plataforma_encerrar_conta(p_conta uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_ator   text := interno.fn_exigir_plataforma();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  c        interno.contas;
  v_sess   int;
begin
  if p_conta = '00000000-0000-0000-0000-000000000001' then
    raise exception 'A conta da operadora não pode ser encerrada.';
  end if;
  if length(v_motivo) not between 3 and 300 then
    raise exception 'Informe o motivo do encerramento (3 a 300 caracteres).';
  end if;
  select * into c from interno.contas where id = p_conta for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if c.estado <> 'ativa' then raise exception 'A conta já está encerrada.'; end if;
  update interno.contas set ativa = false, estado = 'encerrada', encerrada_em = now(), apagar_em = now() + interval '30 days'
   where id = p_conta returning * into c;
  -- app do ponto: sessões encerradas e códigos vencidos já agora
  update interno.ponto_sessoes s set encerrada_em = now(), motivo = 'conta encerrada'
    from interno.tecnicos t where t.id = s.tecnico_id and t.conta_id = p_conta and s.encerrada_em is null;
  get diagnostics v_sess = row_count;
  update interno.ponto_codigos k set expira_em = now()
    from interno.tecnicos t where t.id = k.tecnico_id and t.conta_id = p_conta and k.usado_em is null and k.expira_em > now();
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'encerrar_conta', p_conta, jsonb_build_object('motivo', v_motivo, 'apagar_em', c.apagar_em, 'sessoes_ponto', v_sess));
  -- exportação final automática (F8c, decisão 129): o link vai por e-mail aos administradores da conta
  -- a final vai por e-mail a todos os administradores: só o pacote comum
  perform interno.fn_exportar_pedir(p_conta, v_ator, 'encerramento', false, false);
  return jsonb_build_object('estado', c.estado, 'apagar_em', c.apagar_em);
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_exportacao_dados(p_token text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare e conta_exportacoes;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id for update;
  if not found or e.tentativas >= 3
     or not (e.estado = 'pendente' or (e.estado = 'gerando' and e.iniciado_em < now() - interval '15 minutes')) then
    return null;
  end if;
  update conta_exportacoes set estado = 'gerando', iniciado_em = now(), tentativas = tentativas + 1 where id = p_id;
  return jsonb_build_object('conta', e.conta_id, 'origem', e.origem, 'com_saude', e.com_saude, 'com_folha', e.com_folha,
    'nome', (select nome from contas where id = e.conta_id),
    'tabelas', (select jsonb_agg(jsonb_build_object('tabela', t.tabela, 'colunas', t.colunas)) from fn_exportar_tabelas() t));
end $function$
;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  execute 'revoke execute on all functions in schema interno from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
