-- 153: travas do incidente de 12/11 (homologação pareada no número da produção), B4.1 (ordem na conversa do ponto) e
-- silêncio do ponto para técnico sem autorização do WhatsApp (decisão 137).
--
-- 1. Portão do webhook: o número dono da instância (campo "sender" de todo evento da Evolution v2) tem de ser o
--    esperado da conta (config evolution_numero na conta 1; conta_canais.numero_esperado nas outras). Diferente:
--    não grava conteúdo, alerta (no máximo 1 e-mail por hora) e responde 200. Na homologação, sem número esperado
--    cadastrado, recusa tudo; na produção, sem número cadastrado, segue como antes.
-- 2. Homologação: só os números de telefones_homologacao têm conteúdo gravado e processado; o resto (inclusive
--    grupos e o que o próprio número enviou a outras pessoas) fica só com a marca, e alerta 1 vez por dia.
--    Retenção do log da homologação: 7 dias.
-- 3. B4.1: mensagem com carimbo anterior à última que a conversa do ponto consumiu é ignorada nos ramos do ponto.
-- 4. Ponto pelo WhatsApp não responde nem registra para técnico sem autorização (opt_in), como a tela promete.
-- 5. fn_ponto_wh_ajuste sobe falha de infraestrutura para o reenvio (pendência da 152).
set lock_timeout = '5s';

-- número esperado das instâncias das outras contas (a conta 1 fica na config, como url e instância)
alter table interno.conta_canais add column if not exists numero_esperado text;
alter table interno.conta_canais drop constraint if exists conta_canais_numero_esperado_ck;
alter table interno.conta_canais add constraint conta_canais_numero_esperado_ck check (numero_esperado ~ '^\d{12,13}$');
-- o mesmo número em duas contas é o formato do incidente
create unique index if not exists conta_canais_numero_esperado_uk on interno.conta_canais (interno.fn_tel_canonico(numero_esperado))
  where numero_esperado is not null;

-- carimbo da última mensagem do técnico que a conversa do ponto consumiu (B4.1)
alter table interno.ponto_conversas add column if not exists ultima_msg_em timestamptz;

insert into interno.config (chave, valor, descricao)
values ('evolution_numero', '', 'Número do WhatsApp dono da instância da conta 1 (só dígitos). Evento de outro número é recusado; '
        || 'na homologação, vazio recusa tudo (migration 153)')
on conflict (chave) do nothing;

-- retenção do log da homologação: 7 dias (o valor só desce; produção e banco vazio têm ambiente = producao)
update interno.config set valor = '7'
 where chave = 'retencao_webhook_dias' and valor ~ '^\d+$' and valor::int > 7
   and coalesce(interno.fn_config('ambiente'), 'producao') = 'homologacao';

-- o número de uma conta não pode ser o da conta 1 (entre tabelas não dá restrição)
create or replace function interno.fn_conta_canais_numero()
returns trigger
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $function$
begin
  if new.numero_esperado is not null
     and interno.fn_tel_canonico(new.numero_esperado) = interno.fn_tel_canonico(nullif(fn_config('evolution_numero'), '')) then
    raise exception 'O número % já é o da instância da conta principal', right(new.numero_esperado, 4)
      using hint = 'Cada instância do WhatsApp precisa de um número próprio (incidente de 12/11, decisão 137)';
  end if;
  return new;
end $function$;
drop trigger if exists tg_conta_canais_numero on interno.conta_canais;
create trigger tg_conta_canais_numero before insert or update of numero_esperado on interno.conta_canais
  for each row execute function interno.fn_conta_canais_numero();

-- B4.1: toda gravação na conversa do ponto feita no processamento de uma mensagem guarda o maior carimbo visto.
-- Fora do webhook (cron, mídia pela Edge, painel) a configuração está vazia e o valor fica.
create or replace function interno.fn_ponto_conversas_msg_ts()
returns trigger
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $function$
declare v text := nullif(current_setting('trilha.msg_ts', true), '');
begin
  if tg_op = 'UPDATE' then new.ultima_msg_em := greatest(old.ultima_msg_em, new.ultima_msg_em); end if;
  if v is not null then new.ultima_msg_em := greatest(new.ultima_msg_em, v::timestamptz); end if;
  return new;
