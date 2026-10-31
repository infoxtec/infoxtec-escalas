-- Multiempresa F8c-1, exportação completa dos dados da conta (decisão 129; portabilidade, LGPD art. 18, V). O
-- administrador da conta (com duas etapas) ou a plataforma pedem; a Edge Function exportar-conta lê cada tabela da conta
-- em CSV, monta um ZIP (dados/<tabela>.csv, esquema.json, LEIA-ME.txt, manifesto.sha256), guarda no bucket privado
-- exportacoes e grava o resultado; o link para baixar é assinado na hora, só para quem pode, e o pacote vence em 7
-- dias. Ao encerrar a conta, sai uma exportação final e o link vai por e-mail aos administradores dela. Ficam fora:
-- segredos, hashes de código e de sessão, identificadores de pedidos internos e arquivos binários (espelhos em PDF,
-- documentos, anexos de saúde e AFD entram na F8c-2). Dado de saúde sai com a mesma máscara do painel (o motivo vira
-- 'saude' e os textos ficam vazios): o completo vai só no pacote de saúde da F8c-2, para quem tem ve_saude. O motor
-- (a cada minuto) retoma pedido que falhou ou travou e manda apagar os pacotes vencidos.

set lock_timeout = '5s';

create table interno.conta_exportacoes (
  id               uuid primary key default gen_random_uuid(),
  conta_id         uuid not null default interno.fn_conta_padrao() references interno.contas (id),
  pedido_por       text not null,
  origem           text not null check (origem in ('admin', 'plataforma', 'encerramento')),
  estado           text not null default 'pendente' check (estado in ('pendente', 'gerando', 'pronta', 'falhou', 'expirada')),
  criado_em        timestamptz not null default now(),
  iniciado_em      timestamptz,
  concluido_em     timestamptz,
  expira_em        timestamptz,
  tentativas       int not null default 0,
  arquivo          text,
  tamanho          bigint,
  manifesto_sha256 text check (manifesto_sha256 ~ '^[0-9a-f]{64}$'),
  baixadas         int not null default 0,
  erro             text check (length(erro) <= 300),
  unique (conta_id, id)
);
alter table interno.conta_exportacoes enable row level security;
create index conta_exportacoes_conta_idx on interno.conta_exportacoes (conta_id, criado_em desc);

-- bucket privado: só a Edge Function (chave de serviço) grava e assina
insert into storage.buckets (id, name, public) values ('exportacoes', 'exportacoes', false)
on conflict (id) do update set public = false;

insert into interno.config (chave, valor, descricao)
select 'exportacao_url', replace(c.valor, '/espelho-pdf', '/exportar-conta'), 'Edge Function que gera a exportação completa da conta'
  from interno.config c where c.chave = 'espelho_pdf_url'
on conflict (chave) do nothing;

-- o token da exportação é gravado pelo próprio banco no primeiro pedido
CREATE OR REPLACE FUNCTION interno.fn_segredo_gravar(p_nome text, p_valor text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  if p_nome not in ('WEBHOOK_TOKEN', 'WEBHOOK_TOKEN_ANTERIOR', 'ESPELHO_PDF_TOKEN', 'ALERTA_EMAIL_TOKEN', 'EXPORTACAO_TOKEN')
     and p_nome !~ '^(EVOLUTION_API_KEY|WEBHOOK_TOKEN)_[0-9a-f]{32}$' then
    raise exception 'segredo não permitido';
  end if;
  select id into v_id from vault.secrets where name = p_nome;
  if v_id is null then
    perform vault.create_secret(p_valor, p_nome);
  else
    perform vault.update_secret(v_id, p_valor);
  end if;
end $function$
;

create or replace function interno.fn_exportacao_token_ok(p_token text)
 returns boolean
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v text := fn_segredo('EXPORTACAO_TOKEN');
begin
  return v is not null and coalesce(p_token, '') <> ''
         and extensions.digest(p_token, 'sha256') = extensions.digest(v, 'sha256');
end $function$;

-- CSV (RFC 4180): nulo vira vazio, o resto entre aspas com as aspas dobradas
create or replace function interno.fn_csv(p text)
 returns text
 language sql
 immutable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select case when p is null then '' else '"' || replace(p, '"', '""') || '"' end;
$function$;

create or replace function interno.fn_motivo_saude(p_codigo text)
 returns boolean
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce((select saude from interno.ponto_motivos where codigo = p_codigo), false);
$function$;

-- o que entra: toda tabela do interno com conta_id, menos colunas de segredo, hash de acesso, pedido interno e binário
create or replace function interno.fn_exportar_tabelas()
 returns table (tabela text, colunas text[], chave text[])
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select c.relname::text,
         array(select a.attname::text from pg_attribute a
                where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                  and a.atttypid <> 'bytea'::regtype
                  and a.attname not in ('segredo', 'webhook_segredo', 'token_hash', 'codigo_hash', 'assinatura_chave',
                                        'envio_req', 'http_req_id', 'webhook_req', 'vig_req')
                  and not (c.relname = 'ponto_conversas' and a.attname = 'dados')   -- pedido em andamento (pode ser de saúde)
                order by a.attnum),
         array(select a.attname::text from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
                where i.indrelid = c.oid and i.indisprimary order by array_position(i.indkey::int2[], a.attnum))
    from pg_class c
   where c.relnamespace = 'interno'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'conta_id' and not a.attisdropped)
   order by 1;
