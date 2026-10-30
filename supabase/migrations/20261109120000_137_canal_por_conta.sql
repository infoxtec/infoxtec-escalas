-- Multiempresa F5a: canal de WhatsApp por conta (decisão 108: cada cliente com a sua instância, nunca o número da
-- Infoxtec). A operadora (conta 1) continua no canal da instalação (config evolution_url, evolution_instancia e o
-- segredo EVOLUTION_API_KEY), sem mudança. As outras contas ganham a linha em conta_canais, cadastrada pela plataforma;
-- o envio descobre a conta pelo funcionário que recebe e sai pela instância dela. Conta sem canal não envia.
-- Webhook por instância (entrada pela conta) e fila justa ficam para a F5b e a F5c.

set lock_timeout = '5s';

create table interno.conta_canais (
  conta_id uuid primary key default interno.fn_conta_padrao() references interno.contas (id),
  provedor text not null default 'evolution' check (provedor = 'evolution'),
  url text not null check (url ~ '^https://[a-z0-9.-]+(:[0-9]+)?$'),
  instancia text not null unique check (instancia ~ '^[a-z0-9][a-z0-9-]{2,59}$'),
  segredo text not null unique check (segredo ~ '^EVOLUTION_API_KEY_[0-9a-f]{32}$'),   -- nome do segredo no Vault
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  -- a operadora usa o canal da instalação (config); a tabela é só das outras contas
  check (conta_id <> '00000000-0000-0000-0000-000000000001')
);
alter table interno.conta_canais enable row level security;

alter table interno.plataforma_log drop constraint plataforma_log_acao_check;
alter table interno.plataforma_log add constraint plataforma_log_acao_check
  check (acao in ('criar_conta', 'alterar_conta', 'monitor_externo', 'canal_whatsapp'));


-- conta de quem recebe: o funcionário com esse telefone (único no sistema até a F5b); sem funcionário, a operadora;
-- forma canônica que bate em contas diferentes (12 x 13 dígitos): null, e o envio é recusado
create index if not exists tecnicos_tel_canonico_idx on interno.tecnicos (interno.fn_tel_canonico(telefone_e164));

create or replace function interno.fn_conta_do_numero(p_numero text)
 returns uuid
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_num text := regexp_replace(coalesce(p_numero, ''), '\D', '', 'g');
  v_contas uuid[];
begin
  select array_agg(t.conta_id) into v_contas from interno.tecnicos t where t.telefone_e164 = v_num;
  if v_contas is null then
    select array_agg(distinct t.conta_id) into v_contas from interno.tecnicos t
     where interno.fn_tel_canonico(t.telefone_e164) = interno.fn_tel_canonico(v_num);
  end if;
  if v_contas is null then return '00000000-0000-0000-0000-000000000001'; end if;
  if cardinality(v_contas) > 1 then return null; end if;
  return v_contas[1];
end $function$;


-- para onde vai o envio: a operadora pelo canal da instalação; outra conta pelo canal dela (o caminho dos chamadores
-- termina na instância da instalação e é trocado pela da conta). Null: a conta não tem canal ativo.
create or replace function interno.fn_evo_destino(p_path text, p_numero text)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_inst  text := fn_config('evolution_instancia');
  v_conta uuid := fn_conta_do_numero(p_numero);
  c       conta_canais;
begin
  if v_conta is null then return null; end if;   -- número em mais de uma conta: não adivinha
  if v_conta = '00000000-0000-0000-0000-000000000001' then
    return jsonb_build_object('conta', v_conta, 'url', fn_config('evolution_url'), 'path', p_path, 'instancia', v_inst,
                              'segredo', 'EVOLUTION_API_KEY');
  end if;
  select * into c from conta_canais where conta_id = v_conta and ativo;
  if not found then return null; end if;
  return jsonb_build_object('conta', v_conta, 'url', c.url, 'instancia', c.instancia, 'segredo', c.segredo,
                            'path', left(p_path, length(p_path) - length(coalesce(v_inst, ''))) || c.instancia);
