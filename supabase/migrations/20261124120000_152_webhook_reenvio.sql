-- 152: webhook da Evolution com reenvio seguro (B4, achado #21 do seguranca, decisão 136).
--
-- Antes: qualquer falha (banco travado, conexão, deadlock) virava 200 na Edge e a mensagem do técnico se perdia.
-- Agora: falha de infraestrutura (fn_erro_infra) devolve {reprocessar: true} e a Edge responde 503, para a
-- Evolution reenviar. O reenvio não processa duas vezes: cada mensagem (conta + data.key.id) entra uma vez só no
-- log (índice único parcial em webhook_eventos.wa_msg_id); a tentativa que falhou por infraestrutura solta a chave.
-- Na 3ª falha da mesma mensagem, ou num reenvio que chega mais de 10 min depois, o banco desiste e avisa o técnico.
-- Erro de regra (P0001, dado) segue como hoje: 200, sem reenvio (reenviar não muda o resultado).
--
-- O Supabase CLI não abre transação para a migration: lock_timeout de sessão, para não enfileirar o webhook.
set lock_timeout = '5s';

-- 1. Classificação única de erro de infraestrutura (usada no banco; a Edge repete a lista para o que vem de fora)
--    08 conexão, 40001/40P01 serialização e deadlock, 53 recursos, 55P03/55006 lock e objeto em uso,
--    57P01-57P05 desligamento e conexão perdida, 58 sistema, 72000 snapshot, 25006 réplica só leitura (failover).
--    Fora de propósito: XX (corrupção, reenviar não conserta), 54 (limite de programa), 57014 (statement_timeout de
--    função lenta estouraria sempre; nem é capturável por "when others").
create or replace function interno.fn_erro_infra(p_sqlstate text)
returns boolean
language sql
immutable
set search_path = interno, public, extensions, pg_temp
as $$
  select coalesce(left(p_sqlstate, 2) in ('08', '53')
      or p_sqlstate in ('40001', '40P01', '55P03', '55006', '57P01', '57P02', '57P03', '57P04', '57P05',
                        '58000', '58030', '72000', '25006'), false)
$$;

-- 2. Controle de reenvio no próprio log
--    wa_msg_id: a chave única (conta + id da mensagem); fica nula na tentativa que falhou por infraestrutura.
--    wa_msg_ref: o mesmo id, sempre gravado, para contar as tentativas.
--    O log é pequeno (retenção retencao_webhook_dias): índice comum, sem concurrently.
alter table interno.webhook_eventos add column if not exists wa_msg_id text;
alter table interno.webhook_eventos add column if not exists wa_msg_ref text;
create unique index if not exists webhook_eventos_msg_uk on interno.webhook_eventos (conta_id, wa_msg_id)
  where wa_msg_id is not null;
create index if not exists webhook_eventos_msg_ref_idx on interno.webhook_eventos (conta_id, wa_msg_ref)
  where wa_msg_ref is not null;

-- 3. Recepção do webhook
create or replace function interno.fn_webhook_evolution(p_token text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = interno, public, extensions, pg_temp
as $function$
declare
  v_log    bigint;
  v_conta  uuid;
  v_evento text := lower(replace(coalesce(p_payload->>'event', ''), '_', '.'));
  v_res    jsonb;
  v_pl     jsonb := p_payload - 'apikey';
  v_msg    jsonb;
  v_id     text;
  v_falhas int;
  v_ts     timestamptz;
  v_tel    text;
  v_estado text;
  v_permitidas text[] := array['conversation', 'extendedTextMessage', 'buttonsResponseMessage', 'templateButtonReplyMessage',
                               'interactiveResponseMessage', 'listResponseMessage', 'messageContextInfo', 'localizacao',
                               'reactionMessage', 'protocolMessage'];
begin
  -- F5b: a instância diz a conta, e o token tem de ser o daquela instância; o resto da transação trabalha nela
  v_conta := fn_webhook_conta(p_token, p_payload->>'instance');
  perform set_config('trilha.conta', v_conta::text, true);

  -- mensagem com conteúdo e id (migration 152): é ela que o reenvio poderia processar duas vezes. Evento de
  -- sistema (messageStubType) ou sem message não tem controle: segue como antes.
  if v_evento = 'messages.upsert' and jsonb_typeof(p_payload->'data'->'message') = 'object'
     and p_payload->'data'->'messageStubType' is null then
    v_id := nullif(left(p_payload->'data'->'key'->>'id', 128), '');
  end if;
  begin
    v_ts := to_timestamp((p_payload->'data'->>'messageTimestamp')::bigint);
  exception when others then v_ts := null;   -- carimbo ausente ou fora do formato: sem controle de atraso
  end;
  v_tel := case when p_payload->'data'->'key'->>'remoteJid' ~ '^\d{10,15}@s\.whatsapp\.net$'
                 and coalesce((p_payload->'data'->'key'->>'fromMe')::boolean, false) is false
                then split_part(p_payload->'data'->'key'->>'remoteJid', '@', 1) end;

  -- LGPD: a localização do ponto já fica na marcação; o log do webhook não guarda outra cópia
  if v_pl->'data'->'message' ?| array['locationMessage', 'liveLocationMessage'] then
    v_pl := jsonb_set(v_pl, '{data,message}',
      ((v_pl->'data'->'message') - 'locationMessage' - 'liveLocationMessage') || '{"localizacao": true}');
  end if;
  -- LGPD (decisão 56): o log guarda só texto, botão e a marca da localização (tirada acima). Foto, vídeo,
  -- áudio, arquivo, mensagem temporária ou de visualização única e a mensagem citada saem (miniatura,
  -- legenda, URL e chave da mídia); fica só a marca "midia"
  if jsonb_typeof(v_pl->'data'->'message') = 'object' then
    select coalesce(jsonb_object_agg(e.k, case when e.k = 'extendedTextMessage' then e.v #- '{contextInfo,quotedMessage}' else e.v end), '{}')
      into v_msg
      from jsonb_each(v_pl->'data'->'message') e(k, v)
     where e.k = any(v_permitidas);
    if exists (select 1 from jsonb_object_keys(v_pl->'data'->'message') k where k <> all(v_permitidas)) then
      v_msg := v_msg || '{"midia": true}';
    end if;
    v_pl := jsonb_set(v_pl, '{data,message}', v_msg);
  end if;
  v_pl := v_pl #- '{data,contextInfo,quotedMessage}';

  -- a mesma mensagem entra uma vez: a entrega simultânea espera a primeira terminar e cai no conflito
  insert into webhook_eventos (conta_id, evento, payload, wa_msg_id, wa_msg_ref)
  values (v_conta, v_evento, v_pl, v_id, v_id)
  on conflict (conta_id, wa_msg_id) where wa_msg_id is not null do nothing
  returning id into v_log;
  if v_log is null then
    -- já processada: o log desta entrega guarda só o id (sem outra cópia do conteúdo)
    insert into webhook_eventos (conta_id, evento, payload, resultado, wa_msg_ref)
    values (v_conta, v_evento, jsonb_build_object('instance', p_payload->>'instance', 'data',
              jsonb_build_object('key', jsonb_build_object('id', v_id))), 'reenvio ignorado', v_id);
    return jsonb_build_object('ignorado', 'reenvio');
  end if;

  if v_id is not null then
    select count(*) into v_falhas from webhook_eventos
     where conta_id = v_conta and wa_msg_ref = v_id and id <> v_log and resultado like 'ERRO (reprocessar)%';
    -- reenvio que chega tarde: a conversa já andou; processar agora confundiria o técnico
    if v_falhas > 0 and v_ts < now() - interval '10 minutes' then
      update webhook_eventos set resultado = 'reenvio atrasado' where id = v_log;
      perform fn_webhook_avisar_perda(v_conta, v_tel, v_ts);
      return jsonb_build_object('ignorado', 'reenvio atrasado');
    end if;
  end if;

  begin
    if v_evento = 'messages.update' then
      v_res := fn_wh_status(p_payload->'data');
    elsif v_evento = 'messages.upsert' then
      -- resposta do gestor aos botões de aprovação de hora extra (decisão 100, parte 2)
      v_res := fn_ponto_he_resposta(p_payload->'data');
      if v_res is null then
      begin
        v_res := fn_ponto_wh(p_payload->'data');
      exception when others then
        -- infraestrutura sobe para o reenvio; erro do ponto não pode derrubar a resposta das escalas
        if fn_erro_infra(sqlstate) then raise; end if;
        v_res := null;
        raise warning 'ponto: %', sqlerrm;
      end;
      if v_res is null then
        v_res := fn_wh_mensagem(p_payload->'data');
      end if;
      end if;
    else
      v_res := jsonb_build_object('ignorado', v_evento);
    end if;
    update webhook_eventos set resultado = v_res::text where id = v_log;
  exception when others then
    v_estado := sqlstate;
    if fn_erro_infra(v_estado) and v_id is not null and v_falhas >= 2 then
      -- 3ª falha da mesma mensagem: desiste (a chave fica, reenvios seguintes são ignorados) e avisa o técnico
      update webhook_eventos set resultado = 'ERRO (desistiu) ' || v_estado || ': ' || left(sqlerrm, 200) where id = v_log;
      perform fn_webhook_avisar_perda(v_conta, v_tel, v_ts);
      v_res := jsonb_build_object('erro', 'desistiu');
    elsif fn_erro_infra(v_estado) then
      -- tudo do bloco foi desfeito; a chave sai para o reenvio processar do zero
      update webhook_eventos set resultado = 'ERRO (reprocessar) ' || v_estado || ': ' || left(sqlerrm, 200),
                                 wa_msg_id = null
       where id = v_log;
      v_res := jsonb_build_object('erro', 'infraestrutura', 'reprocessar', true);
    else
      -- erro de regra ou de dado: reenviar dá o mesmo erro; conta como processada
      update webhook_eventos set resultado = 'ERRO: ' || sqlerrm where id = v_log;
      v_res := jsonb_build_object('erro', sqlerrm);
    end if;
  end;

  return v_res;
end $function$;

-- Aviso ao técnico de que a mensagem dele não foi processada (desistência ou reenvio atrasado). Só para número de
-- telefone de verdade (@s.whatsapp.net); falha no aviso não derruba o registro.
create or replace function interno.fn_webhook_avisar_perda(p_conta uuid, p_telefone text, p_quando timestamptz)
returns void
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $function$
begin
  if p_telefone is null then return; end if;
  perform fn_wa_texto_na_conta(p_conta, p_telefone,
    'Não consegui processar sua mensagem'
    || coalesce(' das ' || to_char(p_quando at time zone coalesce(fn_config('fuso'), 'America/Bahia'), 'HH24:MI'), '')
    || '. Por favor, envie de novo.');
exception when others then
  raise warning 'webhook: aviso de perda não enviado (%)', sqlstate;
end $function$;

-- 4. Ponto e hora extra: infraestrutura sobe para o reenvio; ao gestor, só a mensagem de regra (definições da homologação)
create or replace function interno.fn_ponto_wh(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_key    jsonb := p_data->'key';
  v_msg    jsonb := p_data->'message';
  v_wa_id  text  := p_data->'key'->>'id';
  v_jid    text;
  v_tec    record;
  v_conv   record;
  v_norm   text;
  v_ultima text;
  v_tipo   text;
  v_loc    jsonb;
  v_lat    numeric;
  v_lng    numeric;
  v_prec   int;
  c        jsonb;
  v_btn    text;
  v_citou  boolean;
  v_aviso  text;
begin
  if coalesce((v_key->>'fromMe')::boolean, false) or v_wa_id is null then return null; end if;
  -- grupo, status e canal não são do ponto
  if coalesce(v_key->>'remoteJid', '') ~ '@(g\.us|broadcast|newsletter)$' then return null; end if;
  select j into v_jid from unnest(array[v_key->>'remoteJid', v_key->>'remoteJidAlt',
                                        v_key->>'senderPn', p_data->>'sender']) as j
   where j like '%@s.whatsapp.net' limit 1;
  if v_jid is null then return null; end if;

  select t.id, t.nome, t.telefone_e164, t.cpf, t.empresa_id, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id
   where fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1)) and t.ativo
     and t.conta_id = coalesce(fn_conta_contexto(), t.conta_id);   -- F5b: só a conta da instância que recebeu
  -- telefone canônico ambíguo (com e sem o 9): não arrisca marcar no funcionário errado
  if (select count(*) from tecnicos t where t.ativo
        and fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1))
        and t.conta_id = coalesce(fn_conta_contexto(), t.conta_id)) > 1 then
    return null;
  end if;
  -- só quem está cadastrado para o ponto (CPF e empresa) conversa com o ponto
  if v_tec.id is null or v_tec.cpf is null or v_tec.empresa_id is null then return null; end if;

  -- trava a conversa: duas localizações simultâneas não geram duas marcações
  select * into v_conv from ponto_conversas where tecnico_id = v_tec.id and expira_em > now() for update;
  v_norm := lower(trim(translate(coalesce(v_msg->>'conversation', v_msg->'extendedTextMessage'->>'text', ''),
                                 'áàâãéêíóôõúçÁÀÂÃÉÊÍÓÔÕÚÇ', 'aaaaeeiooouc' || 'aaaaeeiooouc')));
  v_norm := regexp_replace(v_norm, '[.!?]+$', '');
  v_loc := coalesce(v_msg->'liveLocationMessage', v_msg->'locationMessage');
  -- resposta de botão (mesmos formatos de fn_wh_mensagem) e mensagem que cita outra
  v_btn := coalesce(v_msg->'buttonsResponseMessage'->>'selectedButtonId',
                    v_msg->'templateButtonReplyMessage'->>'selectedId');
  if v_btn is null and v_msg ? 'interactiveResponseMessage' then
    begin
      v_btn := ((v_msg->'interactiveResponseMessage'->'nativeFlowResponseMessage'->>'paramsJson')::jsonb)->>'id';
    exception when others then v_btn := null; end;
  end if;
  v_citou := v_msg->'extendedTextMessage'->'contextInfo'->>'stanzaId' is not null;

  -- Foto, vídeo ou arquivo pelo WhatsApp: só dentro do pedido de ajuste, na etapa do documento (E2b). O
  -- arquivo não passa pelo log: a Edge Function baixa da Evolution e entrega direto ao cofre
  if v_msg ?| array['imageMessage', 'documentMessage', 'documentWithCaptionMessage', 'videoMessage', 'stickerMessage']
     or exists (select 1 from unnest(array['ephemeralMessage', 'viewOnceMessage', 'viewOnceMessageV2', 'viewOnceMessageV2Extension']) w
                 where v_msg->w->'message' ?| array['imageMessage', 'documentMessage', 'documentWithCaptionMessage', 'videoMessage']) then
    if v_conv.tecnico_id is not null and v_conv.etapa = 'aj_documento' then
      return fn_ponto_documento_recebido(v_tec.id, v_tec.telefone_e164, v_wa_id, v_msg, v_conv.dados);
    end if;
    perform fn_ponto_wa(v_tec.telefone_e164, 'Para enviar atestado ou outro documento, escreva *ajuste*, escolha o motivo e, '
      || 'quando o pedido pedir, mande a foto ou o PDF. Também dá pelo *app do ponto*, aba *Ajuste*.');
    return jsonb_build_object('acao', 'ponto_midia_recusada');
  end if;

  -- 0. Pedido de ajuste (decisão 55): a palavra "ajuste" abre a conversa; dentro dela, as respostas
  -- são do pedido (resposta citando outra mensagem segue para as escalas)
  -- escala enviada ou ocorrência aberta depois do início do pedido: a resposta é da escala, e a conversa
  -- de ajuste termina (o funcionário recomeça com "ajuste")
  if v_conv.tecnico_id is not null and v_conv.etapa like 'aj\_%'
     and (exists (select 1 from ocorrencias o join escalas e on e.id = o.escala_id
                   where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.detalhe is null
                     and o.created_at > now() - interval '2 hours')
          or exists (select 1 from notificacoes n join escalas e on e.id = n.escala_id
                      where e.tecnico_id = v_tec.id
                        and n.created_at > coalesce((v_conv.dados->>'inicio')::timestamptz, now() - interval '15 minutes'))) then
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    v_conv.tecnico_id := null;
  end if;
  if v_loc is null and v_btn is null and not v_citou
     and (v_norm in ('ajuste', 'justificar', 'justificativa')
          or (v_conv.tecnico_id is not null and v_conv.etapa like 'aj\_%' and v_norm <> '')) then
    return fn_ponto_wh_ajuste(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_tec.fuso,
                              case when v_conv.etapa like 'aj\_%' then v_conv.etapa end, v_conv.dados, v_norm);
  end if;

  select m.tipo into v_ultima from ponto_marcacoes m
   where m.tecnico_id = v_tec.id and (m.momento at time zone v_tec.fuso)::date = (now() at time zone v_tec.fuso)::date
   order by m.nsr desc limit 1;

  -- 1. Localização
  if v_loc is not null then
    if exists (select 1 from ponto_marcacoes where origem ->> 'msg_id' = v_wa_id) then
      return jsonb_build_object('ignorado', 'ponto: evento duplicado');
    end if;
    if v_conv.tecnico_id is null or v_conv.etapa <> 'aguardando_local' then
      -- atualização da localização em tempo real fora da conversa: ignora em silêncio
      if v_msg ? 'liveLocationMessage' then return jsonb_build_object('ignorado', 'ponto: localização sem conversa'); end if;
      perform fn_ponto_wa(v_tec.telefone_e164, 'Para bater o ponto, escreva *ponto* primeiro e depois mande a localização.');
      return jsonb_build_object('acao', 'ponto_localizacao_sem_conversa');
    end if;
    -- lugar escolhido no mapa traz nome ou endereço; a localização atual não
    if v_msg ? 'locationMessage' and (coalesce(v_loc->>'name', '') <> '' or coalesce(v_loc->>'address', '') <> '') then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Essa localização é um lugar escolhido no mapa. Mande a sua *localização atual*: 📎 → Localização → *Enviar localização atual*.');
      return jsonb_build_object('acao', 'ponto_localizacao_recusada');
    end if;
    -- localização encaminhada (de outra pessoa ou uma antiga do próprio funcionário). A Evolution 2.x
    -- traz o contexto em data.contextInfo; o protocolo o põe dentro da localização (messageContextInfo
    -- fica por garantia)
    if exists (select 1 from (values (v_loc->'contextInfo'), (p_data->'contextInfo'), (v_msg->'messageContextInfo')) x(ci)
                where coalesce(ci->>'isForwarded', '') = 'true'
                   or coalesce(nullif(ci->>'forwardingScore', ''), '0') <> '0') then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Localização encaminhada não vale para o ponto. Mande a *sua localização atual*: 📎 → Localização → *Enviar localização atual*.');
      return jsonb_build_object('acao', 'ponto_localizacao_encaminhada');
    end if;
    v_lat := (v_loc->>'degreesLatitude')::numeric;
    v_lng := (v_loc->>'degreesLongitude')::numeric;
    v_prec := nullif(v_loc->>'accuracyInMeters', '')::numeric::int;
    if v_lat is null or v_lng is null then return null; end if;
    -- localização FIXA com a coordenada exata (6 casas, ~10 cm) de uma marcação anterior: pode ser
    -- reenviada. Pede a localização em tempo real, que não pode ser encaminhada e é sempre leitura nova
    -- (GPS com cache dentro de prédio também repete coordenada: o funcionário honesto tem saída)
    if v_msg ? 'locationMessage' and exists (select 1 from ponto_marcacoes m
                where m.tecnico_id = v_tec.id and m.momento > now() - interval '60 days'
                  and m.latitude = round(v_lat, 6) and m.longitude = round(v_lng, 6)) then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Essa localização é igual à de uma marcação anterior. Mande a sua *localização em tempo real*: 📎 → Localização → *Compartilhar localização em tempo real* (pode ser por 15 minutos).');
      return jsonb_build_object('acao', 'ponto_localizacao_repetida');
    end if;
    begin
      c := fn_ponto_registrar(v_tec.id, v_conv.tipo, 'whatsapp', v_lat, v_lng, v_prec,
                              jsonb_build_object('msg_id', v_wa_id));
    exception when unique_violation then
      return jsonb_build_object('ignorado', 'ponto: evento duplicado');   -- entrega simultânea
    when others then
      -- falha de infraestrutura sobe: a mensagem volta para a Evolution reenviar (migration 152, decisão 136)
      if fn_erro_infra(sqlstate) then raise; end if;
      -- só a mensagem de regra (raise exception) vai ao funcionário; o detalhe técnico fica no log
      perform fn_ponto_wa(v_tec.telefone_e164, case when sqlstate = 'P0001'
        then 'Não foi possível registrar o ponto: ' || sqlerrm
        else 'Não foi possível registrar o ponto agora. Tente de novo ou fale com o gestor.' end);
      return jsonb_build_object('acao', 'ponto_erro', 'erro', sqlerrm);
    end;
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    -- comprovante no WhatsApp: CPF mascarado (o canal passa por terceiros)
    perform fn_ponto_wa(v_tec.telefone_e164,
      '✅ *Ponto registrado*' || E'\n\n'
      || '*' || fn_ponto_rotulo(c->>'tipo') || '* — ' || (c->>'data') || ' às ' || (c->>'hora') || E'\n'
      || 'NSR ' || (c->>'nsr') || ' · ' || (c->>'empresa') || E'\n'
      || (c->>'trabalhador') || ' · CPF ***.' || substr(c->>'cpf', 4, 3) || '.' || substr(c->>'cpf', 7, 3) || '-**' || E'\n'
      || coalesce('Local: ' || (c->>'local') || case when (c->>'dentro_area')::boolean is false
                   then ' (a ' || (c->>'distancia_m') || ' m: o gestor será avisado)' else '' end || E'\n', '')
      || 'Autenticação: ' || (c->>'autenticacao')
      -- avisos de jornada (intervalo, hora extra, interjornada): a marcação vale, o gestor é avisado
      || coalesce(E'\n\n' || array_to_string(fn_ponto_avisar(v_tec.id, c->>'tipo'), E'\n'), ''));
    return jsonb_build_object('acao', 'ponto_registrado', 'nsr', c->'nsr');
  end if;

  -- Recusa de escala aberta esperando o motivo, sem conversa do ponto aberta depois dela (a recusa fecha a
  -- conversa que havia, em fn_wh_mensagem): o número ou a palavra solta é a resposta do técnico — "1" é o
  -- motivo, "almoço" pode ser o problema — e segue para as escalas. Pedir "ponto" de propósito ainda abre o
  -- menu, e o botão do ponto continua valendo. Com o motivo já dado, o detalhe é opcional: os atalhos do
  -- ponto ("entrada", "saída") voltam a valer, e o resto do texto segue como detalhe (regra mais abaixo)
  if v_btn is null and v_conv.tecnico_id is null
     and v_norm not in ('ponto', 'bater ponto', 'registro de ponto', 'registrar ponto', 'marcar ponto')
     and exists (select 1 from ocorrencias o join escalas e on e.id = o.escala_id
                  where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.motivo is null
                    and o.created_at > now() - interval '2 hours') then
    return null;
  end if;

  -- 2. Botão, número do menu ou palavra do ponto
  if v_btn is not null then
    -- botão de outro fluxo (escala) segue para as escalas
    if v_btn !~ '^ponto:(entrada|saida_almoco|volta_almoco|saida|inicio_he|fim_he)$' then return null; end if;
    v_tipo := substring(v_btn from 7);
  elsif v_conv.tecnico_id is not null and v_conv.etapa = 'escolher_tipo' and v_norm ~ '^[1-6]$' and not v_citou then
    -- número só vale como escolha do menu se não for resposta citando outra mensagem (ex.: a escala)
    v_tipo := (array['entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he'])[v_norm::int];
  elsif v_conv.tecnico_id is not null and not v_citou and v_norm in ('0', 'cancelar', 'sair') then
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    perform fn_ponto_wa(v_tec.telefone_e164, 'Registro de ponto cancelado. Para recomeçar, escreva *ponto*.');
    return jsonb_build_object('acao', 'ponto_cancelado');
  elsif v_norm in ('entrada', 'entrei', 'cheguei', 'inicio do expediente') then
    v_tipo := 'entrada';
  elsif v_norm in ('almoco', 'saida almoco', 'saida para almoco', 'saida para o almoco', 'sai para almoco', 'intervalo') then
    v_tipo := case when v_ultima = 'saida_almoco' then 'volta_almoco' else 'saida_almoco' end;
  elsif v_norm in ('volta', 'volta do almoco', 'voltei', 'retorno', 'retorno do almoco') then
    v_tipo := 'volta_almoco';
  elsif v_norm in ('saida', 'fim do expediente') then
    v_tipo := 'saida';
  elsif v_norm in ('he', 'hora extra', 'horas extras') then
    v_tipo := case when v_ultima = 'inicio_he' then 'fim_he' else 'inicio_he' end;
  elsif v_norm in ('ponto', 'bater ponto', 'registro de ponto', 'registrar ponto', 'marcar ponto') then
    perform fn_ponto_menu(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_ultima, null);
    return jsonb_build_object('acao', 'ponto_menu');
  elsif v_norm ~ '^(1|2|s|n|sim|nao|ok|ciente|confirmado|confirmada|confirmo|ciente, confirmado|problema|tenho um problema)$'
     or exists (select 1 from ocorrencias o join escalas e on e.id = o.escala_id
                 where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.detalhe is null
                   and o.created_at > now() - interval '2 hours') then
    -- resposta típica de escala, ou detalhe de ocorrência aberta (como em fn_wh_mensagem): segue
    -- para as escalas mesmo dentro da conversa do ponto
    return null;
  elsif v_conv.tecnico_id is not null and not v_citou and v_norm <> '' then
    -- dentro da conversa do ponto, resposta que não é opção válida volta para o menu
    perform fn_ponto_menu(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_ultima, 'Não entendi essa opção.');
    return jsonb_build_object('acao', 'ponto_menu_repetido');
  else
    return null;   -- não é do ponto: segue para as escalas
  end if;

  insert into ponto_conversas (tecnico_id, etapa, tipo, expira_em)
  values (v_tec.id, 'aguardando_local', v_tipo, now() + interval '10 minutes')
  on conflict (tecnico_id) do update set etapa = 'aguardando_local', tipo = excluded.tipo, expira_em = excluded.expira_em;
  -- aviso ANTES de registrar a volta do almoço com intervalo abaixo do mínimo (não bloqueia)
  v_aviso := fn_ponto_aviso_previo(v_tec.id, v_tipo);
  perform fn_ponto_wa(v_tec.telefone_e164,
    coalesce(v_aviso || E'\n\n', '')
    || '*' || fn_ponto_rotulo(v_tipo) || '*. Agora mande a sua *localização atual*:' || E'\n'
    || '📎 → Localização → *Enviar localização atual*.' || E'\n\n'
    || 'A hora registrada é a do recebimento da localização.');
  return jsonb_build_object('acao', 'ponto_pediu_localizacao', 'tipo', v_tipo);
end $function$;

create or replace function interno.fn_ponto_he_resposta(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_key jsonb := p_data->'key';
  v_msg jsonb := p_data->'message';
  v_btn text;
  v_jid text;
  v_sup record;
  v_id  uuid;
  h     record;
  r     jsonb;
begin
  if coalesce((v_key->>'fromMe')::boolean, false) then return null; end if;
  v_btn := coalesce(v_msg->'buttonsResponseMessage'->>'selectedButtonId', v_msg->'templateButtonReplyMessage'->>'selectedId');
  if v_btn is null and v_msg ? 'interactiveResponseMessage' then
    begin
      v_btn := ((v_msg->'interactiveResponseMessage'->'nativeFlowResponseMessage'->>'paramsJson')::jsonb)->>'id';
    exception when others then v_btn := null;
    end;
  end if;
  if v_btn is null or v_btn !~ '^he:(ok|nao):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return null; end if;
  v_id := split_part(v_btn, ':', 3)::uuid;

  select j into v_jid from unnest(array[v_key->>'remoteJid', v_key->>'remoteJidAlt', v_key->>'senderPn', p_data->>'sender']) as j
   where j like '%@s.whatsapp.net' limit 1;
  select t.id, t.nome, t.telefone_e164, t.empresa_id into v_sup from tecnicos t
   where t.is_supervisor and t.ativo and t.opt_in and not t.perfil_teste and fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(coalesce(v_jid, ''), '@', 1))
     and t.conta_id = coalesce(fn_conta_contexto(), t.conta_id);   -- F5b: só a conta da instância que recebeu
  if v_sup.id is null then return jsonb_build_object('ignorado', 'hora extra: resposta de quem não é supervisor'); end if;
  select * into h from ponto_he_autorizacoes where id = v_id;
  if h.id is null or h.tecnico_id = v_sup.id or v_sup.empresa_id is distinct from h.empresa_id then
    return jsonb_build_object('ignorado', 'hora extra: pedido de outra empresa ou inexistente');
  end if;
  begin
    r := fn_ponto_he_decidir(v_id, split_part(v_btn, ':', 2) = 'ok', 'WhatsApp · ' || v_sup.nome, 'whatsapp');
  exception when others then
    -- falha de infraestrutura sobe para o reenvio; ao gestor só a mensagem de regra, nunca o detalhe técnico
    if fn_erro_infra(sqlstate) then raise; end if;
    perform fn_ponto_wa(v_sup.telefone_e164, case when sqlstate = 'P0001'
      then 'Não foi possível registrar a decisão da hora extra: ' || sqlerrm
      else 'Não foi possível registrar a decisão da hora extra agora. Toque no botão de novo em alguns minutos.' end);
    return jsonb_build_object('acao', 'he_erro');
  end;
  perform fn_ponto_wa(v_sup.telefone_e164, case r->>'situacao'
    when 'ja_decidida' then 'O pedido de hora extra nº ' || (r->>'numero') || ' já tinha sido decidido.'
    when 'aprovada' then '✅ Hora extra nº ' || (r->>'numero') || ' de ' || (r->>'nome') || ' aprovada. O funcionário foi avisado.'
    else '❌ Hora extra nº ' || (r->>'numero') || ' de ' || (r->>'nome') || ' não autorizada. O funcionário foi avisado.' end);
  return jsonb_build_object('acao', 'he_' || (r->>'situacao'), 'numero', r->'numero');
end $function$;

-- 5. Retenção do log do webhook: no mínimo 1 dia (é o controle de reenvio)
create or replace function interno.fn_validar_config()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v text := coalesce(new.valor, '');
begin
  begin
    if new.chave in ('envios_por_execucao','envios_por_conta_por_execucao','max_tentativas','avisar_supervisor_na','intervalo_reenvio_min',
                     'timeout_entrega_min','motor_alerta_min','jornada_min','intervalo_min','intervalo_apos_min',
                     'antecedencia_minima_min','certificacao_aviso_dias','documento_tamanho_max_mb',
                     'ligacao_apos_tentativas','ligacao_intervalo_min','ligacao_max_por_escala',
                     'ligacao_por_execucao','voz_timeout_dtmf','retencao_webhook_dias','retencao_cron_dias',
                     'retencao_documentos_anos','retencao_payload_dias','conclusao_automatica_min',
                     'banco_alerta_mb','alerta_certificacoes_dow',
                     'regua_lembrete_min','regua_ligacao_min','regua_final_min','ligacao_max_por_dia') then
      if v !~ '^\d+$' then raise exception 'inteiro'; end if;
      -- 0 desliga; 1 (segunda) a 7 (domingo), o mesmo dia ISO que fn_alerta_certificacoes compara como
      -- texto: um dígito só ('07' passaria no inteiro e nunca dispararia)
      if new.chave = 'alerta_certificacoes_dow' and v !~ '^[0-7]$' then raise exception 'dia'; end if;
      -- régua: passo zero dispararia junto com a escala
      if new.chave in ('regua_lembrete_min','regua_ligacao_min','regua_final_min') and v::int < 1 then
        raise exception 'positivo';
      end if;
      -- o log do webhook é também o controle de reenvio (migration 152): zero apagaria tudo a cada limpeza
      if new.chave = 'retencao_webhook_dias' and v::int < 1 then raise exception 'positivo'; end if;
    elsif new.chave = 'hora_noturna_min' then
      if v::numeric <= 0 then raise exception 'positivo'; end if;
    elsif new.chave in ('janela_envio_inicio','janela_envio_fim','alerta_escala_aviso','alerta_escala_prazo',
                        'alerta_certificacoes_hora','ligacao_janela_inicio','ligacao_janela_fim',
                        'noturno_inicio','noturno_fim','regua_fim') then
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
      -- só o endereço de ping do healthchecks.io: a URL é chamada pelo motor a cada minuto
      if v <> '' and v !~ '^https://hc-ping\.com/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'url';
      end if;
    end if;
  exception when others then
    raise exception 'Valor inválido para %: "%"', new.chave, new.valor
      using hint = case new.chave
        when 'alerta_dias_semana' then 'Use dias de 1 (segunda) a 7, separados por vírgula: 1,2,3,4,5'
        when 'alerta_certificacoes_dow' then 'Use 1 (segunda) a 7 (domingo); 0 desliga o alerta'
        when 'monitor_ping_url' then 'Use o endereço de ping do healthchecks.io: https://hc-ping.com/<uuid>, ou vazio'
        when 'alerta_tecnico_telefones' then 'Use telefones com DDI e DDD, só números, separados por vírgula: 5571999999999'
        when 'retencao_webhook_dias' then 'Use um número inteiro de dias, a partir de 1'
        when 'fuso' then 'Use um fuso válido, por exemplo America/Bahia'
        else 'Confira o formato: inteiro, hora HH:MM ou true/false' end;
  end;
  return new;
end $function$;

reset lock_timeout;

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
