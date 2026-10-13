-- Migration 93 (13/10/2026): "Escala" (a ordem de serviço enviada ao técnico) passa a se chamar "Programação"
-- (pedido do responsável, decisão 87). Só textos: mensagens do WhatsApp e da URA ao técnico, avisos ao supervisor
-- e mensagens de erro do painel. Nenhuma regra, tabela ou nome interno muda (tabela escalas, escala_id etc.
-- continuam). Cada função foi recriada a partir da definição atual, idêntica à da homologação (MD5 do corpo
-- conferido em 13/10), trocando só o texto entre aspas. "Escala" passa a ser a carga horária do funcionário
-- (Pedido 2, em análise).

create or replace function fn_mudar_status(p_ator text, p_escala_id text, p_status text)
returns text
language plpgsql volatile
set search_path = public, extensions as $$
begin
  perform fn_exigir_papel(p_ator, array['admin', 'gestor']);
  perform set_config('app.ator', coalesce(nullif(p_ator, ''), 'painel'), false);
  update escalas set status = p_status::escala_status where id = p_escala_id::uuid;
  if not found then
    raise exception 'Programação % nao encontrada', p_escala_id;
  end if;
  return p_status;
exception when unique_violation then
  raise exception 'Já existe outra programação ativa para este técnico no mesmo dia e horário.';
end $$;

create or replace function fn_excluir_tecnico(p_ator text, p_tecnico_id text)
returns jsonb
language plpgsql volatile
set search_path = public, extensions as $$
declare
  v_id      uuid := p_tecnico_id::uuid;
  v_ator    text := coalesce(nullif(p_ator, ''), 'painel');
  v_sup     boolean;
  v_outros  int;
  v_abertas int;
  v_total   int;
  v_hoje    date := (now() at time zone fn_config('fuso'))::date;
begin
  perform fn_exigir_papel(p_ator, array['admin']);
  perform set_config('app.ator', v_ator, false);

  select is_supervisor into v_sup from tecnicos where id = v_id;
  if not found then
    raise exception 'Técnico não encontrado.';
  end if;

  if v_sup then
    select count(*) into v_outros from tecnicos where is_supervisor and ativo and id <> v_id;
    if v_outros = 0 then
      raise exception 'Não é possível excluir o único supervisor ativo. Cadastre outro supervisor antes.';
    end if;
  end if;

  select count(*) into v_abertas
  from escalas
  where tecnico_id = v_id and data_servico >= v_hoje
    and status in ('agendada', 'notificada', 'confirmada', 'reagendada', 'em_execucao');
  if v_abertas > 0 then
    raise exception 'Este técnico tem % programação(ões) em aberto a partir de hoje. Cancele ou conclua antes de excluir.', v_abertas;
  end if;

  select count(*) into v_total from escalas where tecnico_id = v_id;
  delete from escalas  where tecnico_id = v_id;
  delete from tecnicos where id = v_id;

  insert into log_exclusoes (entidade, entidade_id, ator, escalas_removidas)
  values ('tecnico', v_id, v_ator, v_total);

  return jsonb_build_object('excluido', true, 'escalas_removidas', v_total);
end $$;

create or replace function fn_msg_supervisor(p_escala_id uuid, p_diagnostico text, p_tentativa int)
returns text language plpgsql stable as $$
declare
  r record;
begin
  select e.data_servico, e.hora_inicio, t.nome as tecnico, t.telefone_e164,
         coalesce(l.nome, 'local a confirmar') as local_nome
    into r
  from escalas e
  join tecnicos t on t.id = e.tecnico_id
  left join locais l on l.id = e.local_id
  where e.id = p_escala_id;

  return '⚠️ *PROGRAMAÇÃO SEM CONFIRMAÇÃO*' || E'\n\n'
    || 'Ligar para: ' || r.tecnico || ' — ' || r.telefone_e164 || E'\n'
    || 'Programação: ' || to_char(r.data_servico, 'DD/MM') || ' às ' || to_char(r.hora_inicio, 'HH24:MI')
    || ' — ' || r.local_nome || E'\n'
    || 'Situação: ' || coalesce(p_diagnostico, 'sem resposta') || E'\n'
    || 'Tentativas: ' || coalesce(p_tentativa, 0);
