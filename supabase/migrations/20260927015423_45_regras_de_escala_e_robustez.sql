-- 45 | Regras de escala (27/09) e robustez do banco
--
-- Decisões do responsável em 27/09 (docs/decisoes.md, 30 e 31):
-- 1. Escala confirmada (ou em execução) vira concluída sozinha 5 minutos depois do término
--    previsto (config conclusao_automatica_min). Etapa 10.
-- 2. Escala recusada libera o horário do técnico para uma nova escala (fecha a decisão 9).
-- Robustez (docs/analise-global.md, seção 4):
-- 3. Índices nas chaves estrangeiras usadas ao excluir técnico, local e documento
--    (excluir técnico com 260 escalas: 3.526 ms -> 39 ms) e remoção do índice duplicado idx_notif_wa.
-- 4. Motor: trava contra execução simultânea, lock_timeout, conclusão automática (fase 7) e
--    sinal para um monitor externo (healthchecks.io), que avisa mesmo com Supabase ou Evolution fora.
-- 5. Vigia: avisos técnicos também para os telefones de alerta_tecnico_telefones e alerta diário de
--    tamanho do banco.
-- 6. Retenção: payload_envio das notificações é apagado depois de 90 dias (a tabela que mais cresce).
-- 7. Validação dos valores de config (etapa 8).
-- 8. Limpeza do legado (etapa 9): funções da bancada de teste e restrição NOT VALID.
-- Partindo das definições atuais da homologação (migration 44).

-- 1 e 2 ------------------------------------------------------------------------------------------
insert into config (chave, valor, descricao) values
  ('conclusao_automatica_min', '5',   'Minutos depois do término previsto para a escala confirmada virar concluída'),
  ('retencao_payload_dias',    '90',  'Dias até apagar o conteúdo enviado (payload_envio) das notificações'),
  ('banco_alerta_mb',          '350', 'Tamanho do banco, em MB, que dispara aviso técnico (limite do plano gratuito: 500)'),
  ('alerta_tecnico_telefones', '5571981776307', 'Telefones (E.164, separados por vírgula) que recebem os avisos técnicos: motor parado, banco cheio'),
  ('monitor_ping_url',         '',    'URL de ping do healthchecks.io; vazio desliga o monitor externo')
on conflict (chave) do nothing;

drop index if exists escalas_horario_ativo_unico;
create unique index escalas_horario_ativo_unico
  on escalas (tecnico_id, data_servico, hora_inicio)
  where status not in ('cancelada', 'recusada');

create or replace function fn_concluir_escalas()
returns int language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_min   int := coalesce(fn_config_int('conclusao_automatica_min'), 5);
  v_local timestamp := now() at time zone fn_config('fuso');
  v_n     int;
begin
  perform set_config('app.ator', 'conclusao_automatica', true);
  update escalas set status = 'concluida'
   where status in ('confirmada', 'em_execucao')
     and data_servico <= v_local::date
     and data_servico + hora_inicio
         + make_interval(mins => coalesce(duracao_prevista_min, 0) + coalesce(intervalo_min, 0) + v_min)
         <= v_local;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- 3 ----------------------------------------------------------------------------------------------
create index if not exists idx_respostas_notificacao on respostas (notificacao_id);
create index if not exists idx_ocorrencias_escala    on ocorrencias (escala_id);
create index if not exists idx_ligacoes_tecnico      on ligacoes (tecnico_id);
create index if not exists idx_escalas_local         on escalas (local_id);
create index if not exists idx_tecdoc_documento      on tecnico_documentos (documento_id);
drop index if exists idx_notif_wa;   -- duplica o unique notificacoes_wa_message_id_key

-- 4 ----------------------------------------------------------------------------------------------
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

-- Evolution falhando: nos ultimos 15 minutos houve pelo menos 2 falhas e nenhum envio com sucesso
create or replace function fn_evolution_falhando()
returns boolean language sql stable
set search_path = public, extensions as $$
  select count(*) filter (where status_envio = 'falha') >= 2
     and count(*) filter (where status_envio in ('enviada', 'entregue', 'lida')) = 0
    from notificacoes
   where created_at > now() - interval '15 minutes'
$$;

-- 5 ----------------------------------------------------------------------------------------------
alter table motor_estado add column if not exists banco_alerta_em date;

-- Avisos tecnicos (motor, banco) para os telefones de alerta_tecnico_telefones
create or replace function fn_avisar_tecnico(p_texto text)
returns int language plpgsql
set search_path = public, extensions as $$
declare
  v_tel text;
  v_n   int := 0;
begin
  for v_tel in
    select distinct trim(t) from unnest(string_to_array(coalesce(fn_config('alerta_tecnico_telefones'), ''), ',')) t
     where trim(t) <> ''
       and trim(t) not in (select telefone_e164 from tecnicos where is_supervisor and ativo)  -- ja avisados
  loop
    perform fn_wa_texto(v_tel, p_texto);
    v_n := v_n + 1;
  end loop;
  return v_n;
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
      || 'Escalas, lembretes e alertas não estão saindo. Acione o suporte.';
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
      || 'Confira no painel as escalas do período parado.';
    perform fn_avisar_supervisores(v_texto);
    perform fn_avisar_tecnico(v_texto);
    update motor_estado set alerta_enviado_em = null, atualizado_em = now() where id;
    return jsonb_build_object('situacao', 'normalizado', 'alerta', 'enviado');
  end if;

  return jsonb_build_object('situacao', 'em dia', 'minutos', v_min);