$function$;

-- chama a Edge Function com o token (gravado no primeiro uso); sem URL configurada não chama (banco do CI)
create or replace function interno.fn_exportacao_chamar(p_corpo jsonb)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_url text := nullif(trim(coalesce(fn_config('exportacao_url'), '')), '');
  v_tok text;
begin
  if v_url is null then return; end if;
  perform pg_advisory_xact_lock(hashtext('exportacao_token'));
  v_tok := fn_segredo('EXPORTACAO_TOKEN');
  if v_tok is null then
    v_tok := encode(extensions.gen_random_bytes(32), 'hex');
    perform fn_segredo_gravar('EXPORTACAO_TOKEN', v_tok);
  end if;
  perform net.http_post(url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-exportacao-token', v_tok),
    body := p_corpo, timeout_milliseconds := 10000);
end $function$;

-- a exportação final do encerramento falhou de vez: a plataforma gera de novo e manda ao cliente antes da exclusão
create or replace function interno.fn_exportacao_final_falhou(p_conta uuid, p_erro text)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform fn_alerta_email('Trilha: a exportação final de uma conta encerrada falhou',
    'A exportação final da conta ' || (select nome from contas where id = p_conta) || ' falhou 3 vezes ('
    || coalesce(p_erro, 'sem detalhe') || '). Gere de novo na tela Contas e mande o link ao cliente antes de '
    || coalesce(to_char((select apagar_em from contas where id = p_conta) at time zone coalesce(fn_config('fuso'), 'America/Bahia'),
                        'DD/MM/YYYY'), 'a exclusão') || '.');
end $function$;

-- manutenção, chamada pelo motor a cada minuto: retoma o que falhou (2 min depois) ou travou (15 min) e manda apagar os
-- pacotes vencidos; sem nada a fazer, não chama ninguém
create or replace function interno.fn_exportacoes_manutencao()
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e record;
begin
  for e in select id from conta_exportacoes
            where tentativas < 3
              and ((estado = 'pendente' and coalesce(concluido_em, criado_em) < now() - interval '2 minutes')
                   or (estado = 'gerando' and iniciado_em < now() - interval '15 minutes'))
            order by criado_em limit 3 loop
    perform fn_exportacao_chamar(jsonb_build_object('id', e.id));
  end loop;
  -- travado na 3ª tentativa: falhou de vez (a final do encerramento avisa a plataforma)
  for e in update conta_exportacoes set estado = 'falhou', concluido_em = now(), erro = coalesce(erro, 'sem resposta da geração')
            where (estado = 'gerando' and tentativas >= 3 and iniciado_em < now() - interval '15 minutes')
               -- a geração nunca respondeu (função fora do ar ou URL errada): a final não espera mais que 1 hora
               or (estado = 'pendente' and origem = 'encerramento' and criado_em < now() - interval '1 hour')
           returning id, conta_id, origem, erro loop
    if e.origem = 'encerramento' then perform fn_exportacao_final_falhou(e.conta_id, e.erro); end if;
  end loop;
  if exists (select 1 from conta_exportacoes where estado = 'pronta' and expira_em <= now()) then
    perform fn_exportacao_chamar(jsonb_build_object('acao', 'limpar'));
  end if;
end $function$;

