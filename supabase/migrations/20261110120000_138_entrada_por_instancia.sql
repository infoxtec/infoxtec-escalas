-- Multiempresa F5b: entrada pela instância e telefone único por conta (decisão 126). O webhook descobre a conta pela
-- instância que recebeu a mensagem, com o token próprio daquela instância; tudo o que roda na mesma transação (procura
-- do funcionário, respostas) fica na conta dela (trilha.conta). O telefone passa a ser único dentro da conta: a mesma
-- pessoa pode estar em dois clientes. O motor e o pedido de código do ponto dizem a conta antes de enviar.

set lock_timeout = '5s';

-- telefone único por conta (a mesma pessoa em dois clientes, como o CPF da F6)
alter table interno.tecnicos drop constraint tecnicos_telefone_e164_key;
create unique index tecnicos_conta_telefone_uk on interno.tecnicos (conta_id, telefone_e164);
create index tecnicos_telefone_idx on interno.tecnicos (telefone_e164);

-- token do webhook por instância (nome do segredo no Vault)
alter table interno.conta_canais add column webhook_segredo text unique check (webhook_segredo ~ '^WEBHOOK_TOKEN_[0-9a-f]{32}$'),
  add column webhook_req bigint;   -- pedido do /webhook/set: a resposta (com o token) é apagada pelo vigia

-- conta do contexto do canal: a do webhook que chegou, a da escala que o motor envia ou a do cadastro do ponto
create or replace function interno.fn_conta_contexto()
 returns uuid
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select nullif(current_setting('trilha.conta', true), '')::uuid
$function$;

-- conta de quem recebe: a do contexto (webhook, motor, ponto) ou a da sessão do painel; senão, pelo telefone, que agora
-- pode estar em mais de uma conta (ambíguo: null, e o envio é recusado); sem funcionário, a operadora
create or replace function interno.fn_conta_do_numero(p_numero text)
 returns uuid
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_num text := regexp_replace(coalesce(p_numero, ''), '\D', '', 'g');
  v_ctx uuid := coalesce(interno.fn_conta_contexto(), interno.fn_conta_padrao());
  v_contas uuid[];
begin
  if v_ctx is not null then return v_ctx; end if;
  select array_agg(distinct t.conta_id) into v_contas from interno.tecnicos t where t.telefone_e164 = v_num;
  if v_contas is null then
    select array_agg(distinct t.conta_id) into v_contas from interno.tecnicos t
     where interno.fn_tel_canonico(t.telefone_e164) = interno.fn_tel_canonico(v_num);
  end if;
  if v_contas is null then return '00000000-0000-0000-0000-000000000001'; end if;
  if cardinality(v_contas) > 1 then return null; end if;
  return v_contas[1];
end $function$;

-- conta do webhook: instância da instalação com o token da instalação (operadora) ou instância de um canal ativo com o
-- token dela; qualquer outra combinação é recusada como token inválido
create or replace function interno.fn_webhook_conta(p_token text, p_instancia text)
 returns uuid
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare c conta_canais; v text;
begin
  if p_instancia is null or p_instancia = fn_config('evolution_instancia') then
    if fn_webhook_token_ok(p_token) then return '00000000-0000-0000-0000-000000000001'; end if;
    raise exception 'token invalido';
  end if;
  select * into c from conta_canais where instancia = p_instancia and ativo and webhook_segredo is not null;
  v := case when found then fn_segredo(c.webhook_segredo) end;
  if v is null or coalesce(p_token, '') = '' or extensions.digest(p_token, 'sha256') <> extensions.digest(v, 'sha256') then
    raise exception 'token invalido';
  end if;
  return c.conta_id;
end $function$;

