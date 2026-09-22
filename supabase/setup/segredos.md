# Segredos (Supabase Vault)

Nenhum valor fica neste repositorio. Cadastre no Vault (Project Settings > Vault) ou pelo SQL Editor:

| Nome | O que e | Como gerar |
|---|---|---|
| `EVOLUTION_API_KEY` | API key da **instancia** na Evolution (nao a global) | Manager da Evolution |
| `WEBHOOK_TOKEN` | Token da URL do webhook | `select vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'), 'WEBHOOK_TOKEN');` |

Depois de criar o `WEBHOOK_TOKEN`, aponte a Evolution para o webhook sem expor o token:

```sql
select fn_evo_post(
  '/webhook/set/' || fn_config('evolution_instancia'),
  jsonb_build_object('webhook', jsonb_build_object(
    'enabled', true,
    'url', fn_config('webhook_url') || '?token=' || fn_segredo('WEBHOOK_TOKEN'),
    'byEvents', false, 'base64', false,
    'events', jsonb_build_array('MESSAGES_UPSERT', 'MESSAGES_UPDATE'))));
-- a resposta guarda a URL com o token: apague-a de net._http_response em seguida
```