end $function$;
drop trigger if exists tg_10_msg_ts on interno.ponto_conversas;
create trigger tg_10_msg_ts before insert or update on interno.ponto_conversas
  for each row execute function interno.fn_ponto_conversas_msg_ts();

-- alerta do webhook com teto por janela: trava contra a rajada simultânea; falha no alerta nunca muda a resposta
create or replace function interno.fn_webhook_alertar(p_assunto text, p_texto text, p_janela interval)
returns void
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $function$
begin
  perform pg_advisory_xact_lock(hashtext('webhook-alerta:' || p_assunto));
  if exists (select 1 from alertas_email where assunto = p_assunto and criado_em > now() - p_janela) then return; end if;
  perform fn_alerta_email(p_assunto, p_texto, null, false);
exception when others then
  raise warning 'webhook: alerta não registrado (%)', sqlstate;
end $function$;

-- portão do webhook: devolve null para seguir, ou o resultado da recusa (já registrada sem conteúdo)
create or replace function interno.fn_webhook_portao(p_conta uuid, p_evento text, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $function$
declare
  v_homolog  boolean := coalesce(fn_config('ambiente'), 'producao') = 'homologacao';
  v_dono     text := substring(coalesce(p_payload->>'sender', '') from '^(\d{10,15})(?::\d+)?@s\.whatsapp\.net$');
  v_esperado text;
  v_jid      text := coalesce(p_payload->'data'->'key'->>'remoteJid', p_payload->'data'->>'remoteJid', '');
  v_num      text;
  v_conta    text := left(p_conta::text, 8);
begin
  v_esperado := case when p_conta = '00000000-0000-0000-0000-000000000001' then nullif(fn_config('evolution_numero'), '')
                     else (select c.numero_esperado from conta_canais c where c.conta_id = p_conta) end;

  -- 1. número dono da instância (na homologação, sem número esperado, nada entra)
  if v_esperado is not null or v_homolog then
    if v_dono is null and p_evento not like 'messages.%' then
      -- pareamento ou logout (qrcode, connection) ainda sem dono: só a marca
      insert into webhook_eventos (conta_id, evento, payload, resultado)
      values (p_conta, p_evento, jsonb_build_object('instance', p_payload->>'instance'), 'ignorado: sem dono');
      return jsonb_build_object('ignorado', 'sem dono');
    end if;
    if v_esperado is null or v_dono is null or fn_tel_canonico(v_dono) <> fn_tel_canonico(v_esperado) then
      insert into webhook_eventos (conta_id, evento, payload, resultado)
      values (p_conta, p_evento, jsonb_build_object('instance', p_payload->>'instance', 'dono_final', right(v_dono, 4)),
              'recusado: instancia em numero errado');
      perform fn_webhook_alertar('Trilha: WhatsApp no número errado (conta ' || v_conta || ')',
        'A instância "' || coalesce(p_payload->>'instance', '?') || '" está conectada a um número diferente do cadastrado'
        || case when v_esperado is null then ' (nenhum número cadastrado nesta instalação)' else '' end
        || '. As mensagens dela estão sendo recusadas sem gravar conteúdo. Confira no Manager da Evolution qual celular '
        || 'leu o QR e o número em evolution_numero / conta_canais.numero_esperado (decisão 137).', interval '1 hour');
      return jsonb_build_object('ignorado', 'instancia em numero errado');
    end if;
  end if;

  -- 2. homologação: conteúdo só dos números de teste
  if v_homolog then
    if p_evento not in ('messages.upsert', 'messages.update') then
      insert into webhook_eventos (conta_id, evento, payload, resultado)
      values (p_conta, p_evento, jsonb_build_object('instance', p_payload->>'instance'), 'ignorado: evento fora do teste');
      return jsonb_build_object('ignorado', p_evento);
    end if;
    select split_part(j, '@', 1) into v_num
      from unnest(array[p_payload->'data'->'key'->>'remoteJid', p_payload->'data'->'key'->>'remoteJidAlt',
                        p_payload->'data'->'key'->>'senderPn', p_payload->'data'->>'remoteJid']) j
     where j ~ '^\d{10,15}@s\.whatsapp\.net$' limit 1;
    if v_jid ~ '@(g\.us|broadcast|newsletter)$'
       or (v_num is null and p_evento = 'messages.upsert')
       or (v_num is not null and not exists (
             select 1 from regexp_split_to_table(coalesce(fn_config('telefones_homologacao'), ''), '\s*,\s*') t
              where t <> '' and fn_tel_canonico(t) = fn_tel_canonico(v_num))) then
      insert into webhook_eventos (conta_id, evento, payload, resultado)
      values (p_conta, p_evento, jsonb_build_object('instance', p_payload->>'instance', 'fora_da_lista', true),
              'descartado: fora da lista');
      perform fn_webhook_alertar('Trilha homologação: mensagem de fora da lista de teste',
        'A homologação recebeu mensagem de um número fora de telefones_homologacao (ou de grupo). O conteúdo não foi '
        || 'gravado. Se repetir, a instância de homologação pode estar no número da produção (decisão 137).', interval '1 day');
      return jsonb_build_object('ignorado', 'fora da lista');
    end if;
  end if;
  return null;
end $function$;

-- recepção do webhook: portão antes de tudo e carimbo da mensagem para a conversa do ponto (definição da 152)
create or replace function interno.fn_webhook_evolution(p_token text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  -- portão (migration 153, decisão 137): instância no número errado e, na homologação, só os números de teste
  v_res := fn_webhook_portao(v_conta, v_evento, p_payload);
  if v_res is not null then return v_res; end if;

  -- mensagem com conteúdo e id (migration 152): é ela que o reenvio poderia processar duas vezes. Evento de
  -- sistema (messageStubType) ou sem message não tem controle: segue como antes.
  if v_evento = 'messages.upsert' and jsonb_typeof(p_payload->'data'->'message') = 'object'
     and p_payload->'data'->>'messageStubType' is null then   -- ->>: o JSON null também conta como ausente
    v_id := nullif(left(p_payload->'data'->'key'->>'id', 128), '');
  end if;
  begin
    v_ts := to_timestamp((p_payload->'data'->>'messageTimestamp')::bigint);
  exception when others then v_ts := null;   -- carimbo ausente ou fora do formato: sem controle de atraso
  end;
  -- carimbo da mensagem para a ordem da conversa do ponto (gatilho em ponto_conversas, B4.1); nunca no futuro
  if v_evento = 'messages.upsert' then
    perform set_config('trilha.msg_ts', coalesce(least(v_ts, now() + interval '1 minute')::text, ''), true);
  end if;
  -- número do remetente para o aviso de perda: a mesma busca do ponto (o endereço pode chegar como LID)
  if not coalesce((p_payload->'data'->'key'->>'fromMe')::boolean, false)
     and coalesce(p_payload->'data'->'key'->>'remoteJid', '') !~ '@(g\.us|broadcast|newsletter)$' then
    select split_part(j, '@', 1) into v_tel
      from unnest(array[p_payload->'data'->'key'->>'remoteJid', p_payload->'data'->'key'->>'remoteJidAlt',
                        p_payload->'data'->'key'->>'senderPn', p_payload->'data'->>'sender']) as j
     where j ~ '^\d{10,15}@s\.whatsapp\.net$' limit 1;
  end if;

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

-- ponto pelo WhatsApp: sem autorização, silêncio; mensagem fora de ordem ignorada nos ramos do ponto (definição da 152)
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
  v_ult    timestamptz;
  v_tsm    timestamptz;
  v_antiga boolean;
begin
  if coalesce((v_key->>'fromMe')::boolean, false) or v_wa_id is null then return null; end if;
  -- grupo, status e canal não são do ponto
  if coalesce(v_key->>'remoteJid', '') ~ '@(g\.us|broadcast|newsletter)$' then return null; end if;
  select j into v_jid from unnest(array[v_key->>'remoteJid', v_key->>'remoteJidAlt',
                                        v_key->>'senderPn', p_data->>'sender']) as j
   where j like '%@s.whatsapp.net' limit 1;
  if v_jid is null then return null; end if;

  select t.id, t.nome, t.telefone_e164, t.cpf, t.empresa_id, coalesce(e.fuso, 'America/Bahia') as fuso, t.opt_in
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
  -- sem a autorização do WhatsApp ("o sistema não envia nenhuma mensagem para este técnico"): silêncio total,
  -- nada é registrado; o app do ponto continua valendo (migration 153)
  if not coalesce(v_tec.opt_in, false) then return jsonb_build_object('ignorado', 'ponto: sem autorizacao WhatsApp'); end if;

  -- trava a conversa: duas localizações simultâneas não geram duas marcações
  select * into v_conv from ponto_conversas where tecnico_id = v_tec.id and expira_em > now() for update;
  -- B4.1 (migration 153): mensagem com carimbo anterior à última que o ponto já consumiu chegou fora de ordem
  -- (reenvio depois de falha): não volta o menu nem cancela o passo seguinte. Vale só nos ramos do ponto;
  -- o que segue para as escalas não é descartado aqui
  select pc.ultima_msg_em into v_ult from ponto_conversas pc where pc.tecnico_id = v_tec.id;
  begin
    v_tsm := least(to_timestamp((p_data->>'messageTimestamp')::bigint), now() + interval '1 minute');
  exception when others then v_tsm := null;
  end;
  v_antiga := coalesce(v_tsm < v_ult, false);
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
    if v_antiga then return jsonb_build_object('ignorado', 'ponto: mensagem antiga'); end if;
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
    if v_antiga then return jsonb_build_object('ignorado', 'ponto: mensagem antiga'); end if;
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
    if v_antiga then return jsonb_build_object('ignorado', 'ponto: mensagem antiga'); end if;
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
    if v_antiga then return jsonb_build_object('ignorado', 'ponto: mensagem antiga'); end if;
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
    if v_antiga then return jsonb_build_object('ignorado', 'ponto: mensagem antiga'); end if;
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
    if v_antiga then return jsonb_build_object('ignorado', 'ponto: mensagem antiga'); end if;
    perform fn_ponto_menu(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_ultima, 'Não entendi essa opção.');
    return jsonb_build_object('acao', 'ponto_menu_repetido');
  else
    return null;   -- não é do ponto: segue para as escalas
  end if;

  if v_antiga then return jsonb_build_object('ignorado', 'ponto: mensagem antiga'); end if;
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

-- pedido de ajuste: infraestrutura sobe para o reenvio
create or replace function interno.fn_ponto_wh_ajuste(p_tecnico uuid, p_nome text, p_tel text, p_fuso text, p_etapa text, p_dados jsonb, p_norm text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_dados jsonb := coalesce(p_dados, '{}');
  v_hoje  date := (now() at time zone p_fuso)::date;
  v_data  date;
  v_hora  time;
  v_ini   time;
  v_fim   time;
  v_par   text[];
  r       jsonb;
  v_mot   record;
  v_grupo text;
  v_lista text[];
  v_dfim  date;
  v_menu  text := 'Ajuste de ponto, ' || split_part(trim(p_nome), ' ', 1) || '. O que aconteceu? Responda o número:' || E'\n'
    || '*1* Saúde: atestado, consulta ou exame' || E'\n'
    || '*2* Família: falecimento, casamento ou nascimento' || E'\n'
    || '*3* Convocação: justiça, eleição ou outra' || E'\n'
    || '*4* Ponto: esqueci de marcar, atrasei ou o app falhou' || E'\n'
    || '*0* Cancelar';
  v_marc  text := 'Qual marcação ficou faltando?' || E'\n'
    || '*1* Entrada  *2* Saída para almoço  *3* Volta do almoço' || E'\n'
    || '*4* Saída  *5* Início de hora extra  *6* Fim de hora extra';
begin
  if p_norm in ('0', 'cancelar', 'sair') then
    update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Pedido de ajuste cancelado. Para recomeçar, escreva *ajuste*.');
    return jsonb_build_object('acao', 'ajuste_cancelado');
  end if;

  if p_etapa is null or p_norm in ('ajuste', 'justificar', 'justificativa') then
    insert into ponto_conversas (tecnico_id, etapa, tipo, dados, expira_em)
    values (p_tecnico, 'aj_menu', null, jsonb_build_object('inicio', now()), now() + interval '15 minutes')
    on conflict (tecnico_id) do update set etapa = 'aj_menu', tipo = null, dados = excluded.dados, expira_em = excluded.expira_em;
    perform fn_ponto_wa(p_tel, v_menu);
    return jsonb_build_object('acao', 'ajuste_menu');
  end if;

  if p_etapa = 'aj_menu' then
    if p_norm in ('1', '2', '3') then
      v_grupo := (array['saude', 'familia', 'convocacao'])[p_norm::int];
      v_dados := v_dados || jsonb_build_object('grupo', v_grupo);
      update ponto_conversas set etapa = 'aj_falta_motivo', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, fn_ponto_menu_falta(v_grupo));
      return jsonb_build_object('acao', 'ajuste_falta_menu', 'grupo', v_grupo);
    elsif p_norm = '4' then
      update ponto_conversas set etapa = 'aj_motivo', expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, '*Ponto.* O que aconteceu?' || E'\n' || '*1* Esqueci de marcar' || E'\n'
        || '*2* O app ou o WhatsApp não funcionou' || E'\n' || '*3* Cheguei atrasado ou saí mais cedo' || E'\n'
        || '*0* Cancelar' || E'\n' || 'O gestor analisa cada caso.');
      return jsonb_build_object('acao', 'ajuste_ponto');
    end if;
    perform fn_ponto_wa(p_tel, 'Não entendi essa opção.' || E'\n\n' || v_menu);
    return jsonb_build_object('acao', 'ajuste_menu_repetido');
  end if;

  if p_etapa = 'aj_motivo' then
    if p_norm not in ('1', '2', '3') then
      perform fn_ponto_wa(p_tel, 'Responda *1*, *2* ou *3*, ou *0* para cancelar.');
      return jsonb_build_object('acao', 'ajuste_motivo_repetido');
    end if;
    v_dados := v_dados || jsonb_build_object('motivo', (array['esqueci_marcar', 'falha_registro', 'atraso_saida'])[p_norm::int]);
    update ponto_conversas set etapa = 'aj_dia', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Qual dia? Ex.: *15/10*. Responda *hoje* ou *ontem*, se for o caso.');
    return jsonb_build_object('acao', 'ajuste_pediu_dia');
  end if;

  if p_etapa = 'aj_dia' then
    v_data := fn_ponto_ler_data(p_norm, v_hoje);
    if v_data is null or v_data > v_hoje or v_data < v_hoje - 62 then
      perform fn_ponto_wa(p_tel, 'Não entendi o dia. Responda como *15/10*, *hoje* ou *ontem* (até 62 dias atrás).');
      return jsonb_build_object('acao', 'ajuste_dia_repetido');
    end if;
    v_dados := v_dados || jsonb_build_object('data', v_data);
    if v_dados->>'motivo' = 'atraso_saida' then
      update ponto_conversas set etapa = 'aj_periodo', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, 'Qual período? Ex.: *8h às 9h*.');
      return jsonb_build_object('acao', 'ajuste_pediu_periodo');
    end if;
    update ponto_conversas set etapa = 'aj_marcacao', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, v_marc);
    return jsonb_build_object('acao', 'ajuste_pediu_marcacao');
  end if;

  if p_etapa = 'aj_marcacao' then
    if p_norm !~ '^[1-6]$' then
      perform fn_ponto_wa(p_tel, 'Responda o número de *1* a *6*.' || E'\n\n' || v_marc);
      return jsonb_build_object('acao', 'ajuste_marcacao_repetida');
    end if;
    v_dados := v_dados || jsonb_build_object('tipo', (array['entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he'])[p_norm::int]);
    update ponto_conversas set etapa = 'aj_hora', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Que horas foi? Ex.: *7h30*.');
    return jsonb_build_object('acao', 'ajuste_pediu_hora');
  end if;

  -- Faltas com documento (E2b): motivo do grupo, dia, último dia ou horário e, por fim, a foto ou o PDF
  if p_etapa = 'aj_falta_motivo' then
    v_lista := fn_ponto_motivos_grupo(v_dados->>'grupo');
    if p_norm ~ '^\d{1,2}$' then
      if p_norm::int between 1 and coalesce(array_length(v_lista, 1), 0) then
        v_dados := v_dados || jsonb_build_object('motivo', v_lista[p_norm::int]);
      end if;
    end if;
    if not v_dados ? 'motivo' then
      perform fn_ponto_wa(p_tel, 'Não entendi essa opção.' || E'\n\n' || fn_ponto_menu_falta(v_dados->>'grupo'));
      return jsonb_build_object('acao', 'ajuste_falta_menu_repetido');
    end if;
    update ponto_conversas set etapa = 'aj_falta_dia', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, case v_dados->>'motivo'
      when 'atestado' then 'Qual é o *primeiro dia* do atestado? Ex.: *15/10*. Responda *hoje* ou *ontem*, se for o caso.'
      when 'alta_medica' then 'Qual é o dia da *alta* (data do atestado de aptidão)? Ex.: *15/10*, *hoje* ou *ontem*.'
      else 'Qual dia? Ex.: *15/10*. Responda *hoje* ou *ontem*, se for o caso.' end);
    return jsonb_build_object('acao', 'ajuste_falta_pediu_dia');
  end if;

  if p_etapa = 'aj_falta_dia' then
    v_data := fn_ponto_ler_data(p_norm, v_hoje);
    if v_data is null or v_data > v_hoje or v_data < v_hoje - 62 then
      perform fn_ponto_wa(p_tel, 'Não entendi o dia. Responda como *15/10*, *hoje* ou *ontem* (até 62 dias atrás).');
      return jsonb_build_object('acao', 'ajuste_falta_dia_repetido');
    end if;
    v_dados := v_dados || jsonb_build_object('data', v_data);
    select * into v_mot from ponto_motivos where codigo = v_dados->>'motivo';
    if v_mot.abrange = 'horario' then
      update ponto_conversas set etapa = 'aj_falta_periodo', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, 'Qual horário? Ex.: *8h às 10h*. Vale só o horário da consulta ou do exame.');
      return jsonb_build_object('acao', 'ajuste_falta_pediu_periodo');
    end if;
    if v_mot.codigo = 'alta_medica' or (v_mot.unidade = 'dias' and v_mot.quantidade = 1) then
      return fn_ponto_pedir_documento(p_tecnico, p_tel, v_dados);
    end if;
    update ponto_conversas set etapa = 'aj_falta_fim', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, case when v_mot.codigo = 'atestado'
      then 'Até que dia *vale* o atestado? Ex.: *20/10*. Se for só esse dia, responda *mesmo*.' || E'\n'
        || 'Dentro da validade, o ponto e as programações ficam bloqueados.'
      else 'Qual foi o *último dia*? Ex.: *17/10*. Se foi só esse dia, responda *mesmo*.' end);
    return jsonb_build_object('acao', 'ajuste_falta_pediu_fim');
  end if;

  if p_etapa = 'aj_falta_fim' then
    v_data := (v_dados->>'data')::date;
    v_dfim := case when p_norm in ('mesmo', 'mesmo dia', 'so esse', 'so esse dia', 'so hoje') then v_data
                   when p_norm in ('hoje', 'ontem') then fn_ponto_ler_data(p_norm, v_hoje)
                   else fn_ponto_ler_data(p_norm, v_hoje + 31) end;
    if v_dfim is null or v_dfim < v_data or v_dfim - v_data > 30 or v_dfim > v_hoje + 30 then
      perform fn_ponto_wa(p_tel, 'Não entendi o último dia. Responda como *20/10* ou *mesmo* (a partir de '
        || to_char(v_data, 'DD/MM') || ', até 31 dias). Acima de 15 dias de atestado, o caso vai ao INSS: fale com o gestor.');
      return jsonb_build_object('acao', 'ajuste_falta_fim_repetido');
    end if;
    return fn_ponto_pedir_documento(p_tecnico, p_tel, v_dados || jsonb_build_object('data_fim', v_dfim));
  end if;

  if p_etapa = 'aj_falta_periodo' then
    v_par := regexp_split_to_array(p_norm, '\s*(?:as|a|ate|-)\s+|\s*-\s*');
    if array_length(v_par, 1) = 2 then v_ini := fn_ponto_ler_hora(v_par[1]); v_fim := fn_ponto_ler_hora(v_par[2]); end if;
    if v_ini is null or v_fim is null or v_ini >= v_fim then
      perform fn_ponto_wa(p_tel, 'Não entendi o horário. Responda como *8h às 10h* (o início antes do fim).');
      return jsonb_build_object('acao', 'ajuste_falta_periodo_repetido');
    end if;
    return fn_ponto_pedir_documento(p_tecnico, p_tel, v_dados || jsonb_build_object('hora_ini', v_ini, 'hora_fim', v_fim));
  end if;

  if p_etapa = 'aj_documento' then
    perform fn_ponto_wa(p_tel, 'Estou aguardando a *foto* ou o *PDF* do documento: toque no 📎 e escolha Câmera ou Documento.'
      || E'\n' || 'Para cancelar, responda *0*.');
    return jsonb_build_object('acao', 'ajuste_aguardando_documento');
  end if;

  if p_etapa = 'aj_hora' then
    v_hora := fn_ponto_ler_hora(p_norm);
    if v_hora is null then
      perform fn_ponto_wa(p_tel, 'Não entendi o horário. Responda como *7h30* ou *17:05*.');
      return jsonb_build_object('acao', 'ajuste_hora_repetida');
    end if;
  elsif p_etapa = 'aj_periodo' then
    v_par := regexp_split_to_array(p_norm, '\s*(?:as|a|ate|-)\s+|\s*-\s*');
    if array_length(v_par, 1) = 2 then v_ini := fn_ponto_ler_hora(v_par[1]); v_fim := fn_ponto_ler_hora(v_par[2]); end if;
    if v_ini is null or v_fim is null or v_ini >= v_fim then
      perform fn_ponto_wa(p_tel, 'Não entendi o período. Responda como *8h às 9h* (o início antes do fim).');
      return jsonb_build_object('acao', 'ajuste_periodo_repetido');
    end if;
  else
    return null;
  end if;

  begin
    r := fn_ponto_justificativa_criar(p_tecnico, v_dados->>'motivo', (v_dados->>'data')::date, v_dados->>'tipo',
                                      v_hora, v_ini, v_fim, null, 'whatsapp');
  exception when others then
    -- falha de infraestrutura sobe para o reenvio (migration 153; antes fechava a conversa e avisava o erro)
    if fn_erro_infra(sqlstate) then raise; end if;
    update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, case when sqlstate = 'P0001' then 'Não foi possível registrar o pedido: ' || sqlerrm
                                    else 'Não foi possível registrar o pedido agora. Tente de novo ou fale com o gestor.' end);
    return jsonb_build_object('acao', 'ajuste_erro', 'erro', sqlerrm);
  end;
  update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
  perform fn_ponto_wa(p_tel, '✅ *Pedido ' || (r->>'numero') || ' recebido*' || E'\n'
    || (r->>'motivo') || ' · ' || (r->>'data') || ' · ' || (r->>'detalhe') || E'\n'
    || 'O gestor vai analisar. A resposta chega aqui e na aba Ajuste do app.');
  return jsonb_build_object('acao', 'ajuste_registrado', 'numero', r->'numero');
end $function$;

-- config: evolution_numero
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
    elsif new.chave = 'evolution_numero' then
      -- número dono da instância da conta 1 (migration 153): só dígitos; não pode ser o de outra conta
      if v <> '' and v !~ '^\d{12,13}$' then raise exception 'numero'; end if;
      if v <> '' and exists (select 1 from conta_canais c where fn_tel_canonico(c.numero_esperado) = fn_tel_canonico(v)) then
        raise exception 'numero';
      end if;
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
        when 'evolution_numero' then 'Use o número do WhatsApp da instância, só dígitos com DDI e DDD (12 ou 13), ou vazio; não pode ser o de outra conta'
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
