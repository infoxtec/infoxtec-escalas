-- Migration 99: trava de envio endurecida para o WhatsApp da homologação (decisão 94, revisão do seguranca).
-- 1) fn_pode_enviar: na homologação só a lista telefones_homologacao libera envio (muda só por SQL). Antes, qualquer
--    técnico marcado como teste liberava o próprio número — e essa marca se edita no painel.
-- 2) fn_evo_post: falha fechada. O caminho precisa terminar na instância configurada; a homologação só fala pela
--    instância trilha-homologacao e a produção nunca por ela; na homologação, /message/* sem destinatário é recusado.
-- Na produção o comportamento de envio não muda (fn_pode_enviar segue liberando tudo).
-- Recriadas a partir da definição atual da homologação (md5 1a03197e3d9d0108efee48e83f5c04bb e
-- dc87715a7f60ba7d4b0cae7440a05f81, migration 39).

create or replace function fn_pode_enviar(p_telefone text)
returns boolean language plpgsql stable
set search_path = public, extensions as $$
declare
  v_tel   text := fn_tel_canonico(p_telefone);
  v_lista text := coalesce(fn_config('telefones_homologacao'), '');
begin
  if coalesce(fn_config('ambiente'), 'producao') <> 'homologacao' then
    return true;
  end if;
  -- só números liberados na configuração (decisão 94); a marca de teste do técnico não libera mais
  return exists (
    select 1 from unnest(string_to_array(v_lista, ',')) x
    where fn_tel_canonico(trim(x)) = v_tel and trim(x) <> '');
end $$;

create or replace function fn_evo_post(p_path text, p_body jsonb)
returns bigint language plpgsql
set search_path = public, extensions as $$
declare
  v_key  text;
  v_num  text := p_body ->> 'number';
  v_inst text := fn_config('evolution_instancia');
  v_homo boolean := coalesce(fn_config('ambiente'), 'producao') = 'homologacao';
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

  return net.http_post(
    url     := fn_config('evolution_url') || p_path,
    headers := jsonb_build_object('apikey', v_key, 'Content-Type', 'application/json'),
    body    := p_body
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
