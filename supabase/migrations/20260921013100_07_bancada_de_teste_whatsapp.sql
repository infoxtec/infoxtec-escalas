-- 07 | Bancada de teste do WhatsApp via pg_net + Vault
-- TEMPORARIA: sera removida quando as Edge Functions do Passo 3 entrarem.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create or replace function fn_segredo(p_nome text)
returns text language sql stable security definer
set search_path = vault, public as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_nome limit 1
$$;

create or replace function fn_teste_wa_texto(
  p_para  text,
  p_texto text
) returns bigint language plpgsql volatile as $$
declare
  v_token   text := fn_segredo('WHATSAPP_TOKEN');
  v_phone   text := fn_segredo('WHATSAPP_PHONE_NUMBER_ID');
  v_req_id  bigint;
begin
  if v_token is null or v_phone is null then
    raise exception 'Faltam segredos no Vault: WHATSAPP_TOKEN e/ou WHATSAPP_PHONE_NUMBER_ID';
  end if;
  select net.http_post(
    url     := 'https://graph.facebook.com/v21.0/' || v_phone || '/messages',
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || v_token,
                 'Content-Type',  'application/json'),
    body    := jsonb_build_object(
                 'messaging_product', 'whatsapp',
                 'to', p_para,
                 'type', 'text',
                 'text', jsonb_build_object('body', p_texto))
  ) into v_req_id;
  return v_req_id;
end $$;

create or replace function fn_teste_wa_botoes(
  p_para   text,
  p_corpo  text,
  p_ref    text default 'teste'
) returns bigint language plpgsql volatile as $$
declare
  v_token  text := fn_segredo('WHATSAPP_TOKEN');
  v_phone  text := fn_segredo('WHATSAPP_PHONE_NUMBER_ID');
  v_req_id bigint;
begin
  if v_token is null or v_phone is null then
    raise exception 'Faltam segredos no Vault';
  end if;
  select net.http_post(
    url     := 'https://graph.facebook.com/v21.0/' || v_phone || '/messages',
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || v_token,
                 'Content-Type',  'application/json'),
    body    := jsonb_build_object(
      'messaging_product', 'whatsapp',
      'to', p_para,
      'type', 'interactive',
      'interactive', jsonb_build_object(
        'type', 'button',
        'body', jsonb_build_object('text', p_corpo),
        'action', jsonb_build_object('buttons', jsonb_build_array(
          jsonb_build_object('type','reply','reply',
            jsonb_build_object('id','conf:'||p_ref,'title','Ciente, confirmado')),
          jsonb_build_object('type','reply','reply',
            jsonb_build_object('id','prob:'||p_ref,'title','Tenho um problema'))
        ))
      ))
  ) into v_req_id;
  return v_req_id;
end $$;

create or replace function fn_teste_wa_resposta(p_req_id bigint)
returns table (status int, corpo jsonb)
language sql stable as $$
  select status_code, content::jsonb
  from net._http_response where id = p_req_id
$$;
