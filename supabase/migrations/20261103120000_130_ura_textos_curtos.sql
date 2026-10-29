-- URA: falas mais curtas e amigáveis, aprovadas pelo responsável em 29/10. Abertura de cerca de 22 s para cerca de 10 s;
-- sai o "bom trabalho amanhã" fixo (a programação pode ser de outro dia). Só muda o texto falado: as regras, o WhatsApp
-- e os avisos ao supervisor continuam os mesmos.

set lock_timeout = '5s';

CREATE OR REPLACE FUNCTION interno.fn_voz_twiml(p_ligacao uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  r record; v_voz text := coalesce(fn_config('voz_voice'), 'Polly.Camila-Neural');
  v_to text := coalesce(fn_config('voz_timeout_dtmf'), '6');
  v_acao text; v_nome text; v_quando text; v_texto text; v_hora int; v_min int;
  -- o dia falado curto ("quinta", não "quinta-feira"): a abertura fica em cerca de 10 s
  v_dias text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
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
  -- textos aprovados pelo responsável em 29/10: curtos, com o primeiro nome
  v_texto := 'Oi, ' || v_nome || '! Aqui é da Infoxtec. '
    || 'Sua programação é ' || v_quando || ', em ' || fn_xml_escape(r.local_nome) || '. '
    || 'Para confirmar, digite 1. Se não puder ir, digite 2.';

  return '<?xml version="1.0" encoding="UTF-8"?><Response><Pause length="1"/>'
    || '<Gather input="dtmf" numDigits="1" timeout="' || v_to || '" action="' || v_acao || '" method="POST">'
    ||   '<Say voice="' || v_voz || '" language="pt-BR">' || v_texto || '</Say></Gather>'
    || '<Gather input="dtmf" numDigits="1" timeout="' || v_to || '" action="' || v_acao || '" method="POST">'
    ||   '<Say voice="' || v_voz || '" language="pt-BR">Digite 1 para confirmar, ou 2 se não puder ir.</Say></Gather>'
    || '<Redirect method="POST">' || v_acao || '&amp;sem_resposta=1</Redirect></Response>';
end $function$;

CREATE OR REPLACE FUNCTION interno.fn_voz_resposta(p_ligacao uuid, p_digito text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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

  -- falas aprovadas pelo responsável em 29/10 (sem "amanhã" fixo: a programação pode ser de outro dia)
  if p_digito = '1' and r.status in ('agendada','notificada') then
    update escalas set status = 'confirmada' where id = r.escala_id;
    insert into respostas (escala_id, tipo, texto_livre) values (r.escala_id, 'confirmacao', 'Confirmado por telefone (digitou 1)');
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (r.escala_id, 'ligacao_confirmada', 'ura', jsonb_build_object('ligacao', p_ligacao));
    perform fn_wa_texto(r.telefone_e164, '✅ Confirmado, ' || v_nome || '! Programação de ' || v_quando || ' — ' || r.local_nome || '.');
    v_fala := 'Confirmado, ' || v_nome || '! Obrigado e bom trabalho.';
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
    v_fala := 'Tudo bem, ' || v_nome || '. Vou avisar o supervisor. Até mais!';
  elsif p_digito in ('1','2') then
    v_fala := 'Essa programação já estava respondida. Obrigado, ' || v_nome || '!';
  else
    update ligacoes set status = case when status = 'atendida' then 'atendida' else 'sem_resposta' end where id = p_ligacao;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (r.escala_id, 'ligacao_sem_resposta', 'ura', jsonb_build_object('ligacao', p_ligacao));
    perform fn_avisar_supervisores('📞 *LIGAÇÃO SEM RESPOSTA*' || E'\n\n' || r.nome
      || ' não respondeu à ligação sobre a programação de ' || v_quando || ' — ' || r.local_nome
      || E'\n' || 'Telefone: ' || r.telefone_e164 || E'\n\n' || 'Vale ligar pessoalmente.', r.tecnico_id);
    v_fala := 'Não recebi sua resposta. O supervisor vai falar com você. Até mais!';
  end if;

  return '<?xml version="1.0" encoding="UTF-8"?><Response><Say voice="' || v_voz
      || '" language="pt-BR">' || fn_xml_escape(v_fala) || '</Say><Hangup/></Response>';
end $function$;

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