-- canal para baixar a mídia de uma mensagem (Edge Function webhook-evolution): o da conta do funcionário
create or replace function interno.fn_evo_canal_tecnico(p_tecnico uuid)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_conta uuid := (select conta_id from tecnicos where id = p_tecnico); c conta_canais;
begin
  if v_conta is null then return null; end if;
  if v_conta = '00000000-0000-0000-0000-000000000001' then
    return jsonb_build_object('url', fn_config('evolution_url'), 'inst', fn_config('evolution_instancia'),
                              'chave', fn_segredo('EVOLUTION_API_KEY'));
  end if;
  select * into c from conta_canais where conta_id = v_conta and ativo;
  if not found then return null; end if;
  return jsonb_build_object('url', c.url, 'inst', c.instancia, 'chave', fn_segredo(c.segredo));
end $function$;

CREATE OR REPLACE FUNCTION interno.fn_segredo_gravar(p_nome text, p_valor text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  if p_nome not in ('WEBHOOK_TOKEN', 'WEBHOOK_TOKEN_ANTERIOR', 'ESPELHO_PDF_TOKEN', 'ALERTA_EMAIL_TOKEN')
     and p_nome !~ '^(EVOLUTION_API_KEY|WEBHOOK_TOKEN)_[0-9a-f]{32}$' then
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



-- entrada do WhatsApp com a conta da instância (o resto igual às definições da homologação)
CREATE OR REPLACE FUNCTION interno.fn_webhook_evolution(p_token text, p_payload jsonb)
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
  v_permitidas text[] := array['conversation', 'extendedTextMessage', 'buttonsResponseMessage', 'templateButtonReplyMessage',
                               'interactiveResponseMessage', 'listResponseMessage', 'messageContextInfo', 'localizacao',
                               'reactionMessage', 'protocolMessage'];
begin
  -- F5b: a instância diz a conta, e o token tem de ser o daquela instância; o resto da transação trabalha nela
  v_conta := fn_webhook_conta(p_token, p_payload->>'instance');
  perform set_config('trilha.conta', v_conta::text, true);

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
  insert into webhook_eventos (conta_id, evento, payload)
  values (v_conta, v_evento, v_pl)
  returning id into v_log;

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
        -- falha no ponto não pode derrubar a resposta das escalas
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
    update webhook_eventos set resultado = 'ERRO: ' || sqlerrm where id = v_log;
    v_res := jsonb_build_object('erro', sqlerrm);
  end;

  return v_res;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_wh_mensagem(p_data jsonb)
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
  v_esc    record;
  v_btn    text;
  v_texto  text;
  v_norm   text;
  v_ctx    text;
  v_acao   text;
  v_escala uuid;
  v_notif  uuid;
  v_oc     uuid;
  v_nome1  text;
  v_quando text;
  v_motivo text;
begin
  if coalesce((v_key->>'fromMe')::boolean, false) then
    return jsonb_build_object('ignorado', 'mensagem propria');
  end if;

  -- numero de quem respondeu (cobre enderecamento @lid das versoes novas)
  select j into v_jid
  from unnest(array[v_key->>'remoteJid', v_key->>'remoteJidAlt',
                    v_key->>'senderPn', p_data->>'sender']) as j
  where j like '%@s.whatsapp.net'
  limit 1;
  if v_jid is null then
    return jsonb_build_object('ignorado', 'sem telefone', 'jid', v_key->>'remoteJid');
  end if;

  select * into v_tec from tecnicos
  where fn_tel_canonico(telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1))
    and conta_id = coalesce(fn_conta_contexto(), conta_id);   -- F5b: só a conta da instância que recebeu
  if not found then
    return jsonb_build_object('ignorado', 'numero nao cadastrado');
  end if;
  v_nome1 := split_part(v_tec.nome, ' ', 1);

  -- clique em botao (formatos conhecidos da Evolution/Baileys)
  v_btn := coalesce(
    v_msg->'buttonsResponseMessage'->>'selectedButtonId',
    v_msg->'templateButtonReplyMessage'->>'selectedId'
  );
  if v_btn is null and v_msg ? 'interactiveResponseMessage' then
    begin
      v_btn := ((v_msg->'interactiveResponseMessage'->'nativeFlowResponseMessage'->>'paramsJson')::jsonb)->>'id';
    exception when others then
      v_btn := null;
    end;
  end if;

  v_texto := coalesce(
    v_msg->>'conversation',
    v_msg->'extendedTextMessage'->>'text',
    v_msg->'buttonsResponseMessage'->>'selectedDisplayText',
    v_msg->'templateButtonReplyMessage'->>'selectedDisplayText'
  );
  v_norm := lower(trim(coalesce(v_texto, '')));

  v_ctx := coalesce(
    p_data->'contextInfo'->>'stanzaId',
    v_msg->'extendedTextMessage'->'contextInfo'->>'stanzaId',
    v_msg->'buttonsResponseMessage'->'contextInfo'->>'stanzaId',
    v_msg->'interactiveResponseMessage'->'contextInfo'->>'stanzaId',
    v_msg->'templateButtonReplyMessage'->'contextInfo'->>'stanzaId'
  );

  -- motivo da recusa (backlog 064): numero de 1 a 4 logo depois de recusar, sem citar mensagem
  if v_btn is null and v_ctx is null and v_norm ~ '^[1-4][.! ]*$' then
    select o.id, o.escala_id into v_oc, v_escala
      from ocorrencias o join escalas e on e.id = o.escala_id
     where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.motivo is null
       and o.created_at > now() - interval '2 hours'
     order by o.created_at desc limit 1;
    if v_oc is not null and not exists
       (select 1 from escalas e where e.tecnico_id = v_tec.id and e.id <> v_escala
          and e.status in ('agendada', 'notificada')) then
      v_motivo := (array['transporte','conflito_agenda','falta_material','outro'])[left(v_norm, 1)::int];
      insert into respostas (escala_id, wa_message_id, wa_context_id, tipo, texto_livre)
      values (v_escala, v_wa_id, v_ctx, 'motivo', v_texto)
      on conflict (wa_message_id) do nothing;
      if not found then
        return jsonb_build_object('ignorado', 'evento duplicado');
      end if;
      update ocorrencias set motivo = v_motivo::ocorrencia_motivo where id = v_oc;
      select e.data_servico, e.hora_inicio into v_esc from escalas e where e.id = v_escala;
      perform fn_avisar_supervisores(
        '📝 *MOTIVO DA RECUSA*' || E'\n\n'
        || v_tec.nome || ' — programação de ' || to_char(v_esc.data_servico, 'DD/MM')
        || ' às ' || to_char(v_esc.hora_inicio, 'HH24:MI') || ': *' || fn_motivo_rotulo(v_motivo) || '*',
        v_tec.id);
      perform fn_wa_texto(v_tec.telefone_e164,
        'Obrigado, ' || v_nome1 || '. Motivo registrado: ' || fn_motivo_rotulo(v_motivo)
        || '. Se quiser, descreva o problema em uma mensagem.');
      return jsonb_build_object('acao', 'motivo_recusa', 'escala', v_escala, 'motivo', v_motivo);
    end if;
    v_oc := null; v_escala := null;
  end if;

  -- interpretar
  if v_btn like 'conf:%' then
    v_acao := 'confirmacao';
    begin v_escala := substr(v_btn, 6)::uuid; exception when others then v_escala := null; end;
  elsif v_btn like 'prob:%' then
    v_acao := 'problema';
    begin v_escala := substr(v_btn, 6)::uuid; exception when others then v_escala := null; end;
  elsif v_norm ~ '^(1|sim|ok|ciente|confirmado|confirmada|confirmo|ciente, confirmado)[.! ]*$' then
    v_acao := 'confirmacao';
  elsif v_norm ~ '^(2|problema|tenho um problema|nao|não)[.! ]*$' then
    v_acao := 'problema';
  else
    v_acao := 'texto_livre';
  end if;

  -- a escala do botao tem que ser do proprio tecnico
  if v_escala is not null and not exists
     (select 1 from escalas where id = v_escala and tecnico_id = v_tec.id) then
    v_escala := null;
  end if;

  -- escala pela mensagem respondida (resposta com citacao)
  if v_escala is null and v_ctx is not null then
    select n.escala_id, n.id into v_escala, v_notif
    from notificacoes n join escalas e on e.id = n.escala_id
    where n.wa_message_id = v_ctx and e.tecnico_id = v_tec.id;
  end if;

  -- texto livre: pode ser o detalhe de um problema informado ha pouco
  if v_acao = 'texto_livre' then
    select o.id, o.escala_id into v_oc, v_escala
    from ocorrencias o join escalas e on e.id = o.escala_id
    where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.detalhe is null
      and o.created_at > now() - interval '2 hours'
    order by o.created_at desc limit 1;

    if v_oc is not null then
      update ocorrencias set detalhe = v_texto, motivo = coalesce(motivo, 'outro') where id = v_oc;
      insert into respostas (escala_id, wa_message_id, wa_context_id, tipo, texto_livre)
      values (v_escala, v_wa_id, v_ctx, 'motivo', v_texto)
      on conflict (wa_message_id) do nothing;

      select e.data_servico, e.hora_inicio into v_esc from escalas e where e.id = v_escala;
      perform fn_avisar_supervisores(
        '📝 *DETALHE DO PROBLEMA*' || E'\n\n'
        || v_tec.nome || ' — programação de ' || to_char(v_esc.data_servico, 'DD/MM')
        || ' às ' || to_char(v_esc.hora_inicio, 'HH24:MI') || E'\n'
        || '"' || left(v_texto, 500) || '"',
        v_tec.id);
      perform fn_wa_texto(v_tec.telefone_e164, 'Obrigado, ' || v_nome1 || '. Repassei ao supervisor.');
      return jsonb_build_object('acao', 'detalhe_ocorrencia', 'escala', v_escala);
    end if;
  end if;

  -- sem citacao nem botao: escala pendente mais recente desse tecnico
  if v_escala is null then
    select e.id into v_escala
    from escalas e
    where e.tecnico_id = v_tec.id
      and e.status in ('agendada', 'notificada')
      and (e.data_servico + e.hora_inicio) > (now() at time zone fn_config('fuso')) - interval '12 hours'
    order by (select max(n.created_at) from notificacoes n where n.escala_id = e.id) desc nulls last
    limit 1;
  end if;

  if v_escala is null then
    return jsonb_build_object('ignorado', 'sem escala pendente', 'acao', v_acao);
  end if;

  if v_notif is null then
    select id into v_notif from notificacoes where escala_id = v_escala order by created_at desc limit 1;
  end if;

  -- registra a resposta (duplicata do webhook e descartada)
  insert into respostas (notificacao_id, escala_id, wa_message_id, wa_context_id, tipo, button_payload, texto_livre)
  values (v_notif, v_escala, v_wa_id, v_ctx, v_acao::resposta_tipo, v_btn, v_texto)
  on conflict (wa_message_id) do nothing;
  if not found then
    return jsonb_build_object('ignorado', 'evento duplicado');
  end if;

  -- quem respondeu, leu
  update notificacoes
     set status_envio = 'lida', entregue_em = coalesce(entregue_em, now()), lida_em = coalesce(lida_em, now())
   where escala_id = v_escala and status_envio in ('enviada', 'entregue');

  select e.*, coalesce(l.nome, 'local a confirmar') as local_nome into v_esc
  from escalas e left join locais l on l.id = e.local_id where e.id = v_escala;
  v_quando := to_char(v_esc.data_servico, 'DD/MM') || ' às ' || to_char(v_esc.hora_inicio, 'HH24:MI');

  if v_acao = 'texto_livre' then
    -- orienta uma unica vez por escala
    if (select count(*) from respostas where escala_id = v_escala and tipo = 'texto_livre') = 1 then
      perform fn_wa_texto(v_tec.telefone_e164,
        'Não entendi, ' || v_nome1 || '. Para a programação de ' || v_quando || ', responda *1* para confirmar ou *2* se tiver um problema.');
    end if;
    return jsonb_build_object('acao', 'texto_livre', 'escala', v_escala);
  end if;

  if v_esc.status not in ('agendada', 'notificada') then
    perform fn_wa_texto(v_tec.telefone_e164,
      'A programação de ' || v_quando || ' já estava registrada como *' || v_esc.status
      || '*. Para alterar, fale com o supervisor.');
    return jsonb_build_object('ignorado', 'escala ja respondida', 'status', v_esc.status);
  end if;

  perform set_config('app.ator', 'tecnico: ' || v_tec.nome, true);

  if v_acao = 'confirmacao' then
    update escalas set status = 'confirmada' where id = v_escala;
    perform fn_wa_texto(v_tec.telefone_e164,
      '✅ Confirmado, ' || v_nome1 || '! Programação de ' || v_quando || ' — ' || v_esc.local_nome || '.');
    return jsonb_build_object('acao', 'confirmada', 'escala', v_escala);
  end if;

  -- problema
  update escalas set status = 'recusada' where id = v_escala;
  insert into ocorrencias (escala_id) values (v_escala);
  -- a próxima resposta é o motivo da recusa: fecha a conversa do ponto que estivesse aberta (menu ou
  -- espera da localização), para o "1" do motivo não virar escolha do menu do ponto
  update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id and expira_em > now();
  if exists (select 1 from escalas e where e.tecnico_id = v_tec.id and e.id <> v_escala
               and e.status in ('agendada', 'notificada')) then
    -- outra escala aguardando resposta: pedir numero confundiria com o 1/2 dela
    perform fn_wa_texto(v_tec.telefone_e164,
      'Recebido, ' || v_nome1 || '. O supervisor já foi avisado. Se puder, descreva o problema em uma mensagem.');
  else
    perform fn_wa_texto(v_tec.telefone_e164,
      'Recebido, ' || v_nome1 || '. O supervisor já foi avisado.' || E'\n\n'
      || 'Qual o motivo? Responda com o número:' || E'\n'
      || '*1* - Transporte' || E'\n' || '*2* - Conflito de agenda' || E'\n'
      || '*3* - Falta de material' || E'\n' || '*4* - Outro');
  end if;
  perform fn_avisar_supervisores(
    '❌ *PROGRAMAÇÃO RECUSADA*' || E'\n\n'
    || v_tec.nome || ' informou um problema na programação de ' || v_quando || ' — ' || v_esc.local_nome || E'\n'
    || 'Telefone: ' || v_tec.telefone_e164,
    v_tec.id);
  return jsonb_build_object('acao', 'recusada', 'escala', v_escala);
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_wh(p_data jsonb)
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
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_he_resposta(p_data jsonb)
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
    perform fn_ponto_wa(v_sup.telefone_e164, 'Não foi possível registrar a decisão da hora extra: ' || sqlerrm);
    return jsonb_build_object('acao', 'he_erro');
  end;
  perform fn_ponto_wa(v_sup.telefone_e164, case r->>'situacao'
    when 'ja_decidida' then 'O pedido de hora extra nº ' || (r->>'numero') || ' já tinha sido decidido.'
    when 'aprovada' then '✅ Hora extra nº ' || (r->>'numero') || ' de ' || (r->>'nome') || ' aprovada. O funcionário foi avisado.'
    else '❌ Hora extra nº ' || (r->>'numero') || ' de ' || (r->>'nome') || ' não autorizada. O funcionário foi avisado.' end);
  return jsonb_build_object('acao', 'he_' || (r->>'situacao'), 'numero', r->'numero');
