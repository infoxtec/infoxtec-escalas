-- 12 | Fecha a API publica + webhook da Evolution (status de entrega/leitura e respostas)

-- SEGURANCA: nada do schema public fica acessivel pela API publica do Supabase.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
revoke all on vw_escalas_painel, vw_acoes_pendentes, vw_resumo_dia, vw_linha_do_tempo
  from anon, authenticated;

-- Log bruto dos eventos. A apikey da Evolution e removida antes de gravar.
create table if not exists webhook_eventos (
  id          bigserial primary key,
  recebido_em timestamptz not null default now(),
  evento      text,
  payload     jsonb,
  resultado   text
);
alter table webhook_eventos enable row level security;
create index if not exists idx_webhook_eventos_data on webhook_eventos (recebido_em desc);

-- Celular BR sem o 9 (557181776307) vira com 9 (5571981776307)
create or replace function fn_tel_canonico(p text)
returns text language sql immutable as $$
  select case
    when d ~ '^55[1-9][0-9][6-9][0-9]{7}$' then substr(d, 1, 4) || '9' || substr(d, 5)
    else d
  end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
$$;

create or replace function fn_wa_texto(p_telefone text, p_texto text)
returns bigint language sql volatile as $$
  select fn_evo_post(
    '/message/sendText/' || fn_config('evolution_instancia'),
    jsonb_build_object('number', p_telefone, 'text', p_texto)
  )
$$;

create or replace function fn_avisar_supervisores(p_texto text, p_exceto uuid default null)
returns int language plpgsql volatile as $$
declare
  s record;
  v_n int := 0;
begin
  for s in
    select telefone_e164 from tecnicos
    where is_supervisor and ativo and id is distinct from p_exceto
  loop
    perform fn_wa_texto(s.telefone_e164, p_texto);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- messages.update: entregue / lida (nunca rebaixa o status)
create or replace function fn_wh_status(p_data jsonb)
returns jsonb language plpgsql volatile as $$
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
      and status_envio in ('enviada', 'entregue', 'lida');

    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('status_atualizados', v_n);
end $$;

