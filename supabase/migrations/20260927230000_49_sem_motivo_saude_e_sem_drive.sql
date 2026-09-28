-- 49 | Remove o motivo de saude da recusa e descontinua o vinculo por link do Google Drive
--
-- 1. Nao existe mais motivo "saude" no aceite de escala (decisao 40): o enum perde o valor e o menu
--    do WhatsApp passa a ter quatro opcoes (1 Transporte, 2 Conflito de agenda, 3 Falta de material,
--    4 Outro). Ocorrencias antigas com 'saude' sao reclassificadas como 'outro', com registro no log.
-- 2. O vinculo por link do Google Drive e descontinuado (decisao 41): o painel deixa de oferecer a
--    opcao e app_registrar_documento recusa origem 'drive'. Documentos ja vinculados continuam
--    legiveis, para nao sumir com dado sem decisao.
--
-- As tres funcoes partem da definicao vigente (47 e 48), como manda a regra do projeto.
-- ATENCAO: o tipo ocorrencia_motivo e recriado, porque o Postgres nao remove valor de enum.
-- A coluna nao e usada por nenhuma view, entao a troca de tipo nao tem dependencia.

-- 1. Dados e tipo -------------------------------------------------------------------------------

do $$
declare v_antigos int;
begin
  select count(*) into v_antigos from ocorrencias where motivo = 'saude';
  if v_antigos > 0 then
    raise notice 'Reclassificando % ocorrencia(s) de saude para outro', v_antigos;
    update ocorrencias set motivo = 'outro' where motivo = 'saude';
  end if;
end $$;

create type ocorrencia_motivo_novo as enum ('falta_material','conflito_agenda','transporte','outro');
alter table ocorrencias
  alter column motivo type ocorrencia_motivo_novo
  using motivo::text::ocorrencia_motivo_novo;
drop type ocorrencia_motivo;
alter type ocorrencia_motivo_novo rename to ocorrencia_motivo;

-- 2. Funcoes ------------------------------------------------------------------------------------

create or replace function fn_motivo_rotulo(p text)
returns text language sql immutable
set search_path = public, extensions as $$
  select case p
    when 'transporte' then 'Transporte'
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
      || '*1* - Transporte' || E'\n' || '*2* - Conflito de agenda' || E'\n'
      || '*3* - Falta de material' || E'\n' || '*4* - Outro');
  end if;
  perform fn_avisar_supervisores(
    '❌ *ESCALA RECUSADA*' || E'\n\n'
    || v_tec.nome || ' informou um problema na escala de ' || v_quando || ' — ' || v_esc.local_nome || E'\n'
    || 'Telefone: ' || v_tec.telefone_e164,
    v_tec.id);
  return jsonb_build_object('acao', 'recusada', 'escala', v_escala);
end $function$;

create or replace function app_registrar_documento(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id uuid; v_tec uuid := (p->>'tecnico_id')::uuid;
  v_tipo uuid := nullif(p->>'tipo_documento_id','')::uuid;
  v_validade date := nullif(p->>'validade','')::date;
  v_origem text := coalesce(nullif(p->>'origem',''), 'storage');
  v_url text := nullif(trim(p->>'url'), '');
begin
  if not exists (select 1 from tecnicos where id = v_tec) then raise exception 'Técnico não encontrado.'; end if;
  if v_origem <> 'storage' then
    raise exception 'O vínculo por link do Google Drive foi descontinuado. Envie o arquivo (PDF, JPG ou PNG).';
  end if;
  if coalesce(trim(p->>'caminho'),'') = '' then
    raise exception 'Caminho do arquivo ausente.';
  end if;

  insert into documentos (tecnico_id, tipo_documento_id, origem, url, caminho, nome_arquivo, mime, tamanho_bytes, validade, enviado_por)
  values (v_tec, v_tipo, v_origem, v_url, nullif(p->>'caminho',''),
          coalesce(nullif(trim(p->>'nome_arquivo'),''), 'documento'), nullif(p->>'mime',''),
          nullif(p->>'tamanho_bytes','')::int, v_validade, v_email)
  returning id into v_id;

  if v_tipo is not null then
    insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade, documento_id)
    values (v_tec, v_tipo, v_validade, v_id)
    on conflict (tecnico_id, tipo_documento_id) do update
      set validade = coalesce(excluded.validade, tecnico_documentos.validade),
          documento_id = v_id, atualizado_em = now();
  end if;
  return v_id;
end $$;


-- 3. Permissoes: so as funcoes app_* ficam acessiveis ao usuario logado (decisao 12) ------------

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
