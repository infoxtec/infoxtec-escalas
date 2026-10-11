-- Migration 70 (11/10/2026): documento da justificativa pelo WhatsApp — E2b (decisões 55, 56 e 60).
--
-- O "ajuste" no WhatsApp passa a aceitar Saúde, Família e Convocação (opções 1 a 3), com o mesmo núcleo
-- do app: motivo → dia → último dia (ou horário) → foto ou PDF. O arquivo só é aceito na etapa do
-- documento; fora dela, continua recusado. A Edge Function webhook-evolution baixa o arquivo da Evolution
-- (getBase64FromMediaMessage) e entrega a fn_ponto_midia_receber, que cifra no cofre. Nada da mídia vai
-- para o log do webhook (a lista de chaves permitidas da migration 68 continua valendo) e a chave da mídia
-- não é guardada. O texto ao funcionário não escreve o motivo de saúde.

-- Etapas novas da conversa ------------------------------------------------------------------------------
alter table ponto_conversas drop constraint ponto_conversas_etapa_ck;
alter table ponto_conversas add constraint ponto_conversas_etapa_ck
  check (etapa in ('escolher_tipo', 'aguardando_local', 'aj_menu', 'aj_motivo', 'aj_dia', 'aj_marcacao', 'aj_hora', 'aj_periodo',
                   'aj_falta_motivo', 'aj_falta_dia', 'aj_falta_fim', 'aj_falta_periodo', 'aj_documento'));

-- Núcleo da falta com documento: agora informa o canal (app ou WhatsApp) ---------------------------------
drop function fn_ponto_falta_criar(uuid, text, date, date, time, time, text, text, text);
create function fn_ponto_falta_criar(p_tec uuid, p_motivo text, p_data date, p_data_fim date default null,
  p_hora_ini time default null, p_hora_fim time default null, p_observacao text default null,
  p_anexo text default null, p_anexo_tipo text default null, p_canal text default 'app')
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_tec   uuid := p_tec;
  v_mot   record;
  v_bin   bytea;
  r       jsonb;
begin
  select * into v_mot from ponto_motivos where codigo = p_motivo and ativo and grupo <> 'ponto';
  if not found then raise exception 'Escolha um motivo válido.'; end if;
  if p_anexo is not null then
    if length(p_anexo) > 7200000 then raise exception 'Arquivo grande demais: até 5 MB.'; end if;
    begin v_bin := decode(p_anexo, 'base64');
    exception when others then raise exception 'Arquivo inválido. Tire a foto de novo ou escolha outro PDF.'; end;
    if octet_length(v_bin) > 5242880 then raise exception 'Arquivo grande demais: até 5 MB.'; end if;
    -- tipo pelos primeiros bytes, nunca pelo que o aparelho diz
    if not ((p_anexo_tipo = 'image/jpeg' and substring(v_bin from 1 for 3) = '\xffd8ff'::bytea)
         or (p_anexo_tipo = 'image/png' and substring(v_bin from 1 for 8) = '\x89504e470d0a1a0a'::bytea)
         or (p_anexo_tipo = 'application/pdf' and substring(v_bin from 1 for 5) = '\x255044462d'::bytea)) then
      raise exception 'O documento precisa ser foto (JPG ou PNG) ou PDF.';
    end if;
  elsif v_mot.exige_anexo then
    raise exception 'Falta o documento: tire a foto ou escolha o PDF.';
  end if;

  r := fn_ponto_justificativa_criar(v_tec, p_motivo, p_data, null, null, p_hora_ini, p_hora_fim, p_observacao, p_canal, p_data_fim);
  if v_bin is not null then
    insert into ponto_justificativa_anexos (justificativa_id, tipo, tamanho, sha256, conteudo)
    values ((r->>'id')::uuid, p_anexo_tipo, octet_length(v_bin), encode(extensions.digest(v_bin, 'sha256'), 'hex'),
            fn_ponto_cofre_cifrar(v_bin));
  end if;
  return r - 'id' - 'exige_anexo';
