-- WhatsApp na HOMOLOGAÇÃO (decisão 94). Só no projeto infoxtec-escalas-dev (SQL Editor).
-- Script de uma vez só: sai do repositório depois de aplicado (CLAUDE.md).
--
-- Antes: instância "trilha-homologacao" criada e conectada na Evolution da Oracle
-- (https://163-176-68-206.sslip.io/manager) com o número de teste. Nunca a instância "infoxtec" (produção).
--
-- 1) Troque os NÚMEROS abaixo (só dígitos, com 55 e DDD) e rode este arquivo inteiro.
--    - v_testadores: quem vai testar; só esses números recebem mensagem (trava de envio, decisão 44).
--    - os três primeiros viram os telefones de Ana Souza, Bruno Lima e Carla Dias (supervisora) da carga geral.
do $$
declare
  v_testadores text[] := array['55DDDNUMERO1', '55DDDNUMERO2', '55DDDNUMERO3'];
  v_n text;
  i int := 0;
begin
  if coalesce(fn_config('ambiente'), 'producao') <> 'homologacao' then
    raise exception 'Este banco não é a homologação. Nada foi alterado.';
  end if;
  foreach v_n in array v_testadores loop
    if v_n !~ '^55[1-9][0-9]{9,10}$' then
      raise exception 'Número inválido ou não trocado: %. Use só dígitos, com 55 e DDD.', v_n;
    end if;
  end loop;

  insert into config (chave, valor, descricao) values
    ('evolution_url', 'https://163-176-68-206.sslip.io', 'URL base da Evolution API, sem barra no final'),
    ('evolution_instancia', 'trilha-homologacao', 'Instância da Evolution deste ambiente (decisão 94)'),
    ('webhook_url', 'https://oruwnlxyvznpigbpjjbx.supabase.co/functions/v1/webhook-evolution', 'URL do webhook deste projeto'),
    ('webhook_ativo', 'true', 'Respostas pelo webhook'),
    ('ligacao_ativa', 'false', 'Ligação automática desligada na homologação (decisão 94)'),
    ('telefones_homologacao', array_to_string(v_testadores, ','), 'Números liberados na homologação (decisão 44)')
  on conflict (chave) do update set valor = excluded.valor;

  -- os testadores entram no lugar dos telefones fictícios (DDD 00) de três funcionários da carga geral
  foreach v_n in array v_testadores[1:3] loop
    i := i + 1;
    update tecnicos set telefone_e164 = v_n, opt_in = true
     where telefone_e164 = '55009000091' || lpad(i::text, 2, '0');
  end loop;
  raise notice 'Configurado: instância trilha-homologacao, % números liberados, % funcionários com WhatsApp.',
    cardinality(v_testadores), (select count(*) from tecnicos where opt_in);
end $$;

-- 2) Segredos da instância de homologação — rode separado, trocando TOKEN_DA_INSTANCIA pelo token da
--    "trilha-homologacao" (Manager → instância). Nunca o da "infoxtec". Esperado: duas linhas com um id.
-- select vault.create_secret('TOKEN_DA_INSTANCIA', 'EVOLUTION_API_KEY');
-- select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'WEBHOOK_TOKEN');

-- 3) Apontar o webhook da instância para a homologação (depois do passo 2 e do deploy do webhook-evolution).
--    Esperado: um número. Depois apague a resposta, que guarda o token: delete from net._http_response where id = N;
-- select fn_evo_post('/webhook/set/' || fn_config('evolution_instancia'),
--   jsonb_build_object('webhook', jsonb_build_object(
--     'enabled', true, 'url', fn_config('webhook_url'),
--     'headers', jsonb_build_object('x-webhook-token', fn_segredo('WEBHOOK_TOKEN')),
--     'byEvents', false, 'base64', false,
--     'events', jsonb_build_array('MESSAGES_UPSERT', 'MESSAGES_UPDATE')))) as numero_da_requisicao;