-- messages.upsert: botao, "1"/"2", texto livre, detalhe de problema
create or replace function fn_wh_mensagem(p_data jsonb)
returns jsonb language plpgsql volatile as $$
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
begin
  if coalesce((v_key->>'fromMe')::boolean, false) then
    return jsonb_build_object('ignorado', 'mensagem propria');
  end if;

  select j into v_jid
  from unnest(array[v_key->>'remoteJid', v_key->>'remoteJidAlt',
                    v_key->>'senderPn', p_data->>'sender']) as j
  where j like '%@s.whatsapp.net'
  limit 1;
  if v_jid is null then
    return jsonb_build_object('ignorado', 'sem telefone', 'jid', v_key->>'remoteJid');
  end if;

  select * into v_tec from tecnicos
  where fn_tel_canonico(telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1));
  if not found then
    return jsonb_build_object('ignorado', 'numero nao cadastrado');
  end if;
  v_nome1 := split_part(v_tec.nome, ' ', 1);

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

  if v_escala is not null and not exists
     (select 1 from escalas where id = v_escala and tecnico_id = v_tec.id) then
    v_escala := null;
  end if;

  if v_escala is null and v_ctx is not null then
    select n.escala_id, n.id into v_escala, v_notif
    from notificacoes n join escalas e on e.id = n.escala_id
    where n.wa_message_id = v_ctx and e.tecnico_id = v_tec.id;
  end if;

  if v_acao = 'texto_livre' then
    select o.id, o.escala_id into v_oc, v_escala
    from ocorrencias o join escalas e on e.id = o.escala_id
    where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.detalhe is null
      and o.created_at > now() - interval '2 hours'
    order by o.created_at desc limit 1;

    if v_oc is not null then
      update ocorrencias set detalhe = v_texto where id = v_oc;
      insert into respostas (escala_id, wa_message_id, wa_context_id, tipo, texto_livre)
      values (v_escala, v_wa_id, v_ctx, 'motivo', v_texto)
      on conflict (wa_message_id) do nothing;

      select e.data_servico, e.hora_inicio into v_esc from escalas e where e.id = v_escala;
      perform fn_avisar_supervisores(
        '📝 *DETALHE DO PROBLEMA*' || E'\n\n'
        || v_tec.nome || ' — escala de ' || to_char(v_esc.data_servico, 'DD/MM')
        || ' às ' || to_char(v_esc.hora_inicio, 'HH24:MI') || E'\n'
        || '"' || left(v_texto, 500) || '"',
        v_tec.id);
      perform fn_wa_texto(v_tec.telefone_e164, 'Obrigado, ' || v_nome1 || '. Repassei ao supervisor.');
      return jsonb_build_object('acao', 'detalhe_ocorrencia', 'escala', v_escala);
    end if;
  end if;

  if v_escala is null then
    select e.id into v_escala
    from escalas e
    where e.tecnico_id = v_tec.id
      and e.status in ('agendada', 'notificada')
      and (e.data_servico + e.hora_inicio) > now() - interval '12 hours'
    order by (select max(n.created_at) from notificacoes n where n.escala_id = e.id) desc nulls last
    limit 1;
  end if;

  if v_escala is null then
    return jsonb_build_object('ignorado', 'sem escala pendente', 'acao', v_acao);
  end if;

  if v_notif is null then
    select id into v_notif from notificacoes where escala_id = v_escala order by created_at desc limit 1;
  end if;

  insert into respostas (notificacao_id, escala_id, wa_message_id, wa_context_id, tipo, button_payload, texto_livre)
  values (v_notif, v_escala, v_wa_id, v_ctx, v_acao::resposta_tipo, v_btn, v_texto)
  on conflict (wa_message_id) do nothing;
  if not found then
    return jsonb_build_object('ignorado', 'evento duplicado');
  end if;

  update notificacoes
     set status_envio = 'lida', entregue_em = coalesce(entregue_em, now()), lida_em = coalesce(lida_em, now())
   where escala_id = v_escala and status_envio in ('enviada', 'entregue');

  select e.*, coalesce(l.nome, 'local a confirmar') as local_nome into v_esc
  from escalas e left join locais l on l.id = e.local_id where e.id = v_escala;
  v_quando := to_char(v_esc.data_servico, 'DD/MM') || ' às ' || to_char(v_esc.hora_inicio, 'HH24:MI');

  if v_acao = 'texto_livre' then
    if (select count(*) from respostas where escala_id = v_escala and tipo = 'texto_livre') = 1 then
      perform fn_wa_texto(v_tec.telefone_e164,
        'Não entendi, ' || v_nome1 || '. Para a escala de ' || v_quando || ', responda *1* para confirmar ou *2* se tiver um problema.');
    end if;
    return jsonb_build_object('acao', 'texto_livre', 'escala', v_escala);
  end if;

  if v_esc.status not in ('agendada', 'notificada') then
    perform fn_wa_texto(v_tec.telefone_e164,
      'A escala de ' || v_quando || ' já estava registrada como *' || v_esc.status
      || '*. Para alterar, fale com o supervisor.');
    return jsonb_build_object('ignorado', 'escala ja respondida', 'status', v_esc.status);
  end if;

  perform set_config('app.ator', 'tecnico: ' || v_tec.nome, true);

  if v_acao = 'confirmacao' then
    update escalas set status = 'confirmada' where id = v_escala;
    perform fn_wa_texto(v_tec.telefone_e164,
      '✅ Confirmado, ' || v_nome1 || '! Escala de ' || v_quando || ' — ' || v_esc.local_nome || '.');
    return jsonb_build_object('acao', 'confirmada', 'escala', v_escala);
  end if;

  update escalas set status = 'recusada' where id = v_escala;
  insert into ocorrencias (escala_id) values (v_escala);
  perform fn_wa_texto(v_tec.telefone_e164,
    'Recebido, ' || v_nome1 || '. O supervisor já foi avisado. Se puder, descreva o problema em uma mensagem.');
  perform fn_avisar_supervisores(
    '❌ *ESCALA RECUSADA*' || E'\n\n'
    || v_tec.nome || ' informou um problema na escala de ' || v_quando || ' — ' || v_esc.local_nome || E'\n'
    || 'Telefone: ' || v_tec.telefone_e164,
    v_tec.id);
  return jsonb_build_object('acao', 'recusada', 'escala', v_escala);
end $$;

-- Porta de entrada: chamada pela Edge Function webhook-evolution com o token da URL
create or replace function fn_webhook_evolution(p_token text, p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_log    bigint;
  v_evento text := lower(replace(coalesce(p_payload->>'event', ''), '_', '.'));
  v_res    jsonb;
begin
  if p_token is null or p_token = '' or p_token is distinct from fn_segredo('WEBHOOK_TOKEN') then
    raise exception 'token invalido';
  end if;

  insert into webhook_eventos (evento, payload)
  values (v_evento, p_payload - 'apikey')
  returning id into v_log;

  begin
    if v_evento = 'messages.update' then
      v_res := fn_wh_status(p_payload->'data');
    elsif v_evento = 'messages.upsert' then
      v_res := fn_wh_mensagem(p_payload->'data');
    else
      v_res := jsonb_build_object('ignorado', v_evento);
    end if;
    update webhook_eventos set resultado = v_res::text where id = v_log;
  exception when others then
    update webhook_eventos set resultado = 'ERRO: ' || sqlerrm where id = v_log;
    v_res := jsonb_build_object('erro', sqlerrm);
  end;

  return v_res;
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