end $function$;


CREATE OR REPLACE FUNCTION interno.fn_segredo_gravar(p_nome text, p_valor text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  if p_nome not in ('WEBHOOK_TOKEN', 'WEBHOOK_TOKEN_ANTERIOR', 'ESPELHO_PDF_TOKEN', 'ALERTA_EMAIL_TOKEN')
     and p_nome !~ '^EVOLUTION_API_KEY_[0-9a-f]{32}$' then
    raise exception 'segredo não permitido';
  end if;
  select id into v_id from vault.secrets where name = p_nome;
  if v_id is null then
    perform vault.create_secret(p_valor, p_nome);
  else
    perform vault.update_secret(v_id, p_valor);
  end if;
end $function$
;


-- envio pela Evolution: a operadora como antes; outra conta pela instância dela (o caminho dos chamadores, que termina
-- na instância da instalação, é trocado pela da conta). O resto igual à definição da homologação.
CREATE OR REPLACE FUNCTION interno.fn_evo_post(p_path text, p_body jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_key  text;
  v_num  text := p_body ->> 'number';
  v_inst text := fn_config('evolution_instancia');
  v_url  text := fn_config('evolution_url');
  v_homo boolean := coalesce(fn_config('ambiente'), 'producao') = 'homologacao';
  v_body jsonb := p_body;
  v_path text := p_path;
  v_segredo text := 'EVOLUTION_API_KEY';
  v_dest jsonb;
begin
  -- instância: o caminho termina nela; homologação só pela dela, produção nunca pela da homologação
  if v_inst is null or v_inst = '' or right(p_path, length(v_inst) + 1) <> '/' || v_inst then
    raise exception 'Envio recusado: o caminho não é da instância configurada (%).', coalesce(v_inst, 'nenhuma');
  end if;

  -- outra conta: o canal dela (F5a, decisão 108); sem canal ativo, não sai pelo número da operadora
  v_dest := fn_evo_destino(p_path, v_num);
  if v_dest is null then
    raise warning 'Envio recusado: o número final % não tem canal de WhatsApp ativo na conta dele.', right(coalesce(v_num, '-'), 4);
    return null;
  end if;
  -- homologação: só a instância da operadora existe lá; envio de conta cliente vira aviso, sem derrubar o lote
  if v_homo and (v_dest->>'conta')::uuid <> '00000000-0000-0000-0000-000000000001' then
    raise warning 'HOMOLOGACAO: envio de conta cliente não sai (só a instância trilha-homologacao existe)';
    return null;
  end if;
  v_path := v_dest->>'path';
  v_inst := v_dest->>'instancia';
  v_url := v_dest->>'url';
  v_segredo := v_dest->>'segredo';

  if v_homo and v_inst <> 'trilha-homologacao' then
    raise exception 'Envio recusado: a homologação só usa a instância trilha-homologacao.';
  end if;
  if not v_homo and v_inst = 'trilha-homologacao' then
    raise exception 'Envio recusado: a instância trilha-homologacao não serve à produção.';
  end if;
  if v_homo and p_path like '/message/%' and v_num is null then
    raise exception 'Envio recusado: mensagem sem destinatário na homologação.';
  end if;

  v_key := fn_segredo(v_segredo);
  if v_key is null then
    raise exception '% nao encontrada no Vault', v_segredo;
  end if;

  if v_num is not null and not fn_pode_enviar(v_num) then
    raise warning 'HOMOLOGACAO: envio bloqueado para % (numero fora de telefones_homologacao)', v_num;
    return null;
  end if;

  -- texto com prévia de link não é entregue (decisão 95): desliga, salvo pedido explícito
  if p_path like '/message/sendText/%' and not (v_body ? 'linkPreview') then
    v_body := v_body || jsonb_build_object('linkPreview', false);
  end if;

  return net.http_post(
    url     := v_url || v_path,
    headers := jsonb_build_object('apikey', v_key, 'Content-Type', 'application/json'),
    body    := v_body
  );
end $function$
;


-- canais das contas (tela Contas): a operadora pela configuração da instalação; a chave nunca volta
create or replace function public.app_plataforma_canais()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform interno.fn_exigir_plataforma();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'conta_id', c.id,
      'instancia', case when c.id = '00000000-0000-0000-0000-000000000001' then interno.fn_config('evolution_instancia') else k.instancia end,
      'ativo', case when c.id = '00000000-0000-0000-0000-000000000001' then interno.fn_config('evolution_instancia') is not null else k.ativo end,
      'da_instalacao', c.id = '00000000-0000-0000-0000-000000000001',
      'com_chave', case when c.id = '00000000-0000-0000-0000-000000000001' then interno.fn_segredo('EVOLUTION_API_KEY') is not null
                        else interno.fn_segredo(k.segredo) is not null end)
    order by c.criada_em)
    from interno.contas c left join interno.conta_canais k on k.conta_id = c.id), '[]'::jsonb);