end $$;

create or replace function fn_titulo_escala(p_escala_id uuid)
returns text language plpgsql stable as $$
declare
  v_data date;
  v_dias text[] := array['domingo','segunda-feira','terça-feira','quarta-feira',
                         'quinta-feira','sexta-feira','sábado'];
begin
  select data_servico into v_data from escalas where id = p_escala_id;
  return 'PROGRAMAÇÃO — ' || to_char(v_data, 'DD/MM') || ', ' || v_dias[extract(dow from v_data)::int + 1];
end $$;

create or replace function fn_payload_escala(p_escala_id uuid, p_telefone text, p_lembrete boolean, p_botoes boolean)
returns jsonb language plpgsql stable set search_path = public, extensions as $$
declare
  v_inst text := fn_config('evolution_instancia');
begin
  if exists (select 1 from escalas where id = p_escala_id and local_id is null) then
    raise exception 'Programação sem local não é enviada. Escolha o local e reenvie.';
  end if;

  if p_botoes then
    return jsonb_build_object(
      'path', '/message/sendButtons/' || v_inst,
      'body', jsonb_build_object(
        'number', p_telefone,
        'title', case when p_lembrete then 'LEMBRETE — ' else '' end || fn_titulo_escala(p_escala_id),
        'description', fn_corpo_escala(p_escala_id) || E'\n\n'
                       || 'Confirme pelos botões abaixo ou responda *1* (confirmado) ou *2* (problema).',
        'footer', 'Infoxtec Programação',
        'buttons', jsonb_build_array(
          jsonb_build_object('type', 'reply', 'displayText', 'Ciente, confirmado',
                             'id', 'conf:' || p_escala_id::text),
          jsonb_build_object('type', 'reply', 'displayText', 'Tenho um problema',
                             'id', 'prob:' || p_escala_id::text)
        )
      )
    );
  end if;

  return jsonb_build_object(
    'path', '/message/sendText/' || v_inst,
    'body', jsonb_build_object(
      'number', p_telefone,
      'text', fn_msg_escala(p_escala_id, p_lembrete),
      'delay', 1500
    )
  );
end $$;

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
end $function$;