-- põe na fila e chama a Edge Function; sem URL configurada fica pendente (homologação sem a função, banco do CI)
create or replace function interno.fn_exportar_pedir(p_conta uuid, p_autor text, p_origem text)
 returns uuid
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext('exportacao:' || p_conta));
  -- o encerramento nunca é barrado pela exportação: a final sai sempre
  if p_origem <> 'encerramento' and exists (select 1 from conta_exportacoes where conta_id = p_conta and estado in ('pendente', 'gerando')
               and criado_em > now() - interval '30 minutes') then
    raise exception 'Já há uma exportação desta conta em andamento. Aguarde alguns minutos.';
  end if;
  if p_origem = 'admin' and exists (select 1 from conta_exportacoes where conta_id = p_conta and origem = 'admin'
                                      and estado = 'pronta' and criado_em > now() - interval '1 day') then
    raise exception 'Já há uma exportação de hoje. Baixe a que está pronta ou peça de novo amanhã.';
  end if;
  insert into conta_exportacoes (conta_id, pedido_por, origem) values (p_conta, p_autor, p_origem) returning id into v_id;
  perform fn_exportacao_chamar(jsonb_build_object('id', v_id));
  return v_id;
end $function$;

-- administrador da conta da sessão, sempre com as duas etapas (é a cópia de tudo)
create or replace function public.app_conta_exportar()
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_email text := app_exigir(array['admin']);
begin
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'Ative e confirme a verificação em duas etapas para exportar os dados da conta.';
  end if;
  return interno.fn_exportar_pedir(interno.fn_conta_atual(), v_email, 'admin');
end $function$;

create or replace function public.app_exportacoes()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_conta uuid;
begin
  perform app_exigir(array['admin']);
  v_conta := interno.fn_conta_atual();
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'origem', e.origem, 'estado', e.estado, 'pedido_por', e.pedido_por,
      'criado_em', e.criado_em, 'concluido_em', e.concluido_em, 'expira_em', e.expira_em, 'tamanho', e.tamanho,
      'manifesto_sha256', e.manifesto_sha256, 'erro', e.erro) order by e.criado_em desc)
    from (select * from interno.conta_exportacoes where conta_id = v_conta order by criado_em desc limit 20) e), '[]'::jsonb);
end $function$;

create or replace function public.app_plataforma_exportar_conta(p_conta uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_ator text := interno.fn_exigir_plataforma();
begin
  if not exists (select 1 from interno.contas where id = p_conta and estado in ('ativa', 'encerrada')) then
    raise exception 'Conta não encontrada ou já apagada.';
  end if;
  return interno.fn_exportar_pedir(p_conta, v_ator, 'plataforma');
end $function$;

create or replace function public.app_plataforma_exportacoes(p_conta uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform interno.fn_exigir_plataforma();
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'origem', e.origem, 'estado', e.estado, 'pedido_por', e.pedido_por,
      'criado_em', e.criado_em, 'concluido_em', e.concluido_em, 'expira_em', e.expira_em, 'tamanho', e.tamanho,
      'manifesto_sha256', e.manifesto_sha256, 'erro', e.erro) order by e.criado_em desc)
    from (select * from interno.conta_exportacoes where conta_id = p_conta order by criado_em desc limit 20) e), '[]'::jsonb);
end $function$;

-- o motor chama a manutenção das exportações (fase 8)
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
  -- F5c: fila justa; cada conta envia no máximo isto por execução (padrão: o limite geral)
  v_limite_conta int := greatest(coalesce(fn_config_int('envios_por_conta_por_execucao'), coalesce(fn_config_int('envios_por_execucao'), 3)), 1);
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
  -- F5c: rodízio entre as contas (a 1ª de cada conta, depois a 2ª...), com teto por conta
  for a in select f.* from (
             select p.*, row_number() over (partition by e.conta_id order by p.enviada_em nulls first) as ordem_conta
               from vw_acoes_pendentes p join escalas e on e.id = p.escala_id
              where p.acao in ('enviar_primeira','reenviar_falha','reenviar','nao_recebeu')
                -- sem webhook, lembrete e "não recebeu" não ocupam vaga na fila da conta
                and (v_webhook or p.acao not in ('reenviar','nao_recebeu'))) f
            where f.ordem_conta <= v_limite_conta
            order by f.ordem_conta, f.enviada_em nulls first loop
    exit when v_sent >= v_limite;
    if not v_webhook and a.acao in ('reenviar','nao_recebeu') then continue; end if;
    v_tent := coalesce(a.tentativa, 0) + 1;
    v_botoes := v_usar_botoes and a.acao <> 'reenviar_falha';
    begin
      -- F5b: a conta da escala decide o canal (o telefone é único só dentro da conta)
      perform set_config('trilha.conta', (select conta_id from escalas where id = a.escala_id)::text, true);
      v_payload := fn_payload_escala(a.escala_id, a.telefone, a.acao = 'reenviar', v_botoes);
      -- conta sem canal de WhatsApp (F5a): falha registrada, em vez de ficar enfileirada sem pedido
      if fn_evo_destino(v_payload ->> 'path', v_payload -> 'body' ->> 'number') is null then
        raise exception 'A conta do técnico não tem canal de WhatsApp ativo.';
      end if;
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
    perform set_config('trilha.conta', v_conta::text, true);
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

  perform set_config('trilha.conta', '', true);

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

  -- FASE 8: exportações das contas (F8c): retomar o que falhou ou travou e apagar os pacotes vencidos
  begin perform fn_exportacoes_manutencao();
  exception when others then raise warning 'manutencao das exportacoes falhou: %', sqlerrm; end;
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
end $function$
;