end $function$
;

-- motor e pedido de código do ponto dizem a conta antes de enviar (o resto igual às definições da homologação)
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
      -- F5b: a conta da escala decide o canal (o telefone é único só dentro da conta)
      perform set_config('trilha.conta', (select conta_id from escalas where id = a.escala_id)::text, true);
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
    perform set_config('trilha.conta', v_conta::text, true);
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

  perform set_config('trilha.conta', '', true);

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

CREATE OR REPLACE FUNCTION public.ponto_pedir_codigo(p_cpf text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_cpf  text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_ip   text := fn_ponto_ip();
  v_tec  record;
  v_cod  text;
  v_id   uuid := gen_random_uuid();
  v_resp jsonb := jsonb_build_object('ok', true, 'mensagem',
    'Se o CPF estiver cadastrado, você recebe o código no WhatsApp em instantes. Ele vale por 5 minutos.');
  v_aviso text;
begin
  insert into ponto_acessos (tipo, ip) values ('pedir_codigo', v_ip);
  if v_ip is not null and (select count(*) from ponto_acessos where ip = v_ip and tipo = 'pedir_codigo'
                            and momento > now() - interval '1 hour') > 10 then
    return v_resp;
  end if;
  if (select count(*) from ponto_codigos where origem = 'whatsapp' and created_at > now() - interval '1 hour')
       >= coalesce(fn_config_int('ponto_max_codigos_hora'), 60) then
    perform fn_ponto_alerta_teto('codigos');
    return v_resp;
  end if;
  if not fn_cpf_valido(v_cpf) then
    return jsonb_build_object('ok', false, 'mensagem', 'CPF inválido. Confira os 11 números.');
  end if;
  -- F6 (129): o mesmo CPF pode estar em mais de uma conta (funcionário de dois clientes); cada cadastro ativo com
  -- WhatsApp autorizado recebe o próprio código, com o nome da empresa na mensagem
  if not exists (select 1 from tecnicos where cpf = v_cpf and ativo) then
    v_aviso := 'CPF não encontrado. Confira os números ou fale com o seu gestor.';
  elsif not exists (select 1 from tecnicos where cpf = v_cpf and ativo and opt_in) then
    v_aviso := 'Seu WhatsApp ainda não foi autorizado para receber o código. Fale com o seu gestor.';
  end if;
  if v_aviso is not null then
    if fn_ponto_cpf_aviso_liberado(v_ip) then
      return jsonb_build_object('ok', false, 'mensagem', v_aviso);
    end if;
    return v_resp;
  end if;
  for v_tec in select t.id, t.telefone_e164, t.conta_id, coalesce(e.nome_fantasia, e.razao_social) as empresa
                 from tecnicos t left join empresas e on e.id = t.empresa_id
                where t.cpf = v_cpf and t.ativo and t.opt_in order by t.id loop
    perform pg_advisory_xact_lock(hashtextextended(v_tec.id::text, 0));
    continue when (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
                     and created_at > now() - interval '15 minutes') >= 3
               or (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
                     and created_at > now() - interval '1 day') >= 6;

    -- só vence os códigos de WhatsApp anteriores: o código do gestor continua valendo
    update ponto_codigos set expira_em = now()
     where tecnico_id = v_tec.id and origem = 'whatsapp' and usado_em is null and expira_em > now();
    v_id := gen_random_uuid();
    v_cod := fn_ponto_novo_codigo();
    insert into ponto_codigos (id, tecnico_id, codigo_hash, origem, expira_em)
    values (v_id, v_tec.id, fn_sha256(v_id::text || ':' || v_cod), 'whatsapp', now() + interval '5 minutes');

    begin
      -- F5b: cada cadastro recebe pelo canal da conta dele
      perform set_config('trilha.conta', v_tec.conta_id::text, true);
      perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', v_tec.telefone_e164,
          'text', 'Trilha Ponto' || coalesce(' (' || v_tec.empresa || ')', '') || ': seu código de acesso é ' || v_cod
                  || '. Vale por 5 minutos. Não compartilhe com ninguém.'));
    exception when others then
      -- sem Evolution (homologação) ou fora do ar: o gestor gera o código de contingência no painel
      raise warning 'ponto_pedir_codigo: envio do código falhou (%)', sqlerrm;
    end;
  end loop;
  return v_resp;