create or replace function fn_remover_escala(p_ator text, p_escala_id text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_id uuid := p_escala_id::uuid; v_ator text := coalesce(nullif(p_ator, ''), 'painel');
  v_esc record; v_saiu boolean; v_aviso boolean := false;
begin
  perform fn_exigir_papel(p_ator, array['admin', 'gestor']);
  select e.id, e.status, e.teste, e.data_servico, e.hora_inicio, t.telefone_e164, t.ativo, t.opt_in,
         coalesce(l.nome, 'local a confirmar') as local_nome into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id
  left join locais l on l.id = e.local_id where e.id = v_id;
  if not found then raise exception 'Programação não encontrada.'; end if;

  if not v_esc.teste then
    if v_esc.status in ('confirmada','recusada','em_execucao','concluida')
       or exists (select 1 from respostas where escala_id = v_id) then
      raise exception 'O técnico já respondeu esta programação. Use Cancelar para manter o histórico.';
    end if;
    if exists (select 1 from notificacoes where escala_id = v_id
                 and (status_envio in ('entregue','lida') or entregue_em is not null)) then
      raise exception 'O técnico já recebeu esta programação no WhatsApp. Use Cancelar para manter o histórico.';
    end if;
  end if;

  v_saiu := exists (select 1 from notificacoes where escala_id = v_id and status_envio in ('enfileirada','enviada'));
  if v_saiu and v_esc.ativo and not v_esc.teste then
    perform fn_wa_texto(v_esc.telefone_e164,
      '❌ A programação de ' || to_char(v_esc.data_servico, 'DD/MM') || ' às '
      || to_char(v_esc.hora_inicio, 'HH24:MI') || ' — ' || v_esc.local_nome
      || ' foi *cancelada*. Desconsidere a mensagem anterior.');
    v_aviso := true;
  end if;

  perform set_config('app.ator', v_ator, false);
  delete from escalas where id = v_id;
  insert into log_exclusoes (entidade, entidade_id, ator, escalas_removidas)
  values (case when v_esc.teste then 'escala_teste' else 'escala' end, v_id, v_ator, 1);
  return jsonb_build_object('removida', true, 'aviso_enviado', v_aviso, 'teste', v_esc.teste);
end $$;

create or replace function app_reenviar_escala(p_escala uuid)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  v_esc     record;
  v_tent    int;
  v_botoes  boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_payload jsonb;
  v_req     bigint;
begin
  select e.id, e.status, t.telefone_e164, t.ativo, t.opt_in
    into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id
  where e.id = p_escala;

  if not found then raise exception 'Programação não encontrada.'; end if;
  if v_esc.status not in ('agendada', 'notificada') then
    raise exception 'Só é possível reenviar programações agendadas ou aguardando resposta.';
  end if;
  if not v_esc.ativo or not v_esc.opt_in then
    raise exception 'O técnico está inativo ou sem autorização para mensagens.';
  end if;
  if exists (select 1 from notificacoes where escala_id = p_escala and status_envio = 'enfileirada') then
    raise exception 'Já existe um envio em andamento para esta programação. Aguarde um minuto.';
  end if;

  select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = p_escala;
  v_payload := fn_payload_escala(p_escala, v_esc.telefone_e164, v_tent > 1, v_botoes);
  v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');

  insert into notificacoes
    (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
  values
    (p_escala, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo,
     v_tent, case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
     'enfileirada', v_payload, now(), v_req);

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'reenvio_manual', v_email, jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('reenviada', true, 'tentativa', v_tent);
end $$;

create or replace function fn_alerta_prazo_escala()
returns void language plpgsql set search_path to 'public', 'extensions' as $function$
declare
  v_agora  timestamp := now() at time zone fn_config('fuso');
  v_amanha date := (now() at time zone fn_config('fuso'))::date + 1;
  v_dias   text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_multi  boolean := (select count(*) from empresas where ativo) > 1;
  v_p      jsonb;
  v_nomes  text;
  v_qtd    int;
  v_rasc   int;
  v_texto  text;
  v_tipo   text;
  v_hora   time;
  g        record;
begin
  if not (extract(isodow from v_amanha)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))) then
    return;
  end if;
  -- véspera de feriado: sem cobrança de escala (trabalho em feriado é excepcional)
  if exists (select 1 from feriados f where f.data = v_amanha) then
    return;
  end if;

  foreach v_tipo in array array['aviso', 'prazo'] loop
    v_hora := fn_config(case v_tipo when 'aviso' then 'alerta_escala_aviso' else 'alerta_escala_prazo' end)::time;
    continue when v_agora::time < v_hora;
    continue when exists (select 1 from alertas_enviados where tipo = v_tipo and data_ref = v_amanha);

    -- passou da janela (ou o aviso ficou para depois do prazo): registra sem enviar
    if v_agora::time > v_hora + interval '2 hours'
       or (v_tipo = 'aviso' and v_agora::time >= fn_config('alerta_escala_prazo')::time) then
      insert into alertas_enviados (tipo, data_ref, enviado) values (v_tipo, v_amanha, false);
      continue;
    end if;

    v_p    := fn_pendencias_escala(v_amanha);
    v_qtd  := jsonb_array_length(v_p->'sem_escala');
    v_rasc := (v_p->>'rascunhos')::int;
    insert into alertas_enviados (tipo, data_ref, enviado, detalhe)
    values (v_tipo, v_amanha, v_qtd > 0 or v_rasc > 0, v_p);

    continue when v_qtd = 0 and v_rasc = 0;

    for g in
      with sem as (
        select case when v_multi then t.empresa_id end as emp, t.nome, 0 as rasc
          from jsonb_array_elements(v_p->'sem_escala') x join tecnicos t on t.id = (x->>'id')::uuid
      ), rasc as (
        select case when v_multi then t.empresa_id end as emp, null::text as nome, count(*)::int as rasc
          from escalas e join tecnicos t on t.id = e.tecnico_id
         where e.data_servico = v_amanha and e.status = 'rascunho' and not e.teste
         group by 1
      )
      select emp, array_agg(nome order by nome) filter (where nome is not null) as nomes, sum(rasc)::int as rasc
        from (select * from sem union all select * from rasc) u
       group by emp
    loop
      v_qtd  := coalesce(array_length(g.nomes, 1), 0);
      v_rasc := coalesce(g.rasc, 0);
      continue when v_qtd = 0 and v_rasc = 0;
      select string_agg('• ' || n, E'\n') into v_nomes from unnest(g.nomes[1:15]) n;
      if v_qtd > 15 then v_nomes := v_nomes || E'\n• e mais ' || (v_qtd - 15); end if;

      v_texto := case v_tipo
        when 'aviso' then '⏰ *PROGRAMAÇÃO DE AMANHÃ — prazo ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '*'
        else '⚠️ *PRAZO DA PROGRAMAÇÃO ENCERRADO*'
      end || E'\n\n'
        || initcap(v_dias[extract(dow from v_amanha)::int + 1]) || ', ' || to_char(v_amanha, 'DD/MM') || E'\n\n'
        || case when v_qtd > 0 then v_qtd || ' técnico(s) sem programação:' || E'\n' || v_nomes || E'\n\n' else '' end
        || case when v_rasc > 0 then v_rasc || ' programação(ões) em rascunho, ainda não enviada(s).' || E'\n\n' else '' end
        || case v_tipo
             when 'aviso' then 'Envie pelo painel até as ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '.'
             else 'A equipe precisa receber a programação ainda hoje.'
           end;

      perform fn_avisar_supervisores(v_texto, null, g.emp);
    end loop;
  end loop;
