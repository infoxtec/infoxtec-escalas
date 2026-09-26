-- 41 | Habilidades, motor tolerante a falha e fuso no webhook
--
-- 1. app_salvar_habilidade e app_definir_habilidades ainda gravavam habilidades.exige_validade,
--    coluna removida na migration 36. Cadastrar ou editar habilidade e marcar as habilidades de um
--    tecnico falhavam com "column exige_validade does not exist" (producao e repositorio).
--    Habilidade nao vence (decisao 21): a validade passa a ser sempre nula.
-- 2. fn_dispatcher_whatsapp: um erro numa escala derrubava a execucao inteira, e como o pg_net
--    tambem e transacional, nenhuma mensagem saia ate alguem corrigir o dado. Agora cada item
--    das fases 1 a 3 e tratado isoladamente; na fase 2 a falha fica registrada na notificacao
--    (erro_codigo 'interno'), o motor tenta de novo e, esgotadas as tentativas, avisa o supervisor.
--    Partindo da versao de producao sincronizada na migration 40 (fases 1 a 6).
-- 3. fn_wh_mensagem: a resposta solta ("1", "ok") procurava escalas iniciadas ha ate 12 horas,
--    mas comparava hora local com UTC (na pratica, 9 horas). Mesma correcao da migration 39.

create or replace function app_salvar_habilidade(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_id uuid := nullif(p->>'id','')::uuid;
begin
  perform app_exigir(array['admin','gestor']);
  if coalesce(trim(p->>'nome'),'') = '' then raise exception 'Nome da habilidade é obrigatório.'; end if;
  if v_id is null then
    insert into habilidades (nome, categoria, descricao, ativo)
    values (trim(p->>'nome'), coalesce(nullif(p->>'categoria',''),'tecnica'),
            nullif(trim(p->>'descricao'),''), coalesce((p->>'ativo')::boolean,true))
    returning id into v_id;
  else
    update habilidades set nome = trim(p->>'nome'),
      categoria = coalesce(nullif(p->>'categoria',''),'tecnica'),
      descricao = nullif(trim(p->>'descricao'),''),
      ativo = coalesce((p->>'ativo')::boolean,true)
    where id = v_id;
    if not found then raise exception 'Habilidade não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe uma habilidade com esse nome.';
end $$;

create or replace function app_definir_habilidades(p_tecnico uuid, p_habilidades jsonb)
returns integer language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  h     jsonb;
  v_ids uuid[] := '{}';
begin
  perform app_exigir(array['admin','gestor']);
  if not exists (select 1 from tecnicos where id = p_tecnico) then
    raise exception 'Técnico não encontrado.';
  end if;

  for h in select * from jsonb_array_elements(coalesce(p_habilidades, '[]'::jsonb)) loop
    if not exists (select 1 from habilidades where id = (h->>'habilidade_id')::uuid) then
      raise exception 'Habilidade não encontrada.';
    end if;
    v_ids := v_ids || (h->>'habilidade_id')::uuid;
    insert into tecnico_habilidades (tecnico_id, habilidade_id, nivel, validade, observacao)
    values (p_tecnico, (h->>'habilidade_id')::uuid,
            coalesce(nullif(h->>'nivel',''), 'basico'), null, nullif(trim(h->>'observacao'), ''))
    on conflict (tecnico_id, habilidade_id) do update
      set nivel = excluded.nivel, validade = null,
          observacao = excluded.observacao, atualizado_em = now();
  end loop;

  delete from tecnico_habilidades
  where tecnico_id = p_tecnico and not (habilidade_id = any (v_ids));

  return coalesce(array_length(v_ids, 1), 0);
end $$;

CREATE OR REPLACE FUNCTION public.fn_dispatcher_whatsapp()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  n record; r_resp record; a record; s record;
  v_wa_id text; v_req bigint; v_tent int; v_texto text; v_payload jsonb; v_botoes boolean;
  v_sent int := 0;
  v_limite int := coalesce(fn_config_int('envios_por_execucao'), 3);
  v_webhook boolean := coalesce(fn_config('webhook_ativo'), 'false')::boolean;
  v_usar_botoes boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_inst text := fn_config('evolution_instancia');
begin
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

  -- FASE 3: supervisores
  for a in select * from vw_acoes_pendentes
           where acao = 'escalonar' or (v_webhook and avisar_supervisor) loop
    if exists (select 1 from escalas where id = a.escala_id and supervisor_avisado_em is not null) then continue; end if;
   begin
    v_texto := fn_msg_supervisor(a.escala_id, a.diagnostico, a.tentativa);
    for s in select telefone_e164 from tecnicos where is_supervisor and ativo loop
      perform fn_evo_post('/message/sendText/' || v_inst,
                          jsonb_build_object('number', s.telefone_e164, 'text', v_texto));
    end loop;
    update escalas set supervisor_avisado_em = now() where id = a.escala_id;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (a.escala_id, 'supervisor_acionado', 'dispatcher',
            jsonb_build_object('diagnostico', a.diagnostico, 'tentativa', a.tentativa));
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
end $function$;

CREATE OR REPLACE FUNCTION public.fn_wh_mensagem(p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
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
  where fn_tel_canonico(telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1));
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

  -- problema
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
end $function$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
