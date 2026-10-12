-- Migration 79 (12/10/2026): avisos aos supervisores só da empresa do técnico (diagnóstico do DeepSeek,
-- item 1; pré-requisito do 2º cliente, decisão 69). Regra única, a mesma do ponto (fn_ponto_avisar_supervisores):
-- o supervisor recebe aviso de técnico da própria empresa; supervisor sem empresa e técnico sem empresa
-- seguem como hoje (todos), até o cadastro estar completo. Alertas de sistema (motor parado, teto do app do
-- ponto) continuam para todos. Com uma só empresa cadastrada, nada muda para quem recebe.
-- Base: definições atuais da homologação.

-- Função comum dos avisos: ganha p_empresa; sem ela, usa a empresa de p_exceto (o técnico do aviso).
-- As chamadas existentes (recusa, detalhe, URA) já passam o técnico e passam a filtrar sem mudar.
drop function if exists fn_avisar_supervisores(text, uuid);
create function fn_avisar_supervisores(p_texto text, p_exceto uuid default null, p_empresa uuid default null)
returns integer language plpgsql set search_path to 'public', 'extensions' as $function$
declare
  s record;
  v_n int := 0;
  v_emp uuid := coalesce(p_empresa, (select t.empresa_id from tecnicos t where t.id = p_exceto));
begin
  for s in
    select telefone_e164 from tecnicos
    where is_supervisor and ativo and id is distinct from p_exceto
      and (v_emp is null or empresa_id is null or empresa_id = v_emp)
  loop
    perform fn_wa_texto(s.telefone_e164, p_texto);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- Escala de amanhã: uma mensagem por empresa (com mais de uma cadastrada), só com os técnicos dela
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
        when 'aviso' then '⏰ *ESCALA DE AMANHÃ — prazo ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '*'
        else '⚠️ *PRAZO DA ESCALA ENCERRADO*'
      end || E'\n\n'
        || initcap(v_dias[extract(dow from v_amanha)::int + 1]) || ', ' || to_char(v_amanha, 'DD/MM') || E'\n\n'
        || case when v_qtd > 0 then v_qtd || ' técnico(s) sem escala:' || E'\n' || v_nomes || E'\n\n' else '' end
        || case when v_rasc > 0 then v_rasc || ' escala(s) em rascunho, ainda não enviada(s).' || E'\n\n' else '' end
        || case v_tipo
             when 'aviso' then 'Envie pelo painel até as ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '.'
             else 'A equipe precisa receber a escala ainda hoje.'
           end;

      perform fn_avisar_supervisores(v_texto, null, g.emp);
    end loop;
  end loop;
end $function$;

-- Documentos a vencer: uma mensagem por empresa (com mais de uma cadastrada), só com os técnicos dela
create or replace function fn_alerta_certificacoes()
returns void language plpgsql set search_path to 'public', 'extensions' as $function$
declare
  v_agora timestamp := now() at time zone fn_config('fuso');
  v_hoje date := (now() at time zone fn_config('fuso'))::date;
  v_hora time := coalesce(fn_config('alerta_certificacoes_hora')::time, '08:00');
  v_multi boolean := (select count(*) from empresas where ativo) > 1;
  v_qtd int;
  g record;
begin
  if extract(isodow from v_hoje)::text <> coalesce(fn_config('alerta_certificacoes_dow'), '1') then return; end if;
  if v_agora::time < v_hora or v_agora::time > v_hora + interval '2 hours' then return; end if;
  if exists (select 1 from alertas_enviados where tipo = 'certificacoes' and data_ref = v_hoje) then return; end if;

  select count(*) into v_qtd from vw_tecnico_documentos
   where tecnico_ativo and not perfil_teste and situacao in ('vencido','vencendo','sem_data');

  insert into alertas_enviados (tipo, data_ref, enviado, detalhe)
  values ('certificacoes', v_hoje, coalesce(v_qtd,0) > 0, jsonb_build_object('qtd', coalesce(v_qtd,0)));
  if coalesce(v_qtd,0) = 0 then return; end if;

  for g in
    select case when v_multi then t.empresa_id end as emp,
           string_agg('• ' || d.tecnico || ' — ' || d.documento ||
             case when d.situacao = 'vencido' then ' (VENCIDO em ' || to_char(d.validade,'DD/MM') || ')'
                  when d.situacao = 'sem_data' then ' (sem data cadastrada)'
                  else ' (vence em ' || to_char(d.validade,'DD/MM') || ')' end, E'\n' order by d.validade nulls first) as linhas
      from vw_tecnico_documentos d join tecnicos t on t.id = d.tecnico_id
     where d.tecnico_ativo and not d.perfil_teste and d.situacao in ('vencido','vencendo','sem_data')
     group by 1
  loop
    perform fn_avisar_supervisores('📋 *DOCUMENTOS A VENCER*' || E'\n\n' || g.linhas || E'\n\n'
      || 'Técnico com documento vencido não deve ser escalado para atividades que o exigem.', null, g.emp);
  end loop;
end $function$;

-- Motor: fase 3 só para os supervisores da empresa do técnico da escala (resto igual à migration 78)
create or replace function fn_dispatcher_whatsapp()
returns void language plpgsql security definer set search_path to 'public', 'extensions' as $function$
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
              where is_supervisor and ativo and (v_emp is null or empresa_id is null or empresa_id = v_emp) loop
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