end $function$;

create or replace function fn_preparar_ligacao(p_escala uuid)
 returns jsonb
 language plpgsql
 set search_path to 'public', 'extensions'
as $function$
declare
  v_esc record; v_id uuid; v_tent int; v_caller text := fn_config('twilio_caller_id');
begin
  if coalesce(v_caller, '') = '' then
    raise exception 'Configure twilio_caller_id com o número verificado na Twilio.';
  end if;
  if not coalesce(fn_ligacao_permitida(), false) then   -- config faltando nunca libera
    raise exception 'Ligações só em dias úteis, das % às %, fora de sábado, domingo e feriado.',
      fn_config('ligacao_janela_inicio'), fn_config('ligacao_janela_fim');
  end if;
  select e.id, e.tecnico_id, t.nome, t.telefone_e164, t.ativo, t.opt_in, e.status, e.local_id into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = p_escala;
  if not found then raise exception 'Programação não encontrada.'; end if;
  if not v_esc.ativo or not v_esc.opt_in then raise exception 'Técnico inativo ou sem autorização de contato.'; end if;
  if v_esc.status not in ('agendada','notificada') then raise exception 'A programação já foi respondida (%).', v_esc.status; end if;
  if v_esc.local_id is null then
    raise exception 'Programação sem local não é enviada nem ligada. Escolha o local.';
  end if;

  if not fn_pode_enviar(v_esc.telefone_e164) then
    raise exception 'Ambiente de homologação: só é possível ligar para cadastros de teste. % não é um.', v_esc.nome;
  end if;

  select count(*) + 1 into v_tent from ligacoes where escala_id = p_escala;
  insert into ligacoes (escala_id, tecnico_id, telefone, tentativa)
  values (p_escala, v_esc.tecnico_id, v_esc.telefone_e164, v_tent) returning id into v_id;
  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'ligacao_iniciada', 'ura', jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('ligacao_id', v_id, 'para', '+' || v_esc.telefone_e164, 'de', v_caller,
    'sid', fn_segredo('TWILIO_ACCOUNT_SID'), 'token', fn_segredo('TWILIO_AUTH_TOKEN'),
    'url_base', fn_config('voz_url'), 'voz_token', fn_segredo('VOZ_TOKEN'));
end $function$;

create or replace function fn_voz_resposta(p_ligacao uuid, p_digito text)
returns text language plpgsql volatile set search_path = public, extensions as $$
declare
  r record; v_voz text := coalesce(fn_config('voz_voice'), 'Polly.Camila-Neural');
  v_nome text; v_fala text; v_quando text;