end $$;

-- Menu de um grupo de faltas, numerado pela ordem da tabela de motivos -----------------------------------
create or replace function fn_ponto_motivos_grupo(p_grupo text)
returns text[] language sql stable set search_path = public, extensions as $$
  select coalesce(array_agg(codigo order by ordem), '{}') from ponto_motivos where grupo = p_grupo and ativo and grupo <> 'ponto'
$$;

create or replace function fn_ponto_menu_falta(p_grupo text)
returns text language sql stable set search_path = public, extensions as $$
  select case p_grupo when 'saude' then '*Saúde.* Qual é o caso?' when 'familia' then '*Família.* O que aconteceu?'
                      else '*Convocação.* De quem?' end || E'\n'
    || coalesce((select string_agg('*' || n || '* ' || m.nome, E'\n' order by n)
                   from unnest(fn_ponto_motivos_grupo(p_grupo)) with ordinality u(codigo, n)
                   join ponto_motivos m on m.codigo = u.codigo), '')
    || E'\n' || '*0* Cancelar'
    || case p_grupo when 'saude' then E'\n\n' || 'Não precisa informar a doença. (Lei 605/49, art. 6º; CLT art. 473)'
                    else E'\n' || '(CLT art. 473)' end
$$;

-- Última pergunta do pedido: a foto ou o PDF. A conversa fica 30 minutos à espera do arquivo --------------
create or replace function fn_ponto_pedir_documento(p_tecnico uuid, p_tel text, p_dados jsonb)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare v_doc text;
begin
  v_doc := case p_dados->>'motivo' when 'atestado' then 'atestado médico'
                                   when 'alta_medica' then 'atestado de aptidão (alta)'
                                   when 'comparecimento' then 'declaração de comparecimento'
                                   else 'comprovante' end;
  update ponto_conversas set etapa = 'aj_documento', dados = p_dados - 'midia_id' - 'midia_em',
         expira_em = now() + interval '30 minutes'
   where tecnico_id = p_tecnico;
  perform fn_ponto_wa(p_tel, 'Agora mande a *foto* ou o *PDF* do ' || v_doc || ': toque no 📎 e escolha Câmera ou Documento.' || E'\n'
    || 'Um arquivo, até 5 MB. Foto de visualização única não vale.'
    || case when p_dados->>'grupo' = 'saude' then E'\n' || 'Se o documento tiver o CID (código da doença), cubra antes da foto.' else '' end
    || E'\n' || 'O documento fica guardado no cofre e só quem aprova abre.');
  return jsonb_build_object('acao', 'ajuste_pediu_documento');
end $$;

-- Arquivo chegou na etapa do documento: confere tipo e tamanho declarados e pede à Edge Function que baixe
-- da Evolution. A chave da mídia não é guardada; o arquivo só existe cifrado, no cofre ---------------------
create or replace function fn_ponto_documento_recebido(p_tecnico uuid, p_tel text, p_wa_id text, p_msg jsonb, p_dados jsonb)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_m    jsonb := p_msg;
  v_doc  jsonb;
  v_mime text;
  v_tam  numeric;
