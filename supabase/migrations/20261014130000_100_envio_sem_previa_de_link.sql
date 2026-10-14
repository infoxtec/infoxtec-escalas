-- Migration 100: envio de texto pelo WhatsApp sem prévia de link (decisão 95).
-- Na homologação, mensagem com link e prévia ficou só com o aceite do servidor do WhatsApp (SERVER_ACK) e nunca chegou
-- ao celular; a mesma mensagem sem a prévia chegou e foi lida (teste de 14/10 com a Evolution 2.4.0-rc2). Sem isso, o
-- espelho de ponto não chega para assinatura. fn_evo_post é o único ponto de envio: todo sendText sai com
-- linkPreview = false, salvo quem pedir a prévia de forma explícita.
-- Recriada a partir da definição atual da homologação (md5 d4268addcd92e553b7e5fe4562f2a2e8, migration 99).

create or replace function fn_evo_post(p_path text, p_body jsonb)
returns bigint language plpgsql
set search_path = public, extensions as $$
declare
  v_key  text;
  v_num  text := p_body ->> 'number';
  v_inst text := fn_config('evolution_instancia');
  v_homo boolean := coalesce(fn_config('ambiente'), 'producao') = 'homologacao';
  v_body jsonb := p_body;
begin
  -- instância: o caminho termina nela; homologação só pela dela, produção nunca pela da homologação
  if v_inst is null or v_inst = '' or right(p_path, length(v_inst) + 1) <> '/' || v_inst then
    raise exception 'Envio recusado: o caminho não é da instância configurada (%).', coalesce(v_inst, 'nenhuma');
  end if;
  if v_homo and v_inst <> 'trilha-homologacao' then
    raise exception 'Envio recusado: a homologação só usa a instância trilha-homologacao.';
  end if;
  if not v_homo and v_inst = 'trilha-homologacao' then
    raise exception 'Envio recusado: a instância trilha-homologacao não serve à produção.';
  end if;
  if v_homo and p_path like '/message/%' and v_num is null then
    raise exception 'Envio recusado: mensagem sem destinatário na homologação.';
  end if;

  v_key := fn_segredo('EVOLUTION_API_KEY');
  if v_key is null then
    raise exception 'EVOLUTION_API_KEY nao encontrada no Vault';
  end if;

  if v_num is not null and not fn_pode_enviar(v_num) then
    raise warning 'HOMOLOGACAO: envio bloqueado para % (numero fora de telefones_homologacao)', v_num;
    return null;
  end if;

  -- texto com prévia de link não é entregue (decisão 95): desliga, salvo pedido explícito
  if p_path like '/message/sendText/%' and not (v_body ? 'linkPreview') then
    v_body := v_body || jsonb_build_object('linkPreview', false);
  end if;

  return net.http_post(
    url     := fn_config('evolution_url') || p_path,
    headers := jsonb_build_object('apikey', v_key, 'Content-Type', 'application/json'),
    body    := v_body
  );
end $$;

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