begin
  select l.id, l.escala_id, l.tecnico_id, t.nome, e.status, e.data_servico, e.hora_inicio,
         coalesce(loc.nome, 'local a confirmar') as local_nome, t.telefone_e164 into r
  from ligacoes l join escalas e on e.id = l.escala_id join tecnicos t on t.id = l.tecnico_id
  left join locais loc on loc.id = e.local_id where l.id = p_ligacao;
  if not found then return '<?xml version="1.0" encoding="UTF-8"?><Response><Hangup/></Response>'; end if;

  v_nome := split_part(r.nome, ' ', 1);
  v_quando := to_char(r.data_servico, 'DD/MM') || ' às ' || to_char(r.hora_inicio, 'HH24:MI');
  update ligacoes set digito = p_digito, atendida_em = coalesce(atendida_em, now()),
         status = case when status in ('criada','discando') then 'atendida' else status end where id = p_ligacao;
  perform set_config('app.ator', 'ura: ' || r.nome, true);

  if p_digito = '1' and r.status in ('agendada','notificada') then
    update escalas set status = 'confirmada' where id = r.escala_id;
    insert into respostas (escala_id, tipo, texto_livre) values (r.escala_id, 'confirmacao', 'Confirmado por telefone (digitou 1)');
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (r.escala_id, 'ligacao_confirmada', 'ura', jsonb_build_object('ligacao', p_ligacao));
    perform fn_wa_texto(r.telefone_e164, '✅ Confirmado, ' || v_nome || '! Programação de ' || v_quando || ' — ' || r.local_nome || '.');
    v_fala := 'Perfeito, ' || v_nome || ', programação confirmada! Bom trabalho amanhã. Até mais!';
  elsif p_digito = '2' and r.status in ('agendada','notificada') then
    update escalas set status = 'recusada' where id = r.escala_id;
    insert into respostas (escala_id, tipo, texto_livre) values (r.escala_id, 'problema', 'Recusado por telefone (digitou 2)');
    insert into ocorrencias (escala_id) values (r.escala_id);
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (r.escala_id, 'ligacao_recusada', 'ura', jsonb_build_object('ligacao', p_ligacao));
    perform fn_wa_texto(r.telefone_e164, 'Recebido, ' || v_nome || '. Você negou a programação de ' || v_quando
      || ' pelo telefone. O supervisor já foi avisado. Se puder, descreva o problema em uma mensagem.');
    perform fn_avisar_supervisores('❌ *PROGRAMAÇÃO NEGADA POR TELEFONE*' || E'\n\n' || r.nome || ' negou a programação de '
      || v_quando || ' — ' || r.local_nome || E'\n' || 'Telefone: ' || r.telefone_e164, r.tecnico_id);
    v_fala := 'Entendi. Vou avisar o supervisor, ele entra em contato. Obrigado, ' || v_nome || '!';
  elsif p_digito in ('1','2') then
    v_fala := 'Essa programação já tinha sido respondida. Obrigado, ' || v_nome || '!';
  else
    update ligacoes set status = case when status = 'atendida' then 'atendida' else 'sem_resposta' end where id = p_ligacao;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (r.escala_id, 'ligacao_sem_resposta', 'ura', jsonb_build_object('ligacao', p_ligacao));
    perform fn_avisar_supervisores('📞 *LIGAÇÃO SEM RESPOSTA*' || E'\n\n' || r.nome
      || ' não respondeu à ligação sobre a programação de ' || v_quando || ' — ' || r.local_nome
      || E'\n' || 'Telefone: ' || r.telefone_e164 || E'\n\n' || 'Vale ligar pessoalmente.', r.tecnico_id);
    v_fala := 'Sem problema. Vou pedir pro supervisor entrar em contato. Até mais!';
  end if;

  return '<?xml version="1.0" encoding="UTF-8"?><Response><Say voice="' || v_voz
      || '" language="pt-BR">' || fn_xml_escape(v_fala) || '</Say><Hangup/></Response>';
end $$;

create or replace function fn_voz_twiml(p_ligacao uuid)
returns text language plpgsql stable
set search_path = public, extensions as $$
declare
  r record; v_voz text := coalesce(fn_config('voz_voice'), 'Polly.Camila-Neural');
  v_to text := coalesce(fn_config('voz_timeout_dtmf'), '6');
  v_acao text; v_nome text; v_quando text; v_texto text; v_hora int; v_min int;
  v_dias text[] := array['domingo','segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado'];