end $function$;

-- cadastra ou troca o canal de uma conta cliente; chave vazia mantém a que está no Vault
create or replace function public.app_plataforma_salvar_canal(p_conta uuid, p_instancia text, p_chave text, p_ativo boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator text := interno.fn_exigir_plataforma();
  v_inst text := lower(btrim(coalesce(p_instancia, '')));
  v_chave text := btrim(coalesce(p_chave, ''));
  v_homo boolean := coalesce(interno.fn_config('ambiente'), 'producao') = 'homologacao';
  v_segredo text := 'EVOLUTION_API_KEY_' || replace(p_conta::text, '-', '');
  v_url text := rtrim(coalesce(interno.fn_config('evolution_url'), ''), '/');
  v_antes interno.conta_canais;
begin
  if p_conta = '00000000-0000-0000-0000-000000000001' then
    raise exception 'A operadora usa o canal da instalação.';
  end if;
  if not exists (select 1 from interno.contas where id = p_conta) then raise exception 'Conta não encontrada.'; end if;
  if v_inst !~ '^[a-z0-9][a-z0-9-]{2,59}$' then
    raise exception 'Instância inválida: letras minúsculas, números e hífen (3 a 60).';
  end if;
  if v_inst = coalesce(interno.fn_config('evolution_instancia'), '') then
    raise exception 'Esta é a instância da operadora: cada cliente tem a sua (decisão 108).';
  end if;
  if not v_homo and v_inst = 'trilha-homologacao' then
    raise exception 'A instância trilha-homologacao não serve à produção.';
  end if;
  if v_url !~ '^https://[a-z0-9.-]+(:[0-9]+)?$' then raise exception 'Endereço da Evolution não configurado.'; end if;
  if length(v_chave) > 200 or (v_chave <> '' and v_chave !~ '^[A-Za-z0-9_-]{8,200}$') then
    raise exception 'Chave da instância inválida.';
  end if;
  select * into v_antes from interno.conta_canais where conta_id = p_conta for update;
  if v_chave = '' and (v_antes is null or interno.fn_segredo(v_segredo) is null) then
    raise exception 'Informe a chave (token) da instância.';
  end if;
  begin
    insert into interno.conta_canais (conta_id, url, instancia, segredo, ativo)
    values (p_conta, v_url, v_inst, v_segredo, coalesce(p_ativo, true))
    on conflict (conta_id) do update set instancia = excluded.instancia, url = excluded.url,
      ativo = excluded.ativo, atualizado_em = now();
  exception when unique_violation then
    raise exception 'Esta instância já é de outra conta.';
  end;
  if v_chave <> '' then perform interno.fn_segredo_gravar(v_segredo, v_chave); end if;
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'canal_whatsapp', p_conta, jsonb_build_object('instancia', v_inst, 'ativo', coalesce(p_ativo, true),
          'chave_trocada', v_chave <> '', 'instancia_antes', v_antes.instancia));
end $function$;



