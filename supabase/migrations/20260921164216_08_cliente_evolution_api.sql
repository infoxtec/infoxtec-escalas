-- 08 | Cliente da Evolution API (pg_net + Vault)

insert into config (chave, valor, descricao) values
  ('evolution_url', 'https://evo.vluma.com.br', 'URL base da Evolution API, sem barra no final')
on conflict (chave) do update set valor = excluded.valor;

create or replace function fn_evo_get(p_path text)
returns bigint language plpgsql volatile as $$
declare
  v_key text := fn_segredo('EVOLUTION_API_KEY');
begin
  if v_key is null then
    raise exception 'EVOLUTION_API_KEY nao encontrada no Vault';
  end if;
  return net.http_get(
    url     := fn_config('evolution_url') || p_path,
    headers := jsonb_build_object('apikey', v_key)
  );
end $$;

create or replace function fn_evo_post(p_path text, p_body jsonb)
returns bigint language plpgsql volatile as $$
declare
  v_key text := fn_segredo('EVOLUTION_API_KEY');
begin
  if v_key is null then
    raise exception 'EVOLUTION_API_KEY nao encontrada no Vault';
  end if;
  return net.http_post(
    url     := fn_config('evolution_url') || p_path,
    headers := jsonb_build_object('apikey', v_key, 'Content-Type', 'application/json'),
    body    := p_body
  );
end $$;

create or replace function fn_http_resposta(p_req_id bigint)
returns table (status int, corpo text, erro text)
language sql stable as $$
  select status_code, content, error_msg
  from net._http_response where id = p_req_id
$$;