end $$;

-- 6 ----------------------------------------------------------------------------------------------
create or replace function fn_limpeza_logs()
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare v_webhook int; v_alertas int; v_cron int; v_payload int;
begin
  delete from webhook_eventos
   where recebido_em < now() - make_interval(days => coalesce(fn_config_int('retencao_webhook_dias'), 30));
  get diagnostics v_webhook = row_count;
  delete from alertas_enviados where data_ref < current_date - 90;
  get diagnostics v_alertas = row_count;
  delete from cron.job_run_details
   where end_time < now() - make_interval(days => coalesce(fn_config_int('retencao_cron_dias'), 7));
  get diagnostics v_cron = row_count;
  -- o conteudo enviado so serve para conferencia recente; a notificacao (status, datas) fica
  update notificacoes set payload_envio = null
   where payload_envio is not null
     and created_at < now() - make_interval(days => coalesce(fn_config_int('retencao_payload_dias'), 90));
  get diagnostics v_payload = row_count;
  return jsonb_build_object('webhook_eventos', v_webhook, 'alertas_enviados', v_alertas,
                            'cron', v_cron, 'payload_notificacoes', v_payload);
end $$;

-- 7 ----------------------------------------------------------------------------------------------
-- Valor invalido em config e recusado na gravacao, em vez de quebrar o motor depois
create or replace function fn_validar_config()
returns trigger language plpgsql
set search_path = public, extensions as $$
declare
  v text := coalesce(new.valor, '');
begin
  begin
    if new.chave in ('envios_por_execucao','max_tentativas','avisar_supervisor_na','intervalo_reenvio_min',
                     'timeout_entrega_min','motor_alerta_min','jornada_min','intervalo_min','intervalo_apos_min',
                     'antecedencia_minima_min','certificacao_aviso_dias','documento_tamanho_max_mb',
                     'ligacao_apos_tentativas','ligacao_intervalo_min','ligacao_max_por_escala',
                     'ligacao_por_execucao','voz_timeout_dtmf','retencao_webhook_dias','retencao_cron_dias',
                     'retencao_documentos_anos','retencao_payload_dias','conclusao_automatica_min',
                     'banco_alerta_mb','alerta_certificacoes_dow') then
      if v !~ '^\d+$' then raise exception 'inteiro'; end if;
      if new.chave = 'alerta_certificacoes_dow' and v::int not between 0 and 6 then raise exception 'dia'; end if;
    elsif new.chave = 'hora_noturna_min' then
      if v::numeric <= 0 then raise exception 'positivo'; end if;
    elsif new.chave in ('janela_envio_inicio','janela_envio_fim','alerta_escala_aviso','alerta_escala_prazo',
                        'alerta_certificacoes_hora','ligacao_janela_inicio','ligacao_janela_fim',
                        'noturno_inicio','noturno_fim') then
      if v !~ '^\d{2}:\d{2}$' then raise exception 'hora'; end if;
      perform v::time;
    elsif new.chave in ('webhook_ativo','usar_botoes','ligacao_ativa','sem_escala_incluir_supervisores') then
      if v not in ('true','false') then raise exception 'booleano'; end if;
    elsif new.chave = 'fuso' then
      if not exists (select 1 from pg_timezone_names where name = v) then raise exception 'fuso'; end if;
    elsif new.chave = 'alerta_dias_semana' then
      if v !~ '^[1-7](,[1-7])*$' then raise exception 'dias'; end if;
    elsif new.chave = 'alerta_tecnico_telefones' then
      if v <> '' and v !~ '^\d{12,13}(\s*,\s*\d{12,13})*$' then raise exception 'telefones'; end if;
    elsif new.chave = 'monitor_ping_url' then
      if v <> '' and v !~ '^https://' then raise exception 'url'; end if;
    end if;
  exception when others then
    raise exception 'Valor inválido para %: "%"', new.chave, new.valor
      using hint = case new.chave
        when 'alerta_dias_semana' then 'Use dias de 1 (segunda) a 7, separados por vírgula: 1,2,3,4,5'
        when 'alerta_tecnico_telefones' then 'Use telefones com DDI e DDD, só números, separados por vírgula: 5571999999999'
        when 'fuso' then 'Use um fuso válido, por exemplo America/Bahia'
        else 'Confira o formato: inteiro, hora HH:MM ou true/false' end;
  end;
  return new;
end $$;

drop trigger if exists trg_config_validar on config;
create trigger trg_config_validar before insert or update on config
  for each row execute function fn_validar_config();

-- 8 ----------------------------------------------------------------------------------------------
drop function if exists fn_teste_wa_botoes(text, text, text);
drop function if exists fn_teste_wa_resposta(bigint);
drop function if exists fn_teste_wa_texto(text, text);

-- valida a restricao se os dados permitirem; se houver linha antiga fora da regra, fica como esta
do $$
begin
  alter table documentos validate constraint documentos_origem_coerente;
exception when check_violation then
  raise notice 'documentos_origem_coerente continua NOT VALID: ha linhas antigas fora da regra';
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