-- motor: escala de conta sem canal termina em falha (revisão do arquiteto-dados); o resto igual à definição da homologação
CREATE OR REPLACE FUNCTION interno.fn_dispatcher_whatsapp()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  n record; r_resp record; a record; s record;
  v_wa_id text; v_req bigint; v_tent int; v_texto text; v_payload jsonb; v_botoes boolean;
  v_sent int := 0;
  v_avisos int := 0;
  v_emp uuid;
  v_conta uuid;
  v_limite int := coalesce(fn_config_int('envios_por_execucao'), 3);
  v_limite_sup int := greatest(coalesce(fn_config_int('supervisor_avisos_por_execucao'), 5), 1);
  v_webhook boolean := coalesce(fn_config('webhook_ativo'), 'false')::boolean;
  v_usar_botoes boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_inst text := fn_config('evolution_instancia');
  v_ping text := nullif(fn_config('monitor_ping_url'), '');
begin
  -- uma execucao por vez: uma chamada manual junto com o cron nao envia a mesma escala duas vezes
  if not pg_try_advisory_xact_lock(hashtext('fn_dispatcher_whatsapp')) then
    return;
  end if;
  -- nunca preso mais que 20 s esperando lock: a proxima execucao tenta de novo
  perform set_config('lock_timeout', '20s', true);
  perform set_config('app.ator', 'dispatcher', true);

  -- FASE 1: conferir o que a Evolution respondeu
  for n in select id, escala_id, http_req_id, created_at from notificacoes
           where status_envio = 'enfileirada' and http_req_id is not null loop
   begin
    select status_code, content, error_msg into r_resp from net._http_response where id = n.http_req_id;
    if not found then
      if n.created_at < now() - interval '5 minutes' then
        update notificacoes set status_envio = 'falha', erro_codigo = 'timeout',
               erro_mensagem = 'Sem resposta da Evolution em 5 minutos' where id = n.id;
      end if;
      continue;
    end if;
    if r_resp.status_code in (200, 201) then
      begin v_wa_id := (r_resp.content::jsonb) -> 'key' ->> 'id'; exception when others then v_wa_id := null; end;
      update notificacoes set status_envio = 'enviada', wa_message_id = v_wa_id where id = n.id;
      update escalas set status = 'notificada' where id = n.escala_id and status = 'agendada';
    else
      update notificacoes set status_envio = 'falha',
             erro_codigo = coalesce(r_resp.status_code::text, 'rede'),
             erro_mensagem = left(coalesce(r_resp.content, r_resp.error_msg, 'erro desconhecido'), 500)
       where id = n.id;
    end if;
   exception when others then
    raise warning 'fase 1, notificacao %: %', n.id, sqlerrm;
   end;
  end loop;

  -- FASE 2: enviar
  for a in select * from vw_acoes_pendentes
           where acao in ('enviar_primeira','reenviar_falha','reenviar','nao_recebeu')
           order by enviada_em nulls first loop
    exit when v_sent >= v_limite;
    if not v_webhook and a.acao in ('reenviar','nao_recebeu') then continue; end if;
    v_tent := coalesce(a.tentativa, 0) + 1;
    v_botoes := v_usar_botoes and a.acao <> 'reenviar_falha';
    begin
      v_payload := fn_payload_escala(a.escala_id, a.telefone, a.acao = 'reenviar', v_botoes);
      -- conta sem canal de WhatsApp (F5a): falha registrada, em vez de ficar enfileirada sem pedido
      if fn_evo_destino(v_payload ->> 'path', v_payload -> 'body' ->> 'number') is null then
        raise exception 'A conta do técnico não tem canal de WhatsApp ativo.';
      end if;
      v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
      insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
      values (a.escala_id,
        (case when v_tent = 1 then 'primeira' when a.acao = 'reenviar_falha' then 'reenvio_falha' else 'lembrete' end)::notificacao_tipo,
        v_tent, case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
        'enfileirada', v_payload, now(), v_req);
    exception when others then
      -- registra a falha na propria escala: o motor tenta de novo e, esgotadas as tentativas,
      -- aciona o supervisor. As outras escalas seguem normalmente.
      begin
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, erro_codigo, erro_mensagem, enviada_em)
        values (a.escala_id,
          (case when v_tent = 1 then 'primeira' when a.acao = 'reenviar_falha' then 'reenvio_falha' else 'lembrete' end)::notificacao_tipo,
          v_tent, 'erro_interno', 'falha', 'interno', left(sqlerrm, 500), now());
      exception when others then
        raise warning 'fase 2, escala %: %', a.escala_id, sqlerrm;
      end;
    end;
    v_sent := v_sent + 1;
  end loop;

  -- FASE 3: supervisores, no maximo v_limite_sup escalas por execucao (as mais antigas primeiro);
  -- o resto fica para a proxima execucao, porque so a escala avisada ganha supervisor_avisado_em
  for a in select * from vw_acoes_pendentes
           where acao = 'escalonar' or (v_webhook and avisar_supervisor)
           order by enviada_em nulls first loop
    exit when v_avisos >= v_limite_sup;
    if exists (select 1 from escalas where id = a.escala_id and supervisor_avisado_em is not null) then continue; end if;
   begin
    v_texto := fn_msg_supervisor(a.escala_id, a.diagnostico, a.tentativa);
    -- só os supervisores da empresa do técnico (decisão 107); funcionário sem empresa avisa os da conta dele (122)
    select t.empresa_id, e.conta_id into v_emp, v_conta from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = a.escala_id;
    for s in select telefone_e164 from tecnicos
              where is_supervisor and ativo and (v_emp is null or empresa_id = v_emp) and conta_id = v_conta loop
      perform fn_evo_post('/message/sendText/' || v_inst,
                          jsonb_build_object('number', s.telefone_e164, 'text', v_texto));
    end loop;
    update escalas set supervisor_avisado_em = now() where id = a.escala_id;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (a.escala_id, 'supervisor_acionado', 'dispatcher',
            jsonb_build_object('diagnostico', a.diagnostico, 'tentativa', a.tentativa));
    -- conta só o aviso que deu certo: escala que falha sempre não ocupa o teto das outras
    v_avisos := v_avisos + 1;
   exception when others then
    raise warning 'fase 3, escala %: %', a.escala_id, sqlerrm;
   end;
  end loop;

  -- FASE 4: prazo da escala de amanha
  begin perform fn_alerta_prazo_escala();
  exception when others then raise warning 'alerta de prazo falhou: %', sqlerrm; end;

  -- FASE 5: documentos vencidos
  begin perform fn_alerta_certificacoes();
  exception when others then raise warning 'alerta de certificacoes falhou: %', sqlerrm; end;

  -- FASE 6: ligacoes da URA
  begin perform fn_disparar_ligacoes();
  exception when others then raise warning 'ligacoes falharam: %', sqlerrm; end;

  -- FASE 7: escalas encerradas viram concluidas (decisao 30)
  begin perform fn_concluir_escalas();
  exception when others then raise warning 'conclusao automatica falhou: %', sqlerrm; end;
  perform set_config('app.ator', 'dispatcher', true);

  -- Execucao concluida: registro lido pelo vigia (fn_vigiar_motor). Se algo acima falhar sem
  -- tratamento, a transacao inteira e desfeita e este registro tambem.
  update motor_estado set ultima_execucao_ok = now(), atualizado_em = now() where id;

  -- Monitor externo: sinal a cada execucao. Sem sinal (motor parado, Supabase fora ou pausado),
  -- o healthchecks.io avisa por e-mail/Telegram. Evolution falhando: sinal de falha (/fail).
  if v_ping is not null then
    begin
      perform net.http_get(v_ping || case when fn_evolution_falhando() then '/fail' else '' end,
                           timeout_milliseconds => 5000);
    exception when others then raise warning 'ping do monitor falhou: %', sqlerrm; end;
  end if;
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
