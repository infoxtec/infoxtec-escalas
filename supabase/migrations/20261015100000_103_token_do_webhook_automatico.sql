-- Migration 103: troca automática do token do webhook da Evolution (decisão 98; substitui a T09 manual).
-- Pedido do responsável (15/10): nem ele nem o cliente trocam token à mão, nunca. O banco faz a troca inteira:
--   1. gera o token novo e guarda no Vault; o anterior continua aceito por 15 minutos (sem nenhum 401 na transição)
--   2. reaponta o webhook da instância com o token novo no cabeçalho, pelo fn_evo_post (a chave da instância já está
--      no Vault; a chave global da Evolution continua só no servidor)
--   3. a cada 5 minutos (dentro da vigia do motor, que já roda): confere a resposta da Evolution; deu certo, apaga a
--      resposta guardada (ela repete o token) e, vencidos os 15 minutos, apaga o token anterior; deu errado, volta ao
--      token anterior, reaponta o webhook para ele e avisa o suporte
--   4. troca na primeira passada depois desta migration (é a T09: o token que já esteve em URL sai de circulação) e
--      depois sozinha a cada webhook_token_dias (90 por padrão)
-- Recriadas a partir da definição atual da homologação: fn_webhook_evolution (md5 c4313e009f686900775ad19bd4cfdde0)
-- e fn_vigiar_motor (md5 73aa9928485b2725edad1d9815cc52dc).

-- Histórico das trocas ------------------------------------------------------------------------------------
create table if not exists webhook_token_trocas (
  id            bigint generated always as identity primary key,
  motivo        text not null check (motivo in ('primeira', 'agendada', 'manual', 'reversao')),
  iniciada_em   timestamptz not null default now(),
  requisicao    bigint,                         -- id do pedido ao pg_net (net._http_response)
  anterior_ate  timestamptz not null,           -- até quando o token anterior ainda é aceito
  confirmada_em timestamptz,
  falhou_em     timestamptz,
  falha         text check (length(falha) <= 300)
);
alter table webhook_token_trocas enable row level security;
-- uma troca em andamento por vez (segunda barreira, além da trava de sessão)
create unique index if not exists webhook_token_trocas_uma_aberta on webhook_token_trocas ((true))
  where confirmada_em is null and falhou_em is null;
-- aviso ao suporte quando a manutenção do token não consegue rodar: no máximo um por dia
alter table motor_estado add column if not exists token_alerta_em date;
comment on table webhook_token_trocas is 'Trocas automáticas do token do webhook da Evolution (decisão 98); sem o valor do token';

insert into config (chave, valor, descricao) values
  ('webhook_token_dias', '90', 'Dias entre trocas automáticas do token do webhook (decisão 98)')
on conflict (chave) do nothing;

-- Grava o token do webhook no Vault (cria ou troca o valor); só esses dois nomes ---------------------------
create or replace function fn_segredo_gravar(p_nome text, p_valor text)
returns void language plpgsql set search_path = public, extensions as $$
declare v_id uuid;
begin
  if p_nome not in ('WEBHOOK_TOKEN', 'WEBHOOK_TOKEN_ANTERIOR') then raise exception 'segredo não permitido'; end if;
  select id into v_id from vault.secrets where name = p_nome;
  if v_id is null then
    perform vault.create_secret(p_valor, p_nome);
  else
    perform vault.update_secret(v_id, p_valor);
  end if;
end $$;

-- O token que chega é o atual, ou o anterior: dentro da janela ou enquanto a troca não foi confirmada. Fecha em
-- falso (sem token no Vault, ou nulo em qualquer ponta, recusa); compara resumos, não os valores
create or replace function fn_webhook_token_ok(p_token text)
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
           coalesce(p_token, '') <> ''
           and (extensions.digest(p_token, 'sha256') = extensions.digest(fn_segredo('WEBHOOK_TOKEN'), 'sha256')
                or (extensions.digest(p_token, 'sha256') = extensions.digest(fn_segredo('WEBHOOK_TOKEN_ANTERIOR'), 'sha256')
                    and exists (select 1 from webhook_token_trocas
                                 where anterior_ate > now() or (confirmada_em is null and falhou_em is null)))),
           false)
