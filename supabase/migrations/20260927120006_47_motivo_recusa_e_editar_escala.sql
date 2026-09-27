-- 47 | Backlog 064 (motivo de recusa estruturado) e 065 (editar e reagendar escala)
--
-- 064: depois do "2", o WhatsApp pergunta o motivo (1 Saúde, 2 Transporte, 3 Conflito de agenda,
--      4 Falta de material, 5 Outro), gravado em ocorrencias.motivo. Só pergunta quando o técnico
--      não tem outra escala aguardando resposta, para o número não ser confundido com 1/2 de outra
--      escala. Texto livre continua indo para o detalhe (motivo "outro" se ainda vazio).
--      app_indicadores_resposta: recusas por motivo e mediana do tempo de resposta.
-- 065: app_editar_escala (data, hora, local, tarefa). Mudou data, hora ou local de escala já
--      enviada: volta a aguardar resposta e o técnico recebe a escala de novo. Mudou só a tarefa:
--      o técnico é avisado, sem nova confirmação (decisão do responsável, 27/09).
--      app_substituir_tecnico: escala recusada gera outra, igual, para o técnico escolhido.
-- fn_wh_mensagem parte da definição atual da homologação.

create or replace function fn_motivo_rotulo(p text)
returns text language sql immutable
set search_path = public, extensions as $$
  select case p
    when 'saude' then 'Saúde' when 'transporte' then 'Transporte'
    when 'conflito_agenda' then 'Conflito de agenda' when 'falta_material' then 'Falta de material'
    when 'outro' then 'Outro' else 'Não informado' end
$$;

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

  -- motivo da recusa (backlog 064): numero de 1 a 5 logo depois de recusar, sem citar mensagem
  if v_btn is null and v_ctx is null and v_norm ~ '^[1-5][.! ]*$' then
    select o.id, o.escala_id into v_oc, v_escala
      from ocorrencias o join escalas e on e.id = o.escala_id
     where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.motivo is null
       and o.created_at > now() - interval '2 hours'
     order by o.created_at desc limit 1;
    if v_oc is not null and not exists
       (select 1 from escalas e where e.tecnico_id = v_tec.id and e.id <> v_escala
          and e.status in ('agendada', 'notificada')) then
      v_motivo := (array['saude','transporte','conflito_agenda','falta_material','outro'])[left(v_norm, 1)::int];
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
        || v_tec.nome || ' — escala de ' || to_char(v_esc.data_servico, 'DD/MM')
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
  if exists (select 1 from escalas e where e.tecnico_id = v_tec.id and e.id <> v_escala
               and e.status in ('agendada', 'notificada')) then
    -- outra escala aguardando resposta: pedir numero confundiria com o 1/2 dela
    perform fn_wa_texto(v_tec.telefone_e164,
      'Recebido, ' || v_nome1 || '. O supervisor já foi avisado. Se puder, descreva o problema em uma mensagem.');
  else
    perform fn_wa_texto(v_tec.telefone_e164,
      'Recebido, ' || v_nome1 || '. O supervisor já foi avisado.' || E'\n\n'
      || 'Qual o motivo? Responda com o número:' || E'\n'
      || '*1* - Saúde' || E'\n' || '*2* - Transporte' || E'\n' || '*3* - Conflito de agenda' || E'\n'
      || '*4* - Falta de material' || E'\n' || '*5* - Outro');
  end if;
  perform fn_avisar_supervisores(
    '❌ *ESCALA RECUSADA*' || E'\n\n'
    || v_tec.nome || ' informou um problema na escala de ' || v_quando || ' — ' || v_esc.local_nome || E'\n'
    || 'Telefone: ' || v_tec.telefone_e164,
    v_tec.id);
  return jsonb_build_object('acao', 'recusada', 'escala', v_escala);
end $function$;

-- 064: indicadores para a aba Operação
create or replace function app_indicadores_resposta(p_dias int default 30)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
declare
  v_desde date := (now() at time zone fn_config('fuso'))::date - greatest(coalesce(p_dias, 30), 1);
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return jsonb_build_object(
    'dias', greatest(coalesce(p_dias, 30), 1),
    'recusas', coalesce((
      select jsonb_agg(jsonb_build_object('motivo', m, 'rotulo', fn_motivo_rotulo(m), 'total', n) order by n desc)
      from (select coalesce(o.motivo::text, 'nao_informado') m, count(*) n
              from escalas e
              left join lateral (select motivo from ocorrencias where escala_id = e.id
                                  order by created_at desc limit 1) o on true
             where e.status = 'recusada' and not e.teste and e.data_servico >= v_desde
             group by 1) x), '[]'::jsonb),
    'respostas', (select count(*) from escalas e
                   where e.confirmada_em is not null and not e.teste and e.data_servico >= v_desde),
    'mediana_resposta_min', (
      select round((percentile_cont(0.5) within group (order by extract(epoch from e.confirmada_em - n.primeira) / 60))::numeric, 0)
        from escalas e
        join lateral (select min(enviada_em) primeira from notificacoes
                       where escala_id = e.id and enviada_em is not null) n on n.primeira is not null
       where e.confirmada_em is not null and not e.teste and e.data_servico >= v_desde
         and e.confirmada_em >= n.primeira));
end $$;

