-- Alerta por e-mail quando o WhatsApp (Evolution) cai (pedido do responsável em 30/10, depois da queda das duas
-- instâncias). O vigia do motor (a cada 5 min) passa a perguntar à Evolution o estado da instância; com a instância
-- fora de "open" em duas verificações seguidas, sai um e-mail para a plataforma, e outro quando ela volta. O e-mail não
-- pode depender do próprio WhatsApp: sai pela Edge Function alerta-email, pela caixa SMTP da hospedagem (decisão 123).

set lock_timeout = '5s';

-- estado do vigia (uma linha só)
create table interno.evolution_vigia (
  id boolean primary key default true check (id),
  req_id bigint,                 -- pedido do pg_net em andamento (a resposta é lida na volta seguinte)
  estado text,                   -- último estado lido: open, connecting, close ou sem_resposta
  falhas int not null default 0, -- verificações seguidas fora de "open"
  fora_desde timestamptz,
  alertado_em timestamptz,       -- e-mail de queda enviado; limpo quando o de volta sai
  verificado_em timestamptz
);
alter table interno.evolution_vigia enable row level security;

-- fila dos e-mails de alerta (guarda 90 dias)
create table interno.alertas_email (
  id bigint generated always as identity primary key,
  assunto text not null check (length(assunto) between 3 and 150),
  texto text not null check (length(texto) between 3 and 4000),
  criado_em timestamptz not null default now(),
  enviado_em timestamptz,
  erro text,
  tentativas int not null default 0
);
alter table interno.alertas_email enable row level security;
create index alertas_email_criado_idx on interno.alertas_email (criado_em desc);

insert into interno.config (chave, valor, descricao) values
  ('evolution_alerta_falhas', '2', 'Verificações seguidas (a cada 5 min) com o WhatsApp fora do ar antes do e-mail de alerta'),
  ('alerta_emails', '', 'E-mails extras do alerta, separados por vírgula (a plataforma sempre recebe)'),
  ('alerta_smtp_host', 'emailssl-vip.uni5.net', 'Servidor SMTP do alerta (a senha fica no segredo ALERTA_SMTP_SENHA da Edge Function)'),
  ('alerta_smtp_porta', '465', 'Porta do SMTP do alerta (465, SSL: a Edge Function não sai pela 587)'),
  ('alerta_smtp_usuario', 'trilha@infoxtec.com.br', 'Usuário e remetente do SMTP do alerta')
on conflict (chave) do nothing;
insert into interno.config (chave, valor, descricao)
select 'alerta_email_url', replace(c.valor, '/espelho-pdf', '/alerta-email'), 'Edge Function que manda os e-mails de alerta'
  from interno.config c where c.chave = 'espelho_pdf_url'
on conflict (chave) do nothing;


CREATE OR REPLACE FUNCTION interno.fn_segredo_gravar(p_nome text, p_valor text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  if p_nome not in ('WEBHOOK_TOKEN', 'WEBHOOK_TOKEN_ANTERIOR', 'ESPELHO_PDF_TOKEN', 'ALERTA_EMAIL_TOKEN') then raise exception 'segredo não permitido'; end if;
  select id into v_id from vault.secrets where name = p_nome;
  if v_id is null then
    perform vault.create_secret(p_valor, p_nome);
  else
    perform vault.update_secret(v_id, p_valor);
  end if;
end $function$
;

create or replace function interno.fn_alerta_email_token_ok(p_token text)
 returns boolean
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v text := fn_segredo('ALERTA_EMAIL_TOKEN');
begin
  return v is not null and coalesce(p_token, '') <> ''
         and extensions.digest(p_token, 'sha256') = extensions.digest(v, 'sha256');
end $function$;

-- põe o e-mail na fila e chama a Edge Function (sem URL configurada, fica só na fila)
create or replace function interno.fn_alerta_email(p_assunto text, p_texto text)
 returns bigint
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_url text := nullif(trim(coalesce(fn_config('alerta_email_url'), '')), '');
  v_tok text;
  v_id  bigint;
begin
  delete from alertas_email where criado_em < now() - interval '90 days';
  insert into alertas_email (assunto, texto) values (left(p_assunto, 150), left(p_texto, 4000)) returning id into v_id;
  if v_url is null then return v_id; end if;
  perform pg_advisory_xact_lock(hashtext('alerta_email_token'));
  v_tok := fn_segredo('ALERTA_EMAIL_TOKEN');
  if v_tok is null then
    v_tok := encode(extensions.gen_random_bytes(32), 'hex');
    perform fn_segredo_gravar('ALERTA_EMAIL_TOKEN', v_tok);
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-alerta-token', v_tok),
    body := jsonb_build_object('id', v_id),
    timeout_milliseconds := 30000);
  return v_id;