begin
  select l.id, t.nome, e.data_servico, e.hora_inicio, coalesce(loc.nome, 'local a confirmar') as local_nome
    into r
  from ligacoes l join escalas e on e.id = l.escala_id join tecnicos t on t.id = l.tecnico_id
  left join locais loc on loc.id = e.local_id where l.id = p_ligacao;
  if not found then return '<?xml version="1.0" encoding="UTF-8"?><Response><Hangup/></Response>'; end if;

  v_nome := fn_xml_escape(split_part(r.nome, ' ', 1));
  v_hora := extract(hour from r.hora_inicio)::int;
  v_min  := extract(minute from r.hora_inicio)::int;
  v_quando := case when r.data_servico = (now() at time zone fn_config('fuso'))::date + 1 then 'amanhã, ' else '' end
              || v_dias[extract(dow from r.data_servico)::int + 1]
              || ', às ' || v_hora || case when v_hora = 1 then ' hora' else ' horas' end
              || case when v_min > 0 then ' e ' || v_min || ' minutos' else '' end;
  v_acao := fn_xml_escape(fn_config('voz_url') || '?acao=digito&ligacao=' || p_ligacao
            || '&token=' || fn_segredo('VOZ_TOKEN'));
  v_texto := 'Oi, ' || v_nome || '! Aqui é o assistente da Infoxtec, tudo bem? '
    || 'É sobre a sua programação de ' || v_quando || ', em ' || fn_xml_escape(r.local_nome) || '. '
    || 'A gente ainda não recebeu a sua confirmação no WhatsApp. '
    || 'Digite 1 para aprovar a programação, ou digite 2 para negar.';

  return '<?xml version="1.0" encoding="UTF-8"?><Response><Pause length="1"/>'
    || '<Gather input="dtmf" numDigits="1" timeout="' || v_to || '" action="' || v_acao || '" method="POST">'
    ||   '<Say voice="' || v_voz || '" language="pt-BR">' || v_texto || '</Say></Gather>'
    || '<Gather input="dtmf" numDigits="1" timeout="' || v_to || '" action="' || v_acao || '" method="POST">'
    ||   '<Say voice="' || v_voz || '" language="pt-BR">Só pra confirmar: digite 1 para aprovar a programação, ou 2 para negar.</Say></Gather>'
    || '<Redirect method="POST">' || v_acao || '&amp;sem_resposta=1</Redirect></Response>';
end $$;

create or replace function fn_vigiar_motor()
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v        motor_estado;
  v_limite int := coalesce(fn_config_int('motor_alerta_min'), 5);
  v_local  timestamp := now() at time zone fn_config('fuso');
  v_janela boolean;
  v_min    int;
  v_desde  text;
  v_texto  text;
  v_mb     int;
