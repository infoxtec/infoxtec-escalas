-- Migration 112 (17/10/2026): aviso só ao supervisor da mesma empresa (reunião de 17/10, prontidão SaaS; decisão 107).
-- Até aqui, supervisor sem empresa cadastrada recebia os avisos de todas as empresas (decisão 69, "enquanto houver uma
-- só empregadora"). Com mais de um cliente, isso vaza nome de funcionário e escala entre empresas. Passa a valer: o
-- supervisor só recebe aviso de funcionário da própria empresa; supervisor sem empresa não recebe aviso de ninguém
-- (o Checklist já aponta cadastro sem empresa, migration 80). Funcionário sem empresa (cadastro incompleto) continua
-- avisando todos os supervisores das escalas, para nenhum alerta operacional se perder. Os supervisores da produção
-- foram conferidos com empresa pelo responsável em 17/10.

-- fn_avisar_supervisores(text,uuid,uuid) (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.fn_avisar_supervisores(p_texto text, p_exceto uuid DEFAULT NULL::uuid, p_empresa uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  s record;
  v_n int := 0;
  v_emp uuid := coalesce(p_empresa, (select t.empresa_id from tecnicos t where t.id = p_exceto));
begin
  for s in
    select telefone_e164 from tecnicos
    where is_supervisor and ativo and id is distinct from p_exceto
      and (v_emp is null or empresa_id = v_emp)
  loop
    perform fn_wa_texto(s.telefone_e164, p_texto);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- fn_dispatcher_whatsapp() (parte da definição atual da homologação)
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
  v_avisos int := 0;
  v_emp uuid;
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

  -- FASE 3: supervisores, no maximo v_limite_sup escalas por execucao (as mais antigas primeiro);
  -- o resto fica para a proxima execucao, porque so a escala avisada ganha supervisor_avisado_em
  for a in select * from vw_acoes_pendentes
           where acao = 'escalonar' or (v_webhook and avisar_supervisor)
           order by enviada_em nulls first loop
    exit when v_avisos >= v_limite_sup;
    if exists (select 1 from escalas where id = a.escala_id and supervisor_avisado_em is not null) then continue; end if;
   begin
    v_texto := fn_msg_supervisor(a.escala_id, a.diagnostico, a.tentativa);
    -- só os supervisores da empresa do técnico (supervisor sem empresa recebe de todas; decisão 69)
    select t.empresa_id into v_emp from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = a.escala_id;
    for s in select telefone_e164 from tecnicos
              where is_supervisor and ativo and (v_emp is null or empresa_id = v_emp) loop
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
end $function$;

-- fn_ponto_avisar(uuid,text) (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.fn_ponto_avisar(p_tecnico uuid, p_tipo text)
 RETURNS text[]
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_fuso  text;
  v_emp   uuid;
  v_data  date;
  v_nome  text;
  j       jsonb;
  a       text;
  s       record;
  v_func  text;
  v_gest  text;
  v_saida text[] := '{}';
  v_rel   text[];
  v_lim   int;
  v_contr int;
  v_minimo int;
  v_sa    timestamptz;
  v_he    text;
begin
  v_lim := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  select split_part(trim(t.nome), ' ', 1), t.empresa_id, coalesce(e.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_data := (now() at time zone v_fuso)::date;

  -- saída para o intervalo: quando pode voltar (15 min de 4 a 6 h, 1 h acima de 6 h na jornada do dia)
  if p_tipo = 'saida_almoco' then
    v_contr := fn_carga_minutos_dia(p_tecnico, v_data);
    v_minimo := case when v_contr > 360 then v_lim
                     when v_contr > 240 then coalesce(nullif(fn_config('ponto_intervalo_curto_min'), '')::int, 15) end;
    if v_minimo is not null then
      select max(momento) into v_sa from ponto_marcacoes
       where tecnico_id = p_tecnico and tipo = 'saida_almoco' and momento >= v_data::timestamp at time zone v_fuso;
      if v_sa is not null then
        v_saida := v_saida || ('🍽️ Bom intervalo! Retorno a partir de '
          || to_char((v_sa + make_interval(mins => v_minimo)) at time zone v_fuso, 'HH24:MI')
          || ' (intervalo mínimo de ' || fn_ponto_hm(v_minimo) || ', CLT art. 71).');
      end if;
    end if;
    return v_saida;
  end if;

  -- início de hora extra: autorizada pela Programação ou enviada ao gestor para aprovar (decisão 100, parte 2)
  -- bloco próprio: uma falha aqui não desfaz os avisos, e uma falha nos avisos não desfaz o pedido (seguranca)
  if p_tipo = 'inicio_he' then
    begin
      v_he := fn_ponto_he_inicio(p_tecnico);
      if v_he is not null then v_saida := v_saida || v_he; end if;
    exception when others then
      raise warning 'ponto: pedido de aprovação de hora extra falhou: %', sqlerrm;
      begin
        perform fn_avisar_tecnico('⚠️ *HORA EXTRA*' || E'\n\n' || 'O pedido de aprovação de uma hora extra iniciada agora '
          || 'falhou e não foi enviado ao gestor. Confira em Ponto › Marcações e decida no painel.');
      exception when others then null;
      end;
      v_saida := v_saida || 'Início de hora extra registrado. Avise o seu gestor para aprovar.'::text;
    end;
    return v_saida;
  end if;

  j := fn_ponto_jornada_dia(p_tecnico, v_data);
  if j is null then return v_saida; end if;
  v_rel := case p_tipo
    when 'volta_almoco' then array['intervalo_curto', 'intervalo_longo']
    when 'entrada'      then array['interjornada_curta']
    when 'saida'        then array['he_acima_limite', 'sem_intervalo']
    when 'fim_he'       then array['he_acima_limite']
    else array[]::text[] end;
  for a in select x from jsonb_array_elements_text(j->'alertas') x where x = any(v_rel) loop
    v_func := case a
      when 'intervalo_curto'    then case when coalesce((j->>'trabalhado_min')::int, 0) > 360
                                       then 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de ' || fn_ponto_hm(v_lim)
                                            || ' — mínimo da CLT para jornada acima de 6 horas (art. 71).'
                                       else 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de '
                                            || coalesce(nullif(fn_config('ponto_intervalo_curto_min'), ''), '15')
                                            || ' min — mínimo da CLT para jornada acima de 4 horas (art. 71, §1º).' end
      when 'intervalo_longo'    then 'Intervalo de ' || fn_ponto_hm((j->>'intervalo_min')::int)
                                     || ', acima de 2 horas — permitido só com acordo escrito ou convenção coletiva (CLT art. 71).'
      when 'he_acima_limite'    then 'Hora extra de ' || fn_ponto_hm((j->>'he_escala_min')::int) || ' hoje sobre a jornada de '
                                     || fn_ponto_hm((j->>'contratual_min')::int) || ' do dia, acima do limite de 2 horas por dia (CLT art. 59).'
      when 'sem_intervalo'      then case when coalesce((j->>'trabalhado_min')::int, 0) > 360
                                       then 'Jornada de mais de 6 horas sem intervalo registrado — mínimo de 1 hora (CLT art. 71).'
                                       else 'Jornada de mais de 4 horas sem o intervalo mínimo de 15 minutos (CLT art. 71, §1º).' end
      when 'interjornada_curta' then 'Descanso de ' || fn_ponto_hm((j->>'interjornada_min')::int) || ' desde a última saída, abaixo das 11 horas entre jornadas (CLT art. 66).'
    end;
    v_saida := v_saida || ('⚠️ ' || v_func || ' A marcação vale; o gestor será avisado.');
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_' || a || '_' || p_tecnico, v_data, now(), true, jsonb_build_object('tecnico', p_tecnico))
    on conflict do nothing;
    if found then
      v_gest := case when a = 'he_acima_limite'
                  -- Alerta Crítico (decisão 90; texto do juridico): sem motivo, sem saúde, só o primeiro nome
                  then '🚨 *Alerta crítico · carga horária excedida*' || E'\n' || 'O ponto de ' || v_nome || ' hoje ('
                       || to_char(v_data, 'DD/MM') || ') passou de ' || fn_ponto_hm((j->>'limite_min')::int)
                       || ' (jornada do dia + 2h extras). Confira no painel.'
                  else '⚠️ *Ponto · ' || v_nome || '* (' || to_char(v_data, 'DD/MM') || '): ' || v_func end;
      -- supervisor sem empresa cadastrada recebe enquanto houver uma só empregadora; cadastrar a
      -- empresa do supervisor antes do segundo cliente (separação por cliente, backlog 074)
      for s in select telefone_e164 from tecnicos
                where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
                  and empresa_id = v_emp loop
        perform fn_ponto_wa(s.telefone_e164, v_gest);
      end loop;
    end if;
  end loop;
  return v_saida;
exception when others then
  raise warning 'ponto: avisos de jornada falharam: %', sqlerrm;
  return '{}';
end $function$;

-- fn_ponto_avisar_supervisores(uuid,text) (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.fn_ponto_avisar_supervisores(p_tecnico uuid, p_texto text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare s record; v_emp uuid;
begin
  select empresa_id into v_emp from tecnicos where id = p_tecnico;
  for s in select telefone_e164 from tecnicos
            where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
              and empresa_id = v_emp loop
    perform fn_ponto_wa(s.telefone_e164, p_texto);
  end loop;
end $function$;

-- fn_ponto_he_inicio(uuid) (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.fn_ponto_he_inicio(p_tecnico uuid)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_fuso text; v_emp uuid; v_nome text;
  v_data date;
  m      record;
  e      record;
  v_id   uuid;
  v_num  bigint;
  v_txt  text;
  s      record;
begin
  select split_part(trim(t.nome), ' ', 1), t.empresa_id, coalesce(x.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
    from tecnicos t left join empresas x on x.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_data := (now() at time zone v_fuso)::date;
  select x.id, x.momento into m from ponto_marcacoes x
   where x.tecnico_id = p_tecnico and x.tipo = 'inicio_he' and x.momento >= v_data::timestamp at time zone v_fuso
   order by x.nsr desc limit 1;
  if m.id is null or exists (select 1 from ponto_he_autorizacoes h where h.marcacao_id = m.id) then return null; end if;

  -- a Programação do dia cobre o horário do início: autorizada pela Programação
  select s2.id, coalesce(s2.hora_fim_prevista, s2.hora_inicio + make_interval(mins => coalesce(s2.duracao_prevista_min, 0))) as fim
    into e
    from escalas s2
   where s2.tecnico_id = p_tecnico and s2.data_servico = v_data and not coalesce(s2.teste, false)
     and s2.status not in ('cancelada', 'recusada', 'rascunho')
     and s2.hora_inicio <= (m.momento at time zone v_fuso)::time
     -- fim depois da meia-noite (menor que o início) cobre até o fim do dia
     and (coalesce(s2.hora_fim_prevista, s2.hora_inicio + make_interval(mins => coalesce(s2.duracao_prevista_min, 0)))
            > (m.momento at time zone v_fuso)::time
          or coalesce(s2.hora_fim_prevista, s2.hora_inicio + make_interval(mins => coalesce(s2.duracao_prevista_min, 0)))
            < s2.hora_inicio)
   order by 2 desc limit 1;
  if e.id is not null then
    insert into ponto_he_autorizacoes (empresa_id, tecnico_id, marcacao_id, data, inicio, origem, escala_id, status,
                                       decidido_por, decidido_em, canal_decisao)
    values (v_emp, p_tecnico, m.id, v_data, m.momento, 'programada', e.id, 'aprovada', 'Programação do dia', now(), 'programacao');
    return '✅ Hora extra autorizada pela Programação de hoje (até ' || to_char(e.fim, 'HH24:MI') || ').';
  end if;

  insert into ponto_he_autorizacoes (empresa_id, tecnico_id, marcacao_id, data, inicio, origem)
  values (v_emp, p_tecnico, m.id, v_data, m.momento, 'pedido') returning id, numero into v_id, v_num;
  v_txt := '⏱️ *Hora extra · ' || v_nome || '* (pedido nº ' || v_num || ')' || E'\n'
        || 'Início às ' || to_char(m.momento at time zone v_fuso, 'HH24:MI') || ' de ' || to_char(v_data, 'DD/MM')
        || ', fora da Programação. Aprova a hora extra?';
  -- supervisor sem empresa cadastrada recebe enquanto houver uma só empregadora (como os avisos de jornada)
  for s in select telefone_e164 from tecnicos
            where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
              and empresa_id = v_emp loop
    begin
      if coalesce(fn_config('usar_botoes'), 'false')::boolean then
        perform fn_evo_post('/message/sendButtons/' || fn_config('evolution_instancia'),
          jsonb_build_object('number', s.telefone_e164, 'title', 'Hora extra', 'description', v_txt, 'footer', 'Trilha Ponto',
            'buttons', jsonb_build_array(
              jsonb_build_object('type', 'reply', 'displayText', 'Aprovar', 'id', 'he:ok:' || v_id),
              jsonb_build_object('type', 'reply', 'displayText', 'Reprovar', 'id', 'he:nao:' || v_id))));
      else
        perform fn_ponto_wa(s.telefone_e164, v_txt || E'\n' || 'Decida no painel: Ponto › Ajustes e pedidos.');
      end if;
    exception when others then
      raise warning 'ponto: pedido de aprovação de hora extra falhou: %', sqlerrm;
    end;
  end loop;
  return '⏳ Início de hora extra registrado e enviado ao gestor para aprovação; a resposta chega aqui. A marcação já vale.';
end $function$;

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