end $function$;

-- o que a Edge Function manda: assunto, texto, destinatários (plataforma + extras) e o SMTP (sem a senha)
create or replace function interno.fn_alerta_email_dados(p_token text, p_id bigint)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare a alertas_email;
begin
  if not fn_alerta_email_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into a from alertas_email where id = p_id for update;
  if not found or a.enviado_em is not null or a.tentativas >= 3 then return null; end if;
  update alertas_email set tentativas = tentativas + 1 where id = p_id;
  return jsonb_build_object(
    'assunto', a.assunto, 'texto', a.texto,
    'para', (select coalesce(jsonb_agg(distinct e), '[]'::jsonb) from (
               select lower(btrim(email)) e from plataforma_admins
               union select lower(btrim(x)) from unnest(string_to_array(coalesce(fn_config('alerta_emails'), ''), ',')) x
                      where btrim(x) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') d),
    'smtp', jsonb_build_object('host', fn_config('alerta_smtp_host'), 'porta', fn_config('alerta_smtp_porta'),
                               'usuario', fn_config('alerta_smtp_usuario')));
end $function$;

create or replace function interno.fn_alerta_email_resultado(p_token text, p_id bigint, p_ok boolean, p_erro text)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not fn_alerta_email_token_ok(p_token) then raise exception 'token inválido'; end if;
  update alertas_email set enviado_em = case when p_ok then now() end, erro = case when p_ok then null else left(p_erro, 300) end
   where id = p_id and enviado_em is null;
end $function$;

-- vigia da Evolution: lê a resposta do pedido anterior, conta as falhas, avisa na queda e na volta, e faz o pedido novo
create or replace function interno.fn_vigiar_evolution()
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v       evolution_vigia;
  v_resp  record;
  v_estado text;
  v_limite int := greatest(coalesce(fn_config_int('evolution_alerta_falhas'), 2), 1);
  v_inst  text := fn_config('evolution_instancia');
  v_fuso  text := coalesce(fn_config('fuso'), 'America/Bahia');
  v_manager text := rtrim(coalesce(fn_config('evolution_url'), ''), '/') || '/manager';
begin
  if nullif(fn_config('evolution_url'), '') is null or nullif(v_inst, '') is null then
    return jsonb_build_object('situacao', 'sem evolution configurada');
  end if;
  insert into evolution_vigia (id) values (true) on conflict (id) do nothing;
  select * into v from evolution_vigia where id for update;

  if v.req_id is not null then
    select r.status_code, r.content, r.timed_out, r.error_msg into v_resp from net._http_response r where r.id = v.req_id;
    if found then
      begin
        v_estado := case when v_resp.status_code = 200 then coalesce(
                      (v_resp.content::jsonb #>> '{instance,state}'), (v_resp.content::jsonb ->> 'state'), 'desconhecido')
                    else 'sem_resposta' end;
      exception when others then
        v_estado := 'sem_resposta';   -- resposta que não é JSON
      end;
    elsif v.verificado_em < now() - interval '4 minutes' then
      v_estado := 'sem_resposta';   -- o pg_net já descartou a resposta ou nunca respondeu
    end if;
  end if;

  if v_estado is not null then
    if v_estado = 'open' then
      if v.alertado_em is not null then
        perform fn_alerta_email('Trilha: WhatsApp de volta',
          'O WhatsApp do Trilha (instância ' || v_inst || ') voltou a funcionar às '
          || to_char(now() at time zone v_fuso, 'DD/MM HH24:MI') || '.' || E'\n'
          || 'Ficou fora desde ' || to_char(v.fora_desde at time zone v_fuso, 'DD/MM HH24:MI') || '. '
          || 'Confira no painel as programações e os avisos desse período.');
      end if;
      update evolution_vigia set estado = v_estado, falhas = 0, fora_desde = null, alertado_em = null where id;
    else
      update evolution_vigia set estado = v_estado, falhas = falhas + 1, fora_desde = coalesce(fora_desde, now()) where id
        returning * into v;
      if v.falhas >= v_limite and v.alertado_em is null then
        perform fn_alerta_email('Trilha: WhatsApp fora do ar',
          'O WhatsApp do Trilha (instância ' || v_inst || ') está fora do ar desde '
          || to_char(v.fora_desde at time zone v_fuso, 'DD/MM HH24:MI') || ' (estado: ' || v_estado || ').' || E'\n\n'
          || 'Enquanto isso, programações, confirmações e avisos pelo WhatsApp não saem.' || E'\n\n'
          || 'Como resolver: abra ' || v_manager || ', entre na instância ' || v_inst
          || ' e leia o QR code com o WhatsApp do celular da operação. Se a página não abrir, o servidor da Evolution '
          || 'está fora: acione o suporte.' || E'\n\n'
          || 'Quando voltar, você recebe outro e-mail.');
        update evolution_vigia set alertado_em = now() where id;
      end if;
    end if;
  end if;

  update evolution_vigia set req_id = fn_evo_get('/instance/connectionState/' || v_inst), verificado_em = now() where id;
  return jsonb_build_object('estado', coalesce(v_estado, v.estado), 'falhas', (select falhas from evolution_vigia where id));
end $function$;

-- teste do alerta pela tela Contas (só a plataforma)
create or replace function public.app_plataforma_testar_alerta()
 returns bigint
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_ator text := interno.fn_exigir_plataforma();
begin
  if exists (select 1 from interno.alertas_email where assunto like 'Trilha: teste%' and criado_em > now() - interval '2 minutes') then
    raise exception 'Teste enviado há pouco. Aguarde 2 minutos.';
  end if;
  return interno.fn_alerta_email('Trilha: teste do alerta por e-mail',
    'Este é um teste pedido por ' || v_ator || '. Se chegou, os alertas de queda do WhatsApp vão chegar aqui também.');
end $function$;

-- últimos alertas e o estado do vigia (tela Contas)
create or replace function public.app_plataforma_alertas()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform interno.fn_exigir_plataforma();
  return jsonb_build_object(
    'vigia', (select jsonb_build_object('estado', estado, 'falhas', falhas, 'fora_desde', fora_desde, 'verificado_em', verificado_em)
                from interno.evolution_vigia where id),
    'alertas', coalesce((select jsonb_agg(jsonb_build_object('assunto', a.assunto, 'criado_em', a.criado_em,
                                  'enviado_em', a.enviado_em, 'erro', a.erro) order by a.criado_em desc)
                           from (select * from interno.alertas_email order by criado_em desc limit 10) a), '[]'::jsonb));
end $function$;


-- o vigia do motor (a cada 5 min) chama o vigia da Evolution; o resto igual à definição da homologação
CREATE OR REPLACE FUNCTION interno.fn_vigiar_motor()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  -- WhatsApp fora do ar: e-mail para a plataforma (migration 135); falha aqui não para o vigia do motor
  begin
    perform fn_vigiar_evolution();
  exception when others then
    raise warning 'vigia da evolution: %', sqlerrm;
  end;

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
end $function$
;


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