-- Edge Function: começa um pedido (pendente, ou gerando parado há mais de 15 min) e devolve o que exportar
create or replace function interno.fn_exportacao_dados(p_token text, p_id uuid)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id for update;
  if not found or e.tentativas >= 3
     or not (e.estado = 'pendente' or (e.estado = 'gerando' and e.iniciado_em < now() - interval '15 minutes')) then
    return null;
  end if;
  update conta_exportacoes set estado = 'gerando', iniciado_em = now(), tentativas = tentativas + 1 where id = p_id;
  return jsonb_build_object('conta', e.conta_id, 'origem', e.origem,
    'nome', (select nome from contas where id = e.conta_id),
    'tabelas', (select jsonb_agg(jsonb_build_object('tabela', t.tabela, 'colunas', t.colunas)) from fn_exportar_tabelas() t));
end $function$;

-- uma página de uma tabela, em linhas CSV (sem cabeçalho), só da conta do pedido, na ordem da chave primária
create or replace function interno.fn_exportar_csv(p_token text, p_id uuid, p_tabela text, p_offset int, p_limite int)
 returns text
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_conta uuid;
  t record;
  v text;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select conta_id into v_conta from conta_exportacoes where id = p_id and estado = 'gerando';
  if v_conta is null then raise exception 'exportação fora de andamento'; end if;
  select * into t from fn_exportar_tabelas() x where x.tabela = p_tabela;
  if not found then raise exception 'tabela fora da exportação'; end if;
  -- saúde com a máscara do painel: o motivo vira 'saude' e os textos da justificativa ficam vazios
  execute format('select string_agg(l, E''\n'' order by n) from (select row_number() over () as n, concat_ws('','', %s) as l
                    from (select * from interno.%I where conta_id = $1 order by %s limit $2 offset $3) z) y',
                 (select string_agg(case
                     when p_tabela = 'ponto_justificativas' and c = 'motivo'
                       then 'interno.fn_csv(case when interno.fn_motivo_saude(z.motivo) then ''saude'' else z.motivo end)'
                     when p_tabela = 'ponto_justificativas' and c in ('observacao', 'resposta', 'alerta_limite')
                       then format('interno.fn_csv(case when interno.fn_motivo_saude(z.motivo) then null else z.%I::text end)', c)
                     else format('interno.fn_csv(z.%I::text)', c) end, ', ') from unnest(t.colunas) c),
                 p_tabela,
                 (select string_agg(format('%I', c), ', ') from unnest(t.chave) c))
    into v using v_conta, least(greatest(coalesce(p_limite, 5000), 1), 20000), greatest(coalesce(p_offset, 0), 0);
  return v;
end $function$;