begin
  select * into v from motor_estado where id;
  if not found then
    insert into motor_estado (id) values (true);
    return jsonb_build_object('situacao', 'iniciado');
  end if;

  v_min := floor(extract(epoch from now() - v.ultima_execucao_ok) / 60)::int;
  v_janela := v_local::time between fn_config('janela_envio_inicio')::time and fn_config('janela_envio_fim')::time;
  v_desde := to_char(v.ultima_execucao_ok at time zone fn_config('fuso'), 'DD/MM HH24:MI');

  -- tamanho do banco: um aviso por dia, dentro da janela
  v_mb := (pg_database_size(current_database()) / 1048576)::int;
  if v_janela and v_mb >= coalesce(fn_config_int('banco_alerta_mb'), 350)
     and v.banco_alerta_em is distinct from v_local::date then
    perform fn_avisar_tecnico(
      '⚠️ *BANCO DE DADOS PERTO DO LIMITE*' || E'\n\n'
      || 'O banco está com ' || v_mb || ' MB. O plano gratuito para de gravar em 500 MB.' || E'\n'
      || 'Acione o suporte para limpar ou arquivar dados.');
    update motor_estado set banco_alerta_em = v_local::date where id;
  end if;

  if v_min >= v_limite then
    if v.alerta_enviado_em is not null then
      return jsonb_build_object('situacao', 'parado', 'minutos', v_min, 'alerta', 'ja enviado');
    end if;
    if not v_janela then
      return jsonb_build_object('situacao', 'parado', 'minutos', v_min, 'alerta', 'aguardando janela de envio');
    end if;
    v_texto := '⚠️ *MOTOR DE ENVIO PARADO*' || E'\n\n'
      || 'Nenhuma execução concluída desde ' || v_desde || ' (' || v_min || ' min).' || E'\n'
      || 'Programações, lembretes e alertas não estão saindo. Acione o suporte.';
    perform fn_avisar_supervisores(v_texto);
    perform fn_avisar_tecnico(v_texto);
    update motor_estado set alerta_enviado_em = now(), atualizado_em = now() where id;
    return jsonb_build_object('situacao', 'parado', 'minutos', v_min, 'alerta', 'enviado');
  end if;

  if v.alerta_enviado_em is not null then
    if not v_janela then
      return jsonb_build_object('situacao', 'normalizado', 'alerta', 'aguardando janela de envio');
    end if;
    v_texto := '✅ *MOTOR DE ENVIO NORMALIZADO*' || E'\n\n'
      || 'Voltou a funcionar. Última execução: ' || v_desde || '.' || E'\n'
      || 'Confira no painel as programações do período parado.';
    perform fn_avisar_supervisores(v_texto);
    perform fn_avisar_tecnico(v_texto);
    update motor_estado set alerta_enviado_em = null, atualizado_em = now() where id;
    return jsonb_build_object('situacao', 'normalizado', 'alerta', 'enviado');
  end if;

  return jsonb_build_object('situacao', 'em dia', 'minutos', v_min);
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
  if not found then raise exception 'Programação não encontrada.'; end if;
  if e.status not in ('rascunho', 'agendada', 'notificada', 'confirmada') then
    raise exception 'Só dá para editar programação em rascunho, agendada, aguardando resposta ou confirmada.';
  end if;
  perform fn_edicao_permitida(e.id);

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
    raise exception 'O técnico já tem outra programação ativa nesse dia e horário.';
  end;

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (e.id, 'escala_editada', v_email, jsonb_build_object(
    'antes', jsonb_build_object('data', e.data_servico, 'hora', e.hora_inicio, 'local_id', e.local_id, 'tarefa', e.descricao_tarefa),
    'depois', jsonb_build_object('data', v_data, 'hora', v_hora, 'local_id', v_local, 'tarefa', v_tarefa),
    'nova_confirmacao', v_reconf));

  -- aviso ao tecnico quando a escala ja tinha saido
  if e.status in ('notificada', 'confirmada') and not e.teste then
    select telefone_e164, ativo, opt_in into v_tec from tecnicos where id = e.tecnico_id;
    if v_tec.ativo and v_tec.opt_in then
      if v_reconf then
        perform fn_wa_texto(v_tec.telefone_e164,
          '⚠️ *PROGRAMAÇÃO ALTERADA*' || E'\n\n' || 'Sua programação mudou. Confira os novos dados na mensagem a seguir e responda de novo.');
        select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = e.id;
        v_payload := fn_payload_escala(e.id, v_tec.telefone_e164, false, v_botoes);
        v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
        values (e.id, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo, v_tent,
                case when v_botoes then 'botoes_evolution' else 'texto_evolution' end, 'enfileirada', v_payload, now(), v_req);
      else
        perform fn_wa_texto(v_tec.telefone_e164,
          '📝 A tarefa da sua programação de ' || to_char(v_data, 'DD/MM') || ' às ' || to_char(v_hora, 'HH24:MI')
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
  if not found then raise exception 'Programação não encontrada.'; end if;
  if e.status <> 'recusada' then raise exception 'Só dá para substituir o técnico de uma programação recusada.'; end if;
  if p_tecnico = e.tecnico_id then raise exception 'Escolha outro técnico.'; end if;
  begin
    v_novo := fn_criar_escala(v_email, p_tecnico::text, coalesce(e.local_id::text, ''), e.data_servico::text,
                              e.hora_inicio::text, e.descricao_tarefa, e.duracao_prevista_min::text, e.prioridade, 'true');
  exception when unique_violation then
    raise exception 'Esse técnico já tem programação nesse dia e horário.';
  end;
  update escalas set tipo_atividade_id = e.tipo_atividade_id where id = v_novo;
  insert into escala_eventos (escala_id, evento, ator, detalhe) values
    (e.id, 'substituida', v_email, jsonb_build_object('nova_escala', v_novo, 'tecnico_id', p_tecnico)),
    (v_novo, 'substitui', v_email, jsonb_build_object('escala_anterior', e.id));
  return jsonb_build_object('escala', v_novo);
end $$;

create or replace function fn_edicao_permitida(p_escala uuid)
returns void language plpgsql
set search_path = public, extensions as $$
begin
  if exists (select 1 from escala_eventos where escala_id = p_escala and evento = 'escala_editada'
               and created_at > now() - interval '2 minutes') then
    raise exception 'Esta programação acabou de ser editada. Aguarde 2 minutos para editar de novo.';
  end if;
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
end $$;

create or replace function fn_escala_exige_local()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if new.local_id is null and (tg_op = 'INSERT' or old.local_id is not null) then
    raise exception 'Escolha o local da programação. Programação sem local não é criada nem enviada.';
  end if;
  return new;
end $$;

create or replace function fn_ponto_wh_ajuste(p_tecnico uuid, p_nome text, p_tel text, p_fuso text,
  p_etapa text, p_dados jsonb, p_norm text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
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
end $$;

create or replace function ponto_justificar_atestado(p_token text, p_motivo text, p_data date, p_valido_ate date default null,
  p_observacao text default null, p_anexo text default null, p_anexo_tipo text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec   uuid := fn_ponto_sessao(p_token);
  r       jsonb;
  v_n     int;
  v_nome  text;
begin
  if p_motivo not in ('atestado', 'alta_medica') then raise exception 'Use este envio só para atestado ou alta médica.'; end if;
  if p_motivo = 'atestado' and p_valido_ate is null then raise exception 'Informe até quando vale o atestado.'; end if;
  r := fn_ponto_falta_criar(v_tec, p_motivo, p_data, case when p_motivo = 'atestado' then p_valido_ate end,
                            null, null, p_observacao, p_anexo, p_anexo_tipo);
  if p_motivo = 'atestado' then
    select count(*), min(t.nome) into v_n, v_nome from escalas e join tecnicos t on t.id = e.tecnico_id
     where e.tecnico_id = v_tec and e.data_servico between greatest(p_data, (now() at time zone 'America/Bahia')::date) and p_valido_ate
       and e.status not in ('cancelada', 'recusada', 'concluida');
    if v_n > 0 then
      perform fn_ponto_avisar_supervisores(v_tec, '⚠️ *Ponto · ' || split_part(trim(v_nome), ' ', 1) || '*: afastado de '
        || to_char(p_data, 'DD/MM') || ' a ' || to_char(p_valido_ate, 'DD/MM') || ' (pedido nº ' || (r->>'numero') || '). '
        || v_n || ' programação(ões) no período: escolha outro técnico.');
    end if;
  end if;
  return r || jsonb_build_object('escalas_no_periodo', coalesce(v_n, 0));
end $$;

create or replace function fn_ponto_avisar_afastamento(p_tecnico uuid, p_data date, p_ate date, p_numero text)
returns int language plpgsql volatile set search_path = public, extensions as $$
declare v_n int; v_nome text;
begin
  select count(*), min(t.nome) into v_n, v_nome from escalas e join tecnicos t on t.id = e.tecnico_id
   where e.tecnico_id = p_tecnico and e.data_servico between greatest(p_data, (now() at time zone 'America/Bahia')::date) and p_ate
     and e.status not in ('cancelada', 'recusada', 'concluida');
  if v_n > 0 then
    perform fn_ponto_avisar_supervisores(p_tecnico, '⚠️ *Ponto · ' || split_part(trim(v_nome), ' ', 1) || '*: afastado de '
      || to_char(p_data, 'DD/MM') || ' a ' || to_char(p_ate, 'DD/MM') || ' (pedido nº ' || p_numero || '). '
      || v_n || ' programação(ões) no período: escolha outro técnico.');
  end if;
  return v_n;
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
