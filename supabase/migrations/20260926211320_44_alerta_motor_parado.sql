-- 44 | Alerta de motor parado
--
-- Se o motor (fn_dispatcher_whatsapp) parar de concluir execucoes, as escalas deixam de sair e
-- ninguem fica sabendo: a falha so aparecia em cron.job_run_details. Agora:
-- 1. O motor grava em motor_estado a hora de cada execucao concluida (na mesma transacao).
-- 2. fn_vigiar_motor, num agendamento proprio (setup/cron.sql, a cada 5 minutos), avisa os
--    supervisores quando passam mais de motor_alerta_min minutos sem execucao concluida, uma vez
--    por ocorrencia, e avisa de novo quando normaliza. Respeita a janela de envio: parada de
--    madrugada e avisada no inicio da janela.
-- 3. app_estado_motor alimenta o quadro da aba Operacao.
-- Partindo do motor da migration 41 (definicao atual da homologacao e da producao).

create table if not exists motor_estado (
  id                 boolean primary key default true check (id),   -- linha unica
  ultima_execucao_ok timestamptz not null default now(),
  alerta_enviado_em  timestamptz,
  atualizado_em      timestamptz not null default now()
);
alter table motor_estado enable row level security;
insert into motor_estado (id) values (true) on conflict (id) do nothing;

insert into config (chave, valor, descricao) values
  ('motor_alerta_min', '5', 'Minutos sem execucao concluida do motor para avisar os supervisores')
on conflict (chave) do nothing;

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

  -- Execucao concluida: registro lido pelo vigia (fn_vigiar_motor). Se algo acima falhar sem
  -- tratamento, a transacao inteira e desfeita e este registro tambem.
  update motor_estado set ultima_execucao_ok = now(), atualizado_em = now() where id;
end $function$;

create or replace function fn_vigiar_motor()
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v        motor_estado;
  v_limite int := coalesce(fn_config_int('motor_alerta_min'), 5);
  v_local  time := (now() at time zone fn_config('fuso'))::time;
  v_janela boolean;
  v_min    int;
  v_desde  text;
begin
  select * into v from motor_estado where id;
  if not found then
    insert into motor_estado (id) values (true);
    return jsonb_build_object('situacao', 'iniciado');
  end if;

  v_min := floor(extract(epoch from now() - v.ultima_execucao_ok) / 60)::int;
  v_janela := v_local between fn_config('janela_envio_inicio')::time and fn_config('janela_envio_fim')::time;
  v_desde := to_char(v.ultima_execucao_ok at time zone fn_config('fuso'), 'DD/MM HH24:MI');

  if v_min >= v_limite then
    if v.alerta_enviado_em is not null then
      return jsonb_build_object('situacao', 'parado', 'minutos', v_min, 'alerta', 'ja enviado');
    end if;
    if not v_janela then
      return jsonb_build_object('situacao', 'parado', 'minutos', v_min, 'alerta', 'aguardando janela de envio');
    end if;
    perform fn_avisar_supervisores(
      '⚠️ *MOTOR DE ENVIO PARADO*' || E'\n\n'
      || 'Nenhuma execução concluída desde ' || v_desde || ' (' || v_min || ' min).' || E'\n'
      || 'Escalas, lembretes e alertas não estão saindo. Acione o suporte.');
    update motor_estado set alerta_enviado_em = now(), atualizado_em = now() where id;
    return jsonb_build_object('situacao', 'parado', 'minutos', v_min, 'alerta', 'enviado');
  end if;

  if v.alerta_enviado_em is not null then
    if not v_janela then
      return jsonb_build_object('situacao', 'normalizado', 'alerta', 'aguardando janela de envio');
    end if;
    perform fn_avisar_supervisores(
      '✅ *MOTOR DE ENVIO NORMALIZADO*' || E'\n\n'
      || 'Voltou a funcionar. Última execução: ' || v_desde || '.' || E'\n'
      || 'Confira no painel as escalas do período parado.');
    update motor_estado set alerta_enviado_em = null, atualizado_em = now() where id;
    return jsonb_build_object('situacao', 'normalizado', 'alerta', 'enviado');
  end if;

  return jsonb_build_object('situacao', 'em dia', 'minutos', v_min);
end $$;

create or replace function app_estado_motor()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
declare
  v        motor_estado;
  v_limite int := coalesce(fn_config_int('motor_alerta_min'), 5);
begin
  perform app_exigir(array['admin','gestor','leitura']);
  select * into v from motor_estado where id;
  return jsonb_build_object(
    'ultima_execucao_ok', v.ultima_execucao_ok,
    'minutos',            floor(extract(epoch from now() - v.ultima_execucao_ok) / 60)::int,
    'limite_min',         v_limite,
    'em_dia',             now() - v.ultima_execucao_ok < make_interval(mins => v_limite),
    'alerta_ativo',       v.alerta_enviado_em is not null,
    'motor_agendado',     exists (select 1 from cron.job where jobname = 'dispatcher-whatsapp' and active),
    'vigia_agendado',     exists (select 1 from cron.job where jobname = 'vigia-motor' and active));
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