begin
  if p_dados->>'midia_id' = p_wa_id then return jsonb_build_object('ignorado', 'ponto: arquivo repetido'); end if;
  if p_dados ? 'midia_id' and (p_dados->>'midia_em')::timestamptz > now() - interval '2 minutes' then
    perform fn_ponto_wa(p_tel, 'Já recebi um arquivo e estou conferindo. Aguarde a confirmação.');
    return jsonb_build_object('acao', 'ponto_documento_em_andamento');
  end if;
  if v_m ? 'ephemeralMessage' then v_m := v_m->'ephemeralMessage'->'message'; end if;
  if v_m ? 'documentWithCaptionMessage' then v_m := v_m->'documentWithCaptionMessage'->'message'; end if;
  v_doc := coalesce(v_m->'imageMessage', v_m->'documentMessage');
  if v_doc is null or coalesce((v_doc->>'viewOnce')::boolean, false) then
    perform fn_ponto_wa(p_tel, 'Mande uma *foto* comum (não de visualização única) ou um *PDF*. Para cancelar, responda *0*.');
    return jsonb_build_object('acao', 'ponto_documento_recusado', 'motivo', 'formato');
  end if;
  v_mime := lower(trim(split_part(coalesce(v_doc->>'mimetype', ''), ';', 1)));
  if v_mime not in ('image/jpeg', 'image/png', 'application/pdf') then
    perform fn_ponto_wa(p_tel, 'O documento precisa ser foto (JPG ou PNG) ou PDF. Mande outro arquivo ou responda *0* para cancelar.');
    return jsonb_build_object('acao', 'ponto_documento_recusado', 'motivo', 'tipo');
  end if;
  -- fileLength vem como número, texto ou Long ({low, high})
  v_tam := case jsonb_typeof(v_doc->'fileLength')
             when 'number' then (v_doc->>'fileLength')::numeric
             when 'string' then case when v_doc->>'fileLength' ~ '^\d{1,15}$' then (v_doc->>'fileLength')::numeric end
             when 'object' then case when v_doc->'fileLength'->>'high' ~ '^\d{1,10}$' and v_doc->'fileLength'->>'low' ~ '^-?\d{1,10}$'
                                     then (v_doc->'fileLength'->>'high')::numeric * 4294967296
                                          + ((v_doc->'fileLength'->>'low')::numeric + 4294967296) % 4294967296 end
           end;
  -- tamanho que não dá para ler é recusado: o download só sai com tamanho conhecido
  if v_tam is null or v_tam > 5242880 then
    perform fn_ponto_wa(p_tel, 'Arquivo grande demais ou sem tamanho: até 5 MB. Tire uma foto do documento ou mande um PDF menor.');
    return jsonb_build_object('acao', 'ponto_documento_recusado', 'motivo', 'tamanho');
  end if;
  update ponto_conversas set dados = p_dados || jsonb_build_object('midia_id', p_wa_id, 'midia_em', now()),
         expira_em = now() + interval '30 minutes'
   where tecnico_id = p_tecnico;
  return jsonb_build_object('acao', 'ponto_baixar_midia', 'tecnico', p_tecnico, 'midia_id', p_wa_id);
end $$;

-- Aviso aos supervisores: escalas dentro do afastamento (o texto diz só "afastado", nunca o motivo) -----
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
      || v_n || ' escala(s) no período: escolha outro técnico.');
  end if;
  return v_n;
end $$;