$$;

-- Reaponta o webhook da instância com o token dado (o valor nunca vai para log nem tabela) -----------------
create or replace function fn_webhook_apontar(p_token text)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_req bigint;
begin
  if coalesce(fn_config('webhook_url'), '') = '' then raise exception 'webhook_url não configurada'; end if;
  if fn_config('webhook_url') like '%?%' then raise exception 'webhook_url não pode ter parâmetros (o token vai só no cabeçalho)'; end if;
  v_req := fn_evo_post('/webhook/set/' || fn_config('evolution_instancia'),
    jsonb_build_object('webhook', jsonb_build_object(
      'enabled', true, 'url', fn_config('webhook_url'),
      'headers', jsonb_build_object('x-webhook-token', p_token),
      'byEvents', false, 'base64', false,
      'events', jsonb_build_array('MESSAGES_UPSERT', 'MESSAGES_UPDATE'))));
  if v_req is null then raise exception 'pedido à Evolution não foi feito'; end if;
  return v_req;
end $$;

-- Troca o token: o novo vale já; o anterior, por mais 15 minutos -------------------------------------------
create or replace function fn_webhook_token_trocar(p_motivo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_atual text := fn_segredo('WEBHOOK_TOKEN');
  v_novo  text := encode(extensions.gen_random_bytes(32), 'hex');
  v_req   bigint;
  v_id    bigint;
begin
  -- uma troca por vez, mesmo com duas vigias ou uma chamada manual ao mesmo tempo
  if not pg_try_advisory_xact_lock(hashtext('webhook_token')) then return jsonb_build_object('situacao', 'ocupada'); end if;
  if v_atual is null then raise exception 'WEBHOOK_TOKEN não está no Vault: o webhook ainda não foi configurado'; end if;
  if exists (select 1 from webhook_token_trocas where confirmada_em is null and falhou_em is null) then
    return jsonb_build_object('situacao', 'troca em andamento');
  end if;
  perform fn_segredo_gravar('WEBHOOK_TOKEN_ANTERIOR', v_atual);
  perform fn_segredo_gravar('WEBHOOK_TOKEN', v_novo);
  v_req := fn_webhook_apontar(v_novo);
  insert into webhook_token_trocas (motivo, requisicao, anterior_ate)
  values (p_motivo, v_req, now() + interval '15 minutes') returning id into v_id;
  return jsonb_build_object('situacao', 'iniciada', 'troca', v_id);
end $$;

-- Manutenção, a cada 5 minutos: confere, desfaz se falhou, limpa e troca quando vence -----------------------
create or replace function fn_webhook_token_manutencao()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  t      webhook_token_trocas;
  v_st   int;
  v_ok   boolean;
  v_falha text;
  v_ant  text;
  v_req  bigint;
  v_dias int := greatest(coalesce(nullif(fn_config('webhook_token_dias'), '')::int, 90), 7);
begin
  if not pg_try_advisory_xact_lock(hashtext('webhook_token')) then return jsonb_build_object('situacao', 'ocupada'); end if;
  if coalesce(fn_config('evolution_instancia'), '') = '' or fn_segredo('WEBHOOK_TOKEN') is null then
    return jsonb_build_object('situacao', 'webhook não configurado');
  end if;

  -- 1. troca em andamento: a Evolution respondeu?
  select * into t from webhook_token_trocas where confirmada_em is null and falhou_em is null order by id desc limit 1;
  if found then
    select status_code, (status_code between 200 and 299), left(coalesce(error_msg, ''), 200)
      into v_st, v_ok, v_falha from net._http_response where id = t.requisicao;
    if v_ok then
      -- a janela do anterior conta da confirmação (a Evolution pode ter mandado eventos com ele até aqui)
      update webhook_token_trocas set confirmada_em = now(), anterior_ate = now() + interval '15 minutes' where id = t.id;
      delete from net._http_response where id = t.requisicao;   -- a resposta repete o cabeçalho com o token
      return jsonb_build_object('situacao', 'confirmada', 'troca', t.id);
    end if;
    if v_st is null and t.iniciada_em > now() - interval '10 minutes' then
      return jsonb_build_object('situacao', 'aguardando resposta', 'troca', t.id);
    end if;
    -- falhou (ou sem resposta em 10 min): volta ao token anterior e reaponta o webhook para ele; o novo continua
    -- aceito por um dia, para o caso de a Evolution ter gravado e a resposta ter se perdido
    update webhook_token_trocas
       set falhou_em = now(), falha = coalesce('HTTP ' || v_st, 'sem resposta em 10 min') || nullif(' ' || v_falha, ' ')
     where id = t.id;
    delete from net._http_response where id = t.requisicao;
    if t.motivo <> 'reversao' then
      v_ant := fn_segredo('WEBHOOK_TOKEN_ANTERIOR');
      perform fn_segredo_gravar('WEBHOOK_TOKEN_ANTERIOR', fn_segredo('WEBHOOK_TOKEN'));
      perform fn_segredo_gravar('WEBHOOK_TOKEN', v_ant);
      v_req := fn_webhook_apontar(v_ant);
      insert into webhook_token_trocas (motivo, requisicao, anterior_ate) values ('reversao', v_req, now() + interval '1 day');
    else
      -- a volta também falhou: os dois tokens seguem aceitos por 7 dias e o suporte resolve
      update webhook_token_trocas set anterior_ate = greatest(anterior_ate, now() + interval '7 days') where id = t.id;
    end if;
    perform fn_avisar_tecnico('⚠️ *TOKEN DO WEBHOOK*' || E'\n\n'
      || 'A troca automática do token do webhook da Evolution não foi confirmada ('
      || coalesce('HTTP ' || v_st, 'sem resposta') || ').' || E'\n'
      || case when t.motivo <> 'reversao' then 'O sistema voltou ao token anterior sozinho; nada parou.'
              else 'A volta ao token anterior também falhou: os dois tokens seguem aceitos. Acione o suporte.' end);
    return jsonb_build_object('situacao', 'falhou', 'troca', t.id);
  end if;

  -- 2. passou a janela: o token anterior sai do Vault
  if not exists (select 1 from webhook_token_trocas where anterior_ate > now())
     and exists (select 1 from vault.secrets where name = 'WEBHOOK_TOKEN_ANTERIOR') then
    delete from vault.secrets where name = 'WEBHOOK_TOKEN_ANTERIOR';
  end if;

  -- 3. primeira troca (T09) ou troca vencida. Volta ao anterior que também falhou: os dois seguem aceitos e nada
  -- novo começa até o suporte resolver; outra falha: espera um dia (um alerta, não um por passada)
  if exists (select 1 from webhook_token_trocas where motivo = 'reversao' and falhou_em is not null and anterior_ate > now()) then
    return jsonb_build_object('situacao', 'aguardando suporte');
  end if;
  if exists (select 1 from webhook_token_trocas where falhou_em > now() - interval '1 day') then
    return jsonb_build_object('situacao', 'aguardando um dia depois de falha');
  end if;
  if not exists (select 1 from webhook_token_trocas where confirmada_em is not null and motivo <> 'reversao') then
    return fn_webhook_token_trocar('primeira');
  end if;
  if (select max(confirmada_em) from webhook_token_trocas) < now() - make_interval(days => v_dias) then
    return fn_webhook_token_trocar('agendada');
  end if;
  return jsonb_build_object('situacao', 'em dia');
end $$;

-- Webhook: aceita o token atual ou o anterior na janela da troca ------------------------------------------
create or replace function fn_webhook_evolution(p_token text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $function$
declare
  v_log    bigint;
  v_evento text := lower(replace(coalesce(p_payload->>'event', ''), '_', '.'));
  v_res    jsonb;
  v_pl     jsonb := p_payload - 'apikey';
  v_msg    jsonb;
  v_permitidas text[] := array['conversation', 'extendedTextMessage', 'buttonsResponseMessage', 'templateButtonReplyMessage',
                               'interactiveResponseMessage', 'listResponseMessage', 'messageContextInfo', 'localizacao',
                               'reactionMessage', 'protocolMessage'];
begin
  if not fn_webhook_token_ok(p_token) then
    raise exception 'token invalido';
  end if;

  -- LGPD: a localização do ponto já fica na marcação; o log do webhook não guarda outra cópia
  if v_pl->'data'->'message' ?| array['locationMessage', 'liveLocationMessage'] then
    v_pl := jsonb_set(v_pl, '{data,message}',
      ((v_pl->'data'->'message') - 'locationMessage' - 'liveLocationMessage') || '{"localizacao": true}');
  end if;
  -- LGPD (decisão 56): o log guarda só texto, botão e a marca da localização (tirada acima). Foto, vídeo,
  -- áudio, arquivo, mensagem temporária ou de visualização única e a mensagem citada saem (miniatura,
  -- legenda, URL e chave da mídia); fica só a marca "midia"
  if jsonb_typeof(v_pl->'data'->'message') = 'object' then
    select coalesce(jsonb_object_agg(e.k, case when e.k = 'extendedTextMessage' then e.v #- '{contextInfo,quotedMessage}' else e.v end), '{}')
      into v_msg
      from jsonb_each(v_pl->'data'->'message') e(k, v)
     where e.k = any(v_permitidas);
    if exists (select 1 from jsonb_object_keys(v_pl->'data'->'message') k where k <> all(v_permitidas)) then
      v_msg := v_msg || '{"midia": true}';
    end if;
    v_pl := jsonb_set(v_pl, '{data,message}', v_msg);
  end if;
  v_pl := v_pl #- '{data,contextInfo,quotedMessage}';
  insert into webhook_eventos (evento, payload)
  values (v_evento, v_pl)
  returning id into v_log;

  begin
    if v_evento = 'messages.update' then
      v_res := fn_wh_status(p_payload->'data');
    elsif v_evento = 'messages.upsert' then
      begin
        v_res := fn_ponto_wh(p_payload->'data');
      exception when others then
        -- falha no ponto não pode derrubar a resposta das escalas
        v_res := null;
        raise warning 'ponto: %', sqlerrm;
      end;
      if v_res is null then
        v_res := fn_wh_mensagem(p_payload->'data');
      end if;
    else
      v_res := jsonb_build_object('ignorado', v_evento);
    end if;
    update webhook_eventos set resultado = v_res::text where id = v_log;
  exception when others then
    update webhook_eventos set resultado = 'ERRO: ' || sqlerrm where id = v_log;
    v_res := jsonb_build_object('erro', sqlerrm);
  end;

  return v_res;
end $function$;

-- Vigia do motor: passa também pela manutenção do token (a falha dela nunca derruba a vigia) -----------------
create or replace function fn_vigiar_motor()
returns jsonb language plpgsql security definer set search_path = public, extensions as $function$
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
  -- token do webhook (decisão 98): troca, confere e limpa sozinho
  begin
    perform fn_webhook_token_manutencao();
  exception when others then
    raise warning 'token do webhook: %', sqlerrm;
    -- o suporte fica sabendo, no máximo uma vez por dia
    update motor_estado set token_alerta_em = current_date where id and token_alerta_em is distinct from current_date;
    if found then
      perform fn_avisar_tecnico('⚠️ *TOKEN DO WEBHOOK*' || E'\n\n'
        || 'A troca automática do token do webhook não conseguiu rodar: ' || left(sqlerrm, 150) || E'\n'
        || 'O WhatsApp segue com o token atual. Acione o suporte.');
    end if;
  end;

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
      || 'Programações, lembretes e alertas não estão saindo. Acione o suporte.';
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
      || 'Confira no painel as programações do período parado.';
    perform fn_avisar_supervisores(v_texto);
    perform fn_avisar_tecnico(v_texto);
    update motor_estado set alerta_enviado_em = null, atualizado_em = now() where id;
    return jsonb_build_object('situacao', 'normalizado', 'alerta', 'enviado');
  end if;

  return jsonb_build_object('situacao', 'em dia', 'minutos', v_min);
end $function$;

-- Permissões por laço (decisão 12) ----------------------------------------------------------------
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
