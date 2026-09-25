-- 24 | Fraseologia da URA: hora sem zero a esquerda e preposicao neutra no local

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
    || 'É sobre a sua escala de ' || v_quando || ', em ' || fn_xml_escape(r.local_nome) || '. '
    || 'A gente ainda não recebeu a sua confirmação no WhatsApp. '
    || 'Digite 1 para aprovar a escala, ou digite 2 para negar.';

  return '<?xml version="1.0" encoding="UTF-8"?><Response><Pause length="1"/>'
    || '<Gather input="dtmf" numDigits="1" timeout="' || v_to || '" action="' || v_acao || '" method="POST">'
    ||   '<Say voice="' || v_voz || '" language="pt-BR">' || v_texto || '</Say></Gather>'
    || '<Gather input="dtmf" numDigits="1" timeout="' || v_to || '" action="' || v_acao || '" method="POST">'
    ||   '<Say voice="' || v_voz || '" language="pt-BR">Só pra confirmar: digite 1 para aprovar a escala, ou 2 para negar.</Say></Gather>'
    || '<Redirect method="POST">' || v_acao || '&amp;sem_resposta=1</Redirect></Response>';
end $$;