-- Arquivo baixado pela Edge Function: cria o pedido com o documento no cofre (mesmo núcleo do app) ---------
create or replace function fn_ponto_midia_receber(p_tecnico uuid, p_midia_id text, p_base64 text, p_mime text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  c      record;
  d      jsonb;
  r      jsonb;
  v_n    int;
begin
  select pc.dados, t.telefone_e164 as tel into c
    from ponto_conversas pc join tecnicos t on t.id = pc.tecnico_id
   where pc.tecnico_id = p_tecnico and pc.etapa = 'aj_documento' and pc.expira_em > now()
     and pc.dados->>'midia_id' = p_midia_id
     for update of pc;
  if not found then return jsonb_build_object('ignorado', 'ponto: conversa do documento não está mais aberta'); end if;
  d := c.dados;
  begin
    r := fn_ponto_falta_criar(p_tecnico, d->>'motivo', (d->>'data')::date, (d->>'data_fim')::date,
                              (d->>'hora_ini')::time, (d->>'hora_fim')::time, null,
                              p_base64, lower(trim(split_part(coalesce(p_mime, ''), ';', 1))), 'whatsapp');
  exception when others then
    if sqlstate = 'P0001' and (sqlerrm like 'Arquivo%' or sqlerrm like 'O documento%' or sqlerrm like 'Falta o documento%') then
      update ponto_conversas set dados = dados - 'midia_id' - 'midia_em' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(c.tel, sqlerrm || ' Mande outro arquivo ou responda *0* para cancelar.');
      return jsonb_build_object('acao', 'ponto_documento_recusado', 'motivo', 'conteudo');
    end if;
    update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
    perform fn_ponto_wa(c.tel, case when sqlstate = 'P0001' then 'Não foi possível registrar o pedido: ' || sqlerrm
                                    else 'Não foi possível registrar o pedido agora. Tente de novo ou fale com o gestor.' end);
    return jsonb_build_object('acao', 'ajuste_erro', 'erro', sqlerrm);
  end;
  if d->>'motivo' = 'atestado' then
    v_n := fn_ponto_avisar_afastamento(p_tecnico, (d->>'data')::date, (d->>'data_fim')::date, r->>'numero');
  end if;
  update ponto_conversas set expira_em = now(), dados = dados - 'midia_id' - 'midia_em' where tecnico_id = p_tecnico;
  -- motivo de saúde não vai por escrito no WhatsApp: só "Saúde"
  perform fn_ponto_wa(c.tel, '✅ *Pedido ' || (r->>'numero') || ' recebido*' || E'\n'
    || case when d->>'grupo' = 'saude' then 'Saúde' else r->>'motivo' end || ' · ' || (r->>'data') || ' · ' || (r->>'detalhe') || E'\n'
    || 'O documento está no cofre. O gestor vai analisar; a resposta chega aqui e na aba Ajuste do app.'
    || case when r->>'alerta' is not null then E'\n' || 'Esse pedido passa do limite da lei: o gestor decide se abona.' else '' end
    || case when d->>'motivo' = 'atestado' then E'\n\n' || 'Até ' || to_char((d->>'data_fim')::date, 'DD/MM')
         || ' vale o afastamento: o ponto e as escalas ficam bloqueados. Liberado antes? Escreva *ajuste* e mande o atestado de aptidão (alta).'
         else '' end);
  return jsonb_build_object('acao', 'ajuste_registrado', 'numero', r->'numero', 'escalas_no_periodo', coalesce(v_n, 0));
end $$;

-- Download falhou na Edge Function: libera a etapa para um novo envio ----------------------------------------
create or replace function fn_ponto_midia_falhou(p_tecnico uuid, p_midia_id text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare v_tel text;
begin
  update ponto_conversas pc set dados = pc.dados - 'midia_id' - 'midia_em'
    from tecnicos t
   where pc.tecnico_id = p_tecnico and t.id = pc.tecnico_id and pc.etapa = 'aj_documento' and pc.expira_em > now()
     and pc.dados->>'midia_id' = p_midia_id
  returning t.telefone_e164 into v_tel;
  if v_tel is null then return jsonb_build_object('ignorado', 'ponto: conversa do documento não está mais aberta'); end if;
  perform fn_ponto_wa(v_tel, 'Não consegui receber o arquivo. Mande de novo, ou responda *0* para cancelar.');
  return jsonb_build_object('acao', 'ponto_documento_falhou');
end $$;

-- Conversa de ajuste com as faltas (base: migration 68) ------------------------------------------------
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
        || 'Dentro da validade, o ponto e as escalas ficam bloqueados.'
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

-- Conversa do ponto: arquivo aceito só na etapa do documento (base: migration 68) ------------------------
create or replace function fn_ponto_wh(p_data jsonb)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
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
   where fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1)) and t.ativo;
  -- telefone canônico ambíguo (com e sem o 9): não arrisca marcar no funcionário errado
  if (select count(*) from tecnicos t where t.ativo
        and fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1))) > 1 then
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