end $function$
;

-- canal da conta com o webhook próprio (a partir da 137)
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
  v_tok text;
  v_wseg text := 'WEBHOOK_TOKEN_' || replace(p_conta::text, '-', '');
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
  -- F5b: token próprio do webhook da instância (entrada pela conta) e o webhook apontado para o sistema
  v_tok := interno.fn_segredo(v_wseg);
  if v_tok is null then
    v_tok := encode(extensions.gen_random_bytes(32), 'hex');
    perform interno.fn_segredo_gravar(v_wseg, v_tok);
  end if;
  update interno.conta_canais set webhook_segredo = v_wseg where conta_id = p_conta;
  if coalesce(p_ativo, true) and coalesce(interno.fn_config('webhook_url'), '') <> '' then
    perform set_config('trilha.conta', p_conta::text, true);
    update interno.conta_canais set webhook_req = interno.fn_evo_post('/webhook/set/' || interno.fn_config('evolution_instancia'),
      jsonb_build_object('webhook', jsonb_build_object(
        'enabled', true, 'url', interno.fn_config('webhook_url'),
        'headers', jsonb_build_object('x-webhook-token', v_tok),
        'byEvents', false, 'base64', false,
        'events', jsonb_build_array('MESSAGES_UPSERT', 'MESSAGES_UPDATE'))))
     where conta_id = p_conta;
    perform set_config('trilha.conta', '', true);
  end if;
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'canal_whatsapp', p_conta, jsonb_build_object('instancia', v_inst, 'ativo', coalesce(p_ativo, true),
          'chave_trocada', v_chave <> '', 'instancia_antes', v_antes.instancia));
