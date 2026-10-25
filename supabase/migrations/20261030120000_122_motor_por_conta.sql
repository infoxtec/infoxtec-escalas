-- 122: multiempresa F2f-1, motor por conta (docs/multiempresa-f2.md). Os avisos que o motor manda a supervisores
-- (programação de amanhã, documentos a vencer, recusa e ligação sem resposta, comandos do WhatsApp) passam a ir só a
-- supervisores da mesma conta, e os avisos do dia são calculados e registrados por conta. O alerta de segurança do app
-- do ponto (teto por hora) é da plataforma e vai só aos supervisores da conta 1 (operadora). O alerta de motor parado
-- segue para todos (decisão 107: alerta de sistema, sem dado de cliente).
-- Funções recriadas a partir da definição da homologação de 30/10 (md5 do conjunto das quatro: 8c2270d3…).

-- registro de alertas por conta --------------------------------------------------------------------------------------------
-- a chave passa a incluir a conta: o mesmo aviso do dia existe uma vez em cada conta
alter table interno.alertas_enviados drop constraint alertas_enviados_pkey;
alter table interno.alertas_enviados add primary key (conta_id, tipo, data_ref);
-- a chave já começa pela conta; a busca sem conta (aviso do intervalo pendente) usa este
drop index interno.alertas_enviados_conta_id_idx;
create index alertas_enviados_tipo_data_idx on interno.alertas_enviados (tipo, data_ref);

-- alerta por funcionário ou por empresa (o identificador vai no tipo ou no detalhe): a conta vem dele
create or replace function interno.fn_alerta_conta()
returns trigger
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $$
declare
  v_id    uuid;
  v_conta uuid;
