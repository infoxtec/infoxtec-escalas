# Operação e diagnóstico

Consultas para rodar no **SQL Editor** do Supabase. Todas são leitura, salvo onde indicado.

## Saúde do sistema (comece por aqui)

```sql
select
  (select count(*) from escalas where data_servico = current_date)                as escalas_hoje,
  (select count(*) from notificacoes where status_envio = 'falha'
     and created_at > now() - interval '24 hours')                                as falhas_24h,
  (select count(*) from notificacoes where status_envio = 'enfileirada')          as presas_na_fila,
  (select count(*) from webhook_eventos where recebido_em > now() - interval '24 hours') as eventos_webhook_24h,
  (select max(recebido_em) at time zone 'America/Bahia' from webhook_eventos)     as ultimo_evento,
  (select count(*) from cron.job where active)                                    as agendamentos_ativos;
```

- `presas_na_fila` acima de 2 ou 3 por mais de 5 minutos: a Evolution não está respondendo.
- `eventos_webhook_24h` igual a zero num dia de operação: o webhook caiu (ver abaixo).

## A instância do WhatsApp está conectada?

```sql
select fn_evo_get('/instance/connectionState/' || fn_config('evolution_instancia'));
-- alguns segundos depois, com o número devolvido acima:
select * from fn_http_resposta(<numero>);
```

Esperado: `{"instance":{"instanceName":"infoxtec","state":"open"}}`. Se vier `close` ou
`connecting`, a sessão caiu — é preciso ler o QR Code de novo no Manager da Evolution.

## Por que uma escala não chegou

```sql
select e.data_servico, e.hora_inicio, t.nome, t.ativo, t.opt_in, e.status,
       n.tentativa, n.status_envio, n.erro_codigo, left(n.erro_mensagem, 120) as erro,
       (select acao from vw_acoes_pendentes v where v.escala_id = e.id) as proxima_acao
from escalas e
join tecnicos t on t.id = e.tecnico_id
left join lateral (select * from notificacoes where escala_id = e.id order by created_at desc limit 1) n on true
where e.data_servico = current_date
order by e.hora_inicio;
```

Causas mais comuns, em ordem:

1. **`opt_in` falso** — o motor ignora o técnico por completo. Ligue na aba Técnicos.
2. **Fora da janela** — antes das 06h ou depois das 21h nada sai.
3. **Status `rascunho`** — a escala nunca foi liberada.
4. **`erro_codigo` preenchido** — a Evolution recusou; a mensagem diz o motivo.

## O webhook está recebendo?

```sql
select recebido_em at time zone 'America/Bahia' as quando, evento, left(resultado, 120) as resultado
from webhook_eventos order by recebido_em desc limit 20;
```

Se estiver vazio há horas, confira a configuração na Evolution:

```sql
select fn_evo_get('/webhook/find/' || fn_config('evolution_instancia'));
```

Para reconfigurar (a URL leva o token do Vault, que não aparece em tela):

```sql
select fn_evo_post('/webhook/set/' || fn_config('evolution_instancia'),
  jsonb_build_object('webhook', jsonb_build_object(
    'enabled', true,
    'url', fn_config('webhook_url') || '?token=' || fn_segredo('WEBHOOK_TOKEN'),
    'byEvents', false, 'base64', false,
    'events', jsonb_build_array('MESSAGES_UPSERT','MESSAGES_UPDATE'))));
-- depois apague o registro dessa resposta, que guarda a URL com o token:
delete from net._http_response where id = <numero devolvido>;
```

## Respostas que o sistema não entendeu

```sql
select w.recebido_em at time zone 'America/Bahia' as quando, w.resultado,
       w.payload->'data'->'message' as mensagem
from webhook_eventos w
where w.resultado like '%ignorado%' or w.resultado like '%ERRO%'
order by w.recebido_em desc limit 20;
```

Serve para descobrir formatos novos de resposta do WhatsApp e ajustar `fn_wh_mensagem`.

## Pausar tudo sem desligar nada

```sql
-- só primeiro envio; para de cobrar quem não respondeu
update config set valor = 'false' where chave = 'webhook_ativo';

-- silêncio total (nenhum envio sai)
update config set valor = '00:00' where chave = 'janela_envio_fim';

-- desligar o motor de vez (reversível)
select cron.unschedule('dispatcher-whatsapp');
-- religar:
select cron.schedule('dispatcher-whatsapp', '* * * * *', 'select fn_dispatcher_whatsapp()');
```

## Alerta de prazo da escala

```sql
select * from alertas_enviados order by data_ref desc limit 10;
select fn_pendencias_escala(current_date + 1);
```

`enviado = false` significa que o sistema avaliou e não havia pendência, ou que o horário já
tinha passado da janela de 2 horas.

## Limpeza periódica

```sql
delete from webhook_eventos where recebido_em < now() - interval '30 days';
delete from alertas_enviados where data_ref < current_date - interval '90 days';
delete from cron.job_run_details where end_time < now() - interval '7 days';
```

O `pg_cron` roda 1.440 vezes por dia e o histórico cresce rápido no plano gratuito.

## Trocar a chave da Evolution

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'EVOLUTION_API_KEY'),
  'NOVA_CHAVE_AQUI');
```

## Sinais de alerta no WhatsApp

Número não oficial pode ser bloqueado. Reduza o risco:

- `max_tentativas` em 3 e `envios_por_execucao` em 3 — não dispare tudo no mesmo segundo.
- Nunca envie para números que não existem: mantenha `ativo` e `opt_in` corretos.
- Peça a cada técnico novo que salve o número e mande um "oi" antes do primeiro envio.

Se o número cair, a operação para. Não há plano B automático.
