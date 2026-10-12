-- Migration 78 (12/10/2026): teto nos avisos aos supervisores (fase 3 do motor, diagnóstico do DeepSeek, item 2).
-- Antes, a fase 3 avisava todas as escalas pendentes de uma vez, uma mensagem por supervisor para cada uma:
-- depois de uma queda da Evolution ou do motor, isso vira uma rajada no número do WhatsApp (risco de
-- bloqueio). Agora cada execução (a cada minuto) avisa no máximo `supervisor_avisos_por_execucao`
-- escalas, das mais antigas para as mais novas; as demais ficam para o minuto seguinte, sem perda, porque
-- só a escala avisada recebe `supervisor_avisado_em`. O teto conta escalas: cada uma gera uma mensagem por
-- supervisor ativo, então o pico é 5 × supervisores por minuto. Base: definição atual da homologação.

insert into config (chave, valor, descricao) values
  ('supervisor_avisos_por_execucao', '5',
   'Máximo de escalas avisadas aos supervisores a cada execução do motor (1 por minuto); o resto vai no minuto seguinte')
on conflict (chave) do nothing;

create or replace function fn_dispatcher_whatsapp()
returns void language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare
  n record; r_resp record; a record; s record;
  v_wa_id text; v_req bigint; v_tent int; v_texto text; v_payload jsonb; v_botoes boolean;
  v_sent int := 0;
  v_avisos int := 0;
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
    for s in select telefone_e164 from tecnicos where is_supervisor and ativo loop
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