-- resultado: pronta (vence em 7 dias) ou falhou; na final do encerramento, o link vai aos administradores da conta
create or replace function interno.fn_exportacao_resultado(p_token text, p_id uuid, p_ok boolean, p_arquivo text, p_tamanho bigint,
                                                           p_sha text, p_erro text, p_link text default null)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes; v_para text[];
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  update conta_exportacoes set
         estado = case when p_ok then 'pronta' when tentativas >= 3 then 'falhou' else 'pendente' end,
         concluido_em = now(), expira_em = case when p_ok then now() + interval '7 days' end,
         arquivo = case when p_ok then p_arquivo end, tamanho = case when p_ok then p_tamanho end,
         manifesto_sha256 = case when p_ok then p_sha end, erro = case when p_ok then null else left(p_erro, 300) end
   where id = p_id and estado = 'gerando' returning * into e;
  if found and e.estado = 'falhou' and e.origem = 'encerramento' then perform fn_exportacao_final_falhou(e.conta_id, e.erro); end if;
  if not found or not p_ok or e.origem <> 'encerramento' or coalesce(p_link, '') !~ '^https://' then return; end if;
  select array_agg(email order by email) into v_para from conta_membros where conta_id = e.conta_id and papel = 'admin' and ativo;
  if v_para is null then return; end if;
  perform fn_alerta_email('Trilha: exportação final dos dados da sua conta',
    'A conta ' || (select nome from contas where id = e.conta_id) || ' foi encerrada no Trilha. A cópia completa dos dados '
    || 'está pronta para baixar até ' || to_char(e.expira_em at time zone coalesce(fn_config('fuso'), 'America/Bahia'), 'DD/MM/YYYY')
    || ':' || E'\n\n' || p_link || E'\n\n'
    || 'O arquivo tem uma planilha (CSV) por tabela, o dicionário dos campos (esquema.json) e o manifesto com o hash de cada '
    || 'arquivo. Os dados da conta serão apagados em ' || to_char((select apagar_em from contas where id = e.conta_id)
       at time zone coalesce(fn_config('fuso'), 'America/Bahia'), 'DD/MM/YYYY') || '. Guarde a cópia: depois disso ela não '
    || 'poderá ser gerada de novo.',
    v_para, true);
end $function$;

-- link para baixar: só quem pode (administrador ativo da conta, com duas etapas, ou a plataforma) e só antes de vencer
create or replace function interno.fn_exportacao_link(p_email text, p_aal text, p_id uuid)
 returns text
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes; v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if coalesce(p_aal, '') <> 'aal2' then raise exception 'Confirme a verificação em duas etapas para baixar.'; end if;
  select * into e from conta_exportacoes where id = p_id for update;
  if not found or not (exists (select 1 from plataforma_admins where email = v_email)
                       or exists (select 1 from conta_membros m join contas c on c.id = m.conta_id
                                   where m.conta_id = e.conta_id and m.email = v_email and m.papel = 'admin' and m.ativo and c.ativa)) then
    raise exception 'Sem permissão para esta ação.';
  end if;
  if e.estado <> 'pronta' or e.expira_em <= now() then raise exception 'Exportação vencida ou ainda não pronta.'; end if;
  update conta_exportacoes set baixadas = baixadas + 1 where id = p_id;
  return e.arquivo;
end $function$;

-- pacotes vencidos: saem da lista de prontos e a Edge Function apaga os arquivos
create or replace function interno.fn_exportacoes_vencidas(p_token text)
 returns setof text
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  return query
    update conta_exportacoes set estado = 'expirada' where estado = 'pronta' and expira_em <= now() and arquivo is not null
    returning arquivo;
end $function$;

create or replace function public.app_plataforma_encerrar_conta(p_conta uuid, p_motivo text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator   text := interno.fn_exigir_plataforma();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  c        interno.contas;
  v_sess   int;
begin
  if p_conta = '00000000-0000-0000-0000-000000000001' then
    raise exception 'A conta da operadora não pode ser encerrada.';
  end if;
  if length(v_motivo) not between 3 and 300 then
    raise exception 'Informe o motivo do encerramento (3 a 300 caracteres).';
  end if;
  select * into c from interno.contas where id = p_conta for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if c.estado <> 'ativa' then raise exception 'A conta já está encerrada.'; end if;
  update interno.contas set ativa = false, estado = 'encerrada', encerrada_em = now(), apagar_em = now() + interval '30 days'
   where id = p_conta returning * into c;
  -- app do ponto: sessões encerradas e códigos vencidos já agora
  update interno.ponto_sessoes s set encerrada_em = now(), motivo = 'conta encerrada'
    from interno.tecnicos t where t.id = s.tecnico_id and t.conta_id = p_conta and s.encerrada_em is null;
  get diagnostics v_sess = row_count;
  update interno.ponto_codigos k set expira_em = now()
    from interno.tecnicos t where t.id = k.tecnico_id and t.conta_id = p_conta and k.usado_em is null and k.expira_em > now();
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'encerrar_conta', p_conta, jsonb_build_object('motivo', v_motivo, 'apagar_em', c.apagar_em, 'sessoes_ponto', v_sess));
  -- exportação final automática (F8c, decisão 129): o link vai por e-mail aos administradores da conta
  perform interno.fn_exportar_pedir(p_conta, v_ator, 'encerramento');
  return jsonb_build_object('estado', c.estado, 'apagar_em', c.apagar_em);
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