-- 065: dados atuais para o formulário de edição
create or replace function app_escala_edicao(p_escala uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor']);
  return (select jsonb_build_object('id', id, 'tecnico_id', tecnico_id, 'data_servico', data_servico,
            'hora_inicio', to_char(hora_inicio, 'HH24:MI'), 'local_id', local_id,
            'descricao_tarefa', descricao_tarefa, 'status', status)
          from escalas where id = p_escala);
end $$;

create or replace function app_editar_escala(p jsonb)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  e         escalas;
  v_data    date;
  v_hora    time;
  v_local   uuid;
  v_tarefa  text;
  v_mudou   boolean;
  v_reconf  boolean;
  v_tec     record;
  v_tent    int;
  v_botoes  boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_payload jsonb;
  v_req     bigint;
begin
  select * into e from escalas where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Escala não encontrada.'; end if;
  if e.status not in ('rascunho', 'agendada', 'notificada', 'confirmada') then
    raise exception 'Só dá para editar escala em rascunho, agendada, aguardando resposta ou confirmada.';
  end if;

  v_data   := coalesce(nullif(p->>'data_servico', '')::date, e.data_servico);
  v_hora   := coalesce(nullif(p->>'hora_inicio', '')::time, e.hora_inicio);
  v_local  := case when p ? 'local_id' then nullif(p->>'local_id', '')::uuid else e.local_id end;
  v_tarefa := coalesce(nullif(trim(p->>'descricao_tarefa'), ''), e.descricao_tarefa);
  v_mudou  := v_data <> e.data_servico or v_hora <> e.hora_inicio or v_local is distinct from e.local_id;

  if not v_mudou and v_tarefa = e.descricao_tarefa then
    return jsonb_build_object('alterada', false);
  end if;
  if v_data <> e.data_servico or v_hora <> e.hora_inicio then
    perform fn_validar_inicio(v_data, v_hora);
  end if;

  -- decisao do responsavel (27/09): so data, hora ou local pedem nova confirmacao
  v_reconf := v_mudou and e.status in ('notificada', 'confirmada');
  perform set_config('app.ator', v_email, true);
  begin
    update escalas
       set data_servico = v_data, hora_inicio = v_hora, local_id = v_local, descricao_tarefa = v_tarefa,
           status = case when v_reconf then 'notificada'::escala_status else status end,
           confirmada_em = case when v_reconf then null else confirmada_em end,
           supervisor_avisado_em = case when v_mudou then null else supervisor_avisado_em end
     where id = e.id;
  exception when unique_violation then
    raise exception 'O técnico já tem outra escala ativa nesse dia e horário.';
  end;

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (e.id, 'escala_editada', v_email, jsonb_build_object(
    'antes', jsonb_build_object('data', e.data_servico, 'hora', e.hora_inicio, 'local_id', e.local_id, 'tarefa', e.descricao_tarefa),
    'depois', jsonb_build_object('data', v_data, 'hora', v_hora, 'local_id', v_local, 'tarefa', v_tarefa),
    'nova_confirmacao', v_reconf));

  -- aviso ao tecnico quando a escala ja tinha saido
  if e.status in ('notificada', 'confirmada') then
    select telefone_e164, ativo, opt_in into v_tec from tecnicos where id = e.tecnico_id;
    if v_tec.ativo and v_tec.opt_in then
      if v_reconf then
        perform fn_wa_texto(v_tec.telefone_e164,
          '⚠️ *ESCALA ALTERADA*' || E'\n\n' || 'Sua escala mudou. Confira os novos dados na mensagem a seguir e responda de novo.');
        select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = e.id;
        v_payload := fn_payload_escala(e.id, v_tec.telefone_e164, false, v_botoes);
        v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
        values (e.id, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo, v_tent,
                case when v_botoes then 'botoes_evolution' else 'texto_evolution' end, 'enfileirada', v_payload, now(), v_req);
      else
        perform fn_wa_texto(v_tec.telefone_e164,
          '📝 A tarefa da sua escala de ' || to_char(v_data, 'DD/MM') || ' às ' || to_char(v_hora, 'HH24:MI')
          || ' foi atualizada: ' || left(v_tarefa, 500));
      end if;
    end if;
  end if;

  return jsonb_build_object('alterada', true, 'nova_confirmacao', v_reconf);
end $$;

create or replace function app_substituir_tecnico(p_escala uuid, p_tecnico uuid)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  e       escalas;
  v_novo  uuid;
begin
  select * into e from escalas where id = p_escala;
  if not found then raise exception 'Escala não encontrada.'; end if;
  if e.status <> 'recusada' then raise exception 'Só dá para substituir o técnico de uma escala recusada.'; end if;
  if p_tecnico = e.tecnico_id then raise exception 'Escolha outro técnico.'; end if;
  begin
    v_novo := fn_criar_escala(v_email, p_tecnico::text, coalesce(e.local_id::text, ''), e.data_servico::text,
                              e.hora_inicio::text, e.descricao_tarefa, e.duracao_prevista_min::text, e.prioridade, 'true');
  exception when unique_violation then
    raise exception 'Esse técnico já tem escala nesse dia e horário.';
  end;
  update escalas set tipo_atividade_id = e.tipo_atividade_id where id = v_novo;
  insert into escala_eventos (escala_id, evento, ator, detalhe) values
    (e.id, 'substituida', v_email, jsonb_build_object('nova_escala', v_novo, 'tecnico_id', p_tecnico)),
    (v_novo, 'substitui', v_email, jsonb_build_object('escala_anterior', e.id));
  return jsonb_build_object('escala', v_novo);
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