end $function$;


-- status de entrega só na conta da instância; e o vigia apaga a resposta do /webhook/set (revisão do seguranca)
CREATE OR REPLACE FUNCTION interno.fn_wh_status(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  it     jsonb;
  v_id   text;
  v_st   text;
  v_novo envio_status;
  v_n    int := 0;
begin
  for it in
    select value from jsonb_array_elements(
      case when jsonb_typeof(p_data) = 'array' then p_data else jsonb_build_array(p_data) end)
  loop
    v_id := coalesce(it->>'keyId', it->'key'->>'id', it->>'id');
    v_st := upper(coalesce(it->>'status', it->'update'->>'status', ''));
    v_novo := case
      when v_st in ('DELIVERY_ACK', 'DELIVERED', '3') then 'entregue'
      when v_st in ('READ', 'PLAYED', '4', '5')       then 'lida'
    end;
    continue when v_id is null or v_novo is null;

    update notificacoes set
      status_envio = case when status_envio = 'lida' then status_envio else v_novo end,
      entregue_em  = coalesce(entregue_em, now()),
      lida_em      = case when v_novo = 'lida' then coalesce(lida_em, now()) else lida_em end
    where wa_message_id = v_id
      and status_envio in ('enviada', 'entregue', 'lida')
      and conta_id = coalesce(fn_conta_contexto(), conta_id);   -- F5b: só a conta da instância que avisou

    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('status_atualizados', v_n);
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_vigiar_evolution()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v       evolution_vigia;
  v_resp  record;
  v_estado text;
  v_limite int := greatest(coalesce(fn_config_int('evolution_alerta_falhas'), 2), 1);
  v_inst  text := fn_config('evolution_instancia');
  v_fuso  text := coalesce(fn_config('fuso'), 'America/Bahia');
  v_manager text := rtrim(coalesce(fn_config('evolution_url'), ''), '/') || '/manager';
begin
  -- F5b: a resposta do /webhook/set das instâncias de cliente repete o token no cabeçalho; sai assim que chega
  with r as (delete from net._http_response h using conta_canais c where h.id = c.webhook_req returning h.id)
  update conta_canais set webhook_req = null where webhook_req in (select id from r);
  update conta_canais set webhook_req = null where webhook_req is not null and atualizado_em < now() - interval '1 day';
  if nullif(fn_config('evolution_url'), '') is null or nullif(v_inst, '') is null then
    return jsonb_build_object('situacao', 'sem evolution configurada');
  end if;
  insert into evolution_vigia (id) values (true) on conflict (id) do nothing;
  select * into v from evolution_vigia where id for update skip locked;
  if not found then return jsonb_build_object('situacao', 'outra volta em andamento'); end if;

  if v.req_id is not null then
    select r.status_code, r.content, r.timed_out, r.error_msg into v_resp from net._http_response r where r.id = v.req_id;
    if found then
      begin
        v_estado := case when v_resp.status_code = 200 then left(coalesce(
                      (v_resp.content::jsonb #>> '{instance,state}'), (v_resp.content::jsonb ->> 'state'), 'desconhecido'), 30)
                    else 'sem_resposta' end;
      exception when others then
        v_estado := 'sem_resposta';   -- resposta que não é JSON
      end;
    elsif v.verificado_em < now() - interval '4 minutes' then
      v_estado := 'sem_resposta';   -- o pg_net já descartou a resposta ou nunca respondeu
    end if;
  end if;

  if v_estado is not null then
    if v_estado = 'open' then
      if v.alertado_em is not null then
        perform fn_alerta_email('Trilha: WhatsApp de volta',
          'O WhatsApp do Trilha (instância ' || v_inst || ') voltou a funcionar às '
          || to_char(now() at time zone v_fuso, 'DD/MM HH24:MI') || '.' || E'\n'
          || 'Ficou fora desde ' || to_char(v.fora_desde at time zone v_fuso, 'DD/MM HH24:MI') || '. '
          || 'Confira no painel as programações e os avisos desse período.');
      end if;
      update evolution_vigia set estado = v_estado, falhas = 0, fora_desde = null, alertado_em = null where id;
    else
      update evolution_vigia set estado = v_estado, falhas = falhas + 1, fora_desde = coalesce(fora_desde, now()) where id
        returning * into v;
      if v.falhas >= v_limite and v.alertado_em is null then
        perform fn_alerta_email('Trilha: WhatsApp fora do ar',
          'O WhatsApp do Trilha (instância ' || v_inst || ') está fora do ar desde '
          || to_char(v.fora_desde at time zone v_fuso, 'DD/MM HH24:MI') || ' (estado: ' || v_estado || ').' || E'\n\n'
          || 'Enquanto isso, programações, confirmações e avisos pelo WhatsApp não saem.' || E'\n\n'
          || 'Como resolver: abra ' || v_manager || ', entre na instância ' || v_inst
          || ' e leia o QR code com o WhatsApp do celular da operação. Se a página não abrir, o servidor da Evolution '
          || 'está fora: acione o suporte.' || E'\n\n'
          || 'Quando voltar, você recebe outro e-mail.');
        update evolution_vigia set alertado_em = now() where id;
      end if;
    end if;
  end if;

  begin
    update evolution_vigia set req_id = fn_evo_get('/instance/connectionState/' || v_inst), verificado_em = now() where id;
  exception when others then
    -- sem a chave da Evolution no Vault (ou o pg_net fora): aparece no quadro da plataforma, em vez de só um aviso no log
    update evolution_vigia set req_id = null, estado = 'erro_interno', verificado_em = now() where id;
  end;
  return jsonb_build_object('estado', coalesce(v_estado, v.estado), 'falhas', (select falhas from evolution_vigia where id));
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