begin
  v_id := coalesce(nullif(new.detalhe ->> 'tecnico', '')::uuid,
                   (regexp_match(new.tipo, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'))[1]::uuid);
  if v_id is not null then
    select conta_id into v_conta from interno.tecnicos where id = v_id;
    if v_conta is null then
      select conta_id into v_conta from interno.empresas where id = v_id;
    end if;
    if v_conta is not null then
      new.conta_id := v_conta;
    else
      raise warning 'alertas_enviados: % não é funcionário nem empresa; fica na conta informada', v_id;
    end if;
  end if;
  return new;
end $$;

create trigger tg_00_conta before insert on interno.alertas_enviados
  for each row execute function interno.fn_alerta_conta();

-- aviso a supervisores: da empresa informada, ou da do funcionário; sem empresa, só da mesma conta ---------------------
drop function interno.fn_avisar_supervisores(text, uuid, uuid);
create function interno.fn_avisar_supervisores(p_texto text, p_exceto uuid DEFAULT NULL::uuid, p_empresa uuid DEFAULT NULL::uuid,
                                               p_conta uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  s record;
  v_n int := 0;
  v_emp uuid := coalesce(p_empresa, (select t.empresa_id from tecnicos t where t.id = p_exceto));
  -- sem conta (alerta de sistema, como o motor parado): todos, como antes (decisão 107)
  v_conta uuid := coalesce(p_conta, (select t.conta_id from tecnicos t where t.id = p_exceto),
                           (select e.conta_id from empresas e where e.id = p_empresa));
begin
  for s in
    select telefone_e164 from tecnicos
    where is_supervisor and ativo and id is distinct from p_exceto
      and (v_emp is null or empresa_id = v_emp)
      and (v_conta is null or conta_id = v_conta)
  loop
    perform fn_wa_texto(s.telefone_e164, p_texto);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- documentos a vencer: uma lista por conta (e por empresa, quando a conta tem mais de uma) -----------------------------
CREATE OR REPLACE FUNCTION interno.fn_alerta_certificacoes()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_agora timestamp := now() at time zone fn_config('fuso');
  v_hoje date := (now() at time zone fn_config('fuso'))::date;
  v_hora time := coalesce(fn_config('alerta_certificacoes_hora')::time, '08:00');
  v_multi boolean;
  v_qtd int;
  c record;
  g record;
begin
  if extract(isodow from v_hoje)::text <> coalesce(fn_config('alerta_certificacoes_dow'), '1') then return; end if;
  if v_agora::time < v_hora or v_agora::time > v_hora + interval '2 hours' then return; end if;

  for c in select x.id from contas x where x.ativa order by x.criada_em loop
   -- erro numa conta não derruba o aviso das outras
   begin
    continue when exists (select 1 from alertas_enviados where conta_id = c.id and tipo = 'certificacoes' and data_ref = v_hoje);
    v_multi := (select count(*) from empresas where ativo and conta_id = c.id) > 1;

    select count(*) into v_qtd from vw_tecnico_documentos d join tecnicos t on t.id = d.tecnico_id
     where d.tecnico_ativo and not d.perfil_teste and d.situacao in ('vencido','vencendo','sem_data') and t.conta_id = c.id;

    insert into alertas_enviados (conta_id, tipo, data_ref, enviado, detalhe)
    values (c.id, 'certificacoes', v_hoje, coalesce(v_qtd,0) > 0, jsonb_build_object('qtd', coalesce(v_qtd,0)));
    continue when coalesce(v_qtd,0) = 0;

    for g in
      select case when v_multi then t.empresa_id end as emp,
             string_agg('• ' || d.tecnico || ' — ' || d.documento ||
               case when d.situacao = 'vencido' then ' (VENCIDO em ' || to_char(d.validade,'DD/MM') || ')'
                    when d.situacao = 'sem_data' then ' (sem data cadastrada)'
                    else ' (vence em ' || to_char(d.validade,'DD/MM') || ')' end, E'\n' order by d.validade nulls first) as linhas
        from vw_tecnico_documentos d join tecnicos t on t.id = d.tecnico_id
       where d.tecnico_ativo and not d.perfil_teste and d.situacao in ('vencido','vencendo','sem_data') and t.conta_id = c.id
       group by 1
    loop
      perform fn_avisar_supervisores('📋 *DOCUMENTOS A VENCER*' || E'\n\n' || g.linhas || E'\n\n'
        || 'Técnico com documento vencido não deve ser escalado para atividades que o exigem.', null, g.emp, c.id);
    end loop;
   exception when others then
    raise warning 'fn_alerta_certificacoes: conta % falhou (%)', c.id, sqlerrm;
   end;
  end loop;
end $function$;

-- programação de amanhã: pendências e aviso por conta ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.fn_alerta_prazo_escala()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_agora  timestamp := now() at time zone fn_config('fuso');
  v_amanha date := (now() at time zone fn_config('fuso'))::date + 1;
  v_dias   text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_multi  boolean;
  v_p      jsonb;
  v_nomes  text;
  v_qtd    int;
  v_rasc   int;
  v_texto  text;
  v_tipo   text;
  v_hora   time;
  c        record;
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

    for c in select x.id from contas x where x.ativa order by x.criada_em loop
     -- erro numa conta não derruba o aviso das outras
     begin
      continue when exists (select 1 from alertas_enviados where conta_id = c.id and tipo = v_tipo and data_ref = v_amanha);

      -- passou da janela (ou o aviso ficou para depois do prazo): registra sem enviar
      if v_agora::time > v_hora + interval '2 hours'
         or (v_tipo = 'aviso' and v_agora::time >= fn_config('alerta_escala_prazo')::time) then
        insert into alertas_enviados (conta_id, tipo, data_ref, enviado) values (c.id, v_tipo, v_amanha, false);
        continue;
      end if;

      v_multi := (select count(*) from empresas where ativo and conta_id = c.id) > 1;
      v_p    := fn_pendencias_escala(v_amanha, c.id);
      v_qtd  := jsonb_array_length(v_p->'sem_escala');
      v_rasc := (v_p->>'rascunhos')::int;
      insert into alertas_enviados (conta_id, tipo, data_ref, enviado, detalhe)
      values (c.id, v_tipo, v_amanha, v_qtd > 0 or v_rasc > 0, v_p);

      continue when v_qtd = 0 and v_rasc = 0;

      for g in
        with sem as (
          select case when v_multi then t.empresa_id end as emp, t.nome, 0 as rasc
            from jsonb_array_elements(v_p->'sem_escala') x join tecnicos t on t.id = (x->>'id')::uuid
        ), rasc as (
          select case when v_multi then t.empresa_id end as emp, null::text as nome, count(*)::int as rasc
            from escalas e join tecnicos t on t.id = e.tecnico_id
           where e.data_servico = v_amanha and e.status = 'rascunho' and not e.teste and e.conta_id = c.id
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

        perform fn_avisar_supervisores(v_texto, null, g.emp, c.id);
      end loop;
     exception when others then
      raise warning 'fn_alerta_prazo_escala: conta % falhou (%)', c.id, sqlerrm;
     end;
    end loop;
  end loop;
end $function$;

-- teto do app do ponto: alerta de segurança da plataforma, só à operadora (conta 1) --------------------------------------
CREATE OR REPLACE FUNCTION interno.fn_ponto_alerta_teto(p_qual text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  s record;
begin
  insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
  values ('ponto_teto_' || p_qual || '_' || to_char(now() at time zone 'America/Bahia', 'HH24'),
          (now() at time zone 'America/Bahia')::date, now(), true, jsonb_build_object('teto', p_qual))
  on conflict do nothing;
  if not found then return; end if;
  raise warning 'app do ponto: teto de % por hora atingido', p_qual;
  for s in select telefone_e164 from tecnicos where is_supervisor and ativo and opt_in and not perfil_teste
                                               and conta_id = '00000000-0000-0000-0000-000000000001' loop
    begin
      perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', s.telefone_e164,
          'text', case when p_qual = 'avisos'
            then 'Trilha Ponto: muitos CPFs não encontrados no app do ponto nesta hora (possível tentativa de descobrir '
                 || 'funcionários). O app voltou à resposta única até a próxima hora; o código continua chegando para quem é cadastrado.'
            else 'Trilha Ponto: o limite de ' || case when p_qual = 'erros' then 'tentativas de login'
                  else 'códigos por WhatsApp' end || ' por hora foi atingido (possível ataque). '
                  || 'Enquanto durar, o funcionário entra com o código gerado pelo gestor no painel.' end));
    exception when others then null;
    end;
  end loop;
end $function$;

-- conta e papel sem depender da sessão: a regra de fn_conta_atual numa função pura, que a sessão do painel e as
-- Edge Functions (que não passam pelo PostgREST) usam igual. Não grava nada na sessão (revisão do seguranca).
create or replace function interno.fn_conta_de(p_email text, p_pedida text)
 returns uuid
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email  text := lower(nullif(p_email, ''));
  v_pedida text := nullif(btrim(p_pedida), '');
  v_conta  uuid;
  v_n      int;
begin
  if v_email is null then
    return null;
  end if;
  if v_pedida is not null then
    if v_pedida !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      raise exception 'Conta inválida.';
    end if;
    select m.conta_id into v_conta
      from interno.conta_membros m join interno.contas c on c.id = m.conta_id
     where m.email = v_email and m.ativo and c.ativa and m.conta_id = v_pedida::uuid;
    if v_conta is null then
      raise exception 'Sem acesso a esta conta.';
    end if;
    return v_conta;
  end if;
  select min(m.conta_id::text)::uuid, count(*) into v_conta, v_n
    from interno.conta_membros m join interno.contas c on c.id = m.conta_id
   where m.email = v_email and m.ativo and c.ativa;
  if v_n > 1 then
    raise exception 'Escolha a conta para continuar.';
  end if;
  return v_conta;
end $function$;

-- a sessão do painel: e-mail do token e cabeçalho x-conta do PostgREST (regra inalterada desde a 117)
create or replace function interno.fn_conta_atual()
 returns uuid
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_pedida text;
begin
  -- cabeçalho do PostgREST; ausente fora de uma chamada pela API (cron, Edge Function, teste)
  begin
    v_pedida := nullif(current_setting('request.headers', true), '')::json ->> 'x-conta';
  exception when others then
    v_pedida := null;
  end;
  return interno.fn_conta_de(auth.jwt() ->> 'email', v_pedida);
end $function$;

-- papel na conta para Edge Functions: e-mail do token já conferido no servidor de autenticação e x-conta do pedido
create or replace function interno.fn_papel_na_conta_de(p_email text, p_conta_cabecalho text default null)
 returns text
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select m.papel from interno.conta_membros m
   where m.conta_id = interno.fn_conta_de(p_email, p_conta_cabecalho) and m.email = lower(p_email) and m.ativo
$function$;

-- motor: supervisor de funcionário sem empresa só da mesma conta (revisão do seguranca; base: homologação, md5 4fafe311…)
CREATE OR REPLACE FUNCTION interno.fn_dispatcher_whatsapp()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  n record; r_resp record; a record; s record;
  v_wa_id text; v_req bigint; v_tent int; v_texto text; v_payload jsonb; v_botoes boolean;
  v_sent int := 0;
  v_avisos int := 0;
  v_emp uuid;
  v_conta uuid;
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
    -- só os supervisores da empresa do técnico (decisão 107); funcionário sem empresa avisa os da conta dele (122)
    select t.empresa_id, e.conta_id into v_emp, v_conta from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = a.escala_id;
    for s in select telefone_e164 from tecnicos
              where is_supervisor and ativo and (v_emp is null or empresa_id = v_emp) and conta_id = v_conta loop
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
