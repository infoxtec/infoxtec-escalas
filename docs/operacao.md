# Operação e diagnóstico

Consultas para rodar no **SQL Editor** do Supabase. Todas são leitura, salvo onde indicado.

## Conferência depois de um merge

Cinco alvos, cada um com o seu comando. Serve para responder "o que está no ar agora?" sem depender
da memória de ninguém.

**1. O repositório recebeu o merge?**

```bash
cd ~/infoxtec-escalas && git checkout main && git pull && git log --oneline -3
```

Esperado: o commit do merge no topo, e `git status` limpo.

**2. O banco da produção está na migration mais nova?**

No SQL Editor da produção (a versão é o prefixo do nome do arquivo da migration):

```sql
select version, name
  from supabase_migrations.schema_migrations
 order by version desc
 limit 5;
```

Esperado: a maior versão igual ao arquivo mais recente de `supabase/migrations/`.

**3. O painel publicado é o que está na `main`?**

Abra https://infoxtec-escalas.vercel.app e confira a **versão no rodapé** — ela tem que bater com
`__APP_VERSION__` em `web/vite.config.ts`. Se não bater, a Vercel não publicou.

**4. O painel de controle está atualizado?**

Ele não é publicado: é arquivo, lido do repositório.

```bash
cd ~/infoxtec-escalas && git pull && xdg-open docs/painel-de-controle.html
```

**5. O quadro do backlog está como você deixou?**

```bash
cd ~/infoxtec-escalas && ./scripts/backlog-conferir.sh
```

Mostra o quadro por coluna e quem está travando a tabela (precisa de `psql` e da conexão em
`~/.infoxtec/producao.env`). Para ler sem instalar nada, o mesmo `select` no SQL Editor resolve —
`select` não espera lock.

**Quando um `update` no SQL Editor travar:** é bloqueio de tabela, e o editor não tem limite de
espera. Veja "Tabela travada" no fim deste documento.

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

## Ligações da URA

```sql
select l.criada_em at time zone 'America/Bahia' as quando, t.nome, l.status, l.digito,
       l.duracao_seg, l.preco, left(coalesce(l.erro, '—'), 80) as erro
from ligacoes l join tecnicos t on t.id = l.tecnico_id
order by l.criada_em desc limit 20;

-- quem está na fila para receber ligação agora
select * from vw_ligacoes_pendentes;
```

`duracao_seg = 0` com status `sem_resposta` significa que a chamada não foi atendida — não é
bloqueio de operadora. Para ver o registro real na Twilio, ver `supabase/setup/twilio.md`.

## Documentos

```sql
-- documentos vencidos de retenção (5 anos após o desligamento)
select * from vw_documentos_expirados;

-- validade dos documentos por técnico ativo
select tecnico, habilidade, validade, situacao
from vw_tecnico_habilidades
where tecnico_ativo and exige_validade
order by validade nulls first;
```

Arquivo órfão no Storage (enviado, mas sem registro no banco) não deveria existir: o painel apaga
o arquivo quando o registro falha. Se suspeitar de sobra, compare o bucket `documentos` com
`select caminho from documentos where origem = 'storage'`.

## Motor parado

Desde a migration 44, a aba **Operação** mostra no topo se o motor de envio está em dia. Se ele
passar de 5 minutos sem concluir uma execução, os supervisores recebem aviso pelo WhatsApp (uma
vez) e outro quando normalizar. Para ver o motivo da falha:

```sql
select start_time at time zone 'America/Bahia' as inicio, status, left(return_message, 200) as mensagem
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = 'dispatcher-whatsapp')
order by start_time desc limit 10;
```

Desde a migration 45, o aviso também vai para os telefones de `alerta_tecnico_telefones`, e o
motor manda um sinal por minuto ao monitor externo (healthchecks.io), que avisa por e-mail e
Telegram quando o sinal para (motor parado, Supabase fora ou pausado) ou chega como falha
(Evolution recusando envios). Ver decisão 34 e `docs/roteiro-producao.md`.

**O monitor está ligado desde 28/09/2026** (período de 5 minutos, carência de 5, no healthchecks.io).
Confirme de tempo em tempo — se `valor` voltar vazio, o monitor está desligado:

```sql
select chave, valor from config where chave = 'monitor_ping_url';
```

Se `valor` voltar vazio, o monitor está desligado e a única vigilância é o aviso pelo WhatsApp, que
depende do próprio canal que pode estar quebrado. É o tema **INF-02** no painel de controle. Para
ligar: crie o check no healthchecks.io (período de 5 minutos, carência de 5) e grave o endereço:

```sql
update config
   set valor = 'https://hc-ping.com/COLE-A-UUID-DO-CHECK'
 where chave = 'monitor_ping_url'
returning chave, valor;
```

O gatilho da migration 45 recusa valor que não comece com `https://`.

## Evolution fora do ar: contingência manual

Quando o monitor avisar que a Evolution está falhando, ou os técnicos não receberem:

1. Na Evolution, conferir se a instância está conectada (seção acima) e reconectar pelo QR Code.
2. Enquanto não voltar, avisar a escala de amanhã por ligação ou por um WhatsApp manual, a partir
   da aba Agenda (filtro do dia seguinte).
3. Quando voltar, o motor reenvia sozinho o que ficou em `falha`, dentro de `max_tentativas`.
   Confira na aba Operação as escalas que ficaram sem resposta.

## Backup

Diário e gratuito, pelo GitHub Actions (`.github/workflows/backup.yml`, etapa 18): cópia completa
do banco de produção (papéis, estrutura e dados, sem `webhook_eventos`), criptografada com a senha
`BACKUP_SENHA`, guardada 30 dias como artefato do GitHub (aba **Actions → Backup da produção**).
Todo dia 1, `.github/workflows/restauracao.yml` restaura a cópia mais recente num banco temporário e
confere as contagens; se falhar, o GitHub manda e-mail.

**Âncora da cadeia do ponto** (decisão 51, parte 2). Antes do dump, o backup:
1. baixa a âncora do backup anterior (artefato `ancora-ponto`, criptografado, 90 dias) e confere na
   produção que cada empresa ainda tem aquela marcação com o mesmo hash (`scripts/backup/ancora-anterior.sh`).
   Como cada hash inclui o anterior, reescrever qualquer marcação até ali — mesmo refazendo a cadeia
   inteira de forma consistente, o que o banco sozinho não percebe — muda o hash ancorado;
2. grava a âncora nova (`scripts/backup/ancora-ponto.sql`, transação só de leitura): por empresa, o
   último NSR e o último hash, depois de conferir `ponto_nsr` contra as marcações.

Se uma das duas acusar, **a cópia é guardada mesmo assim** e a execução falha no fim, com e-mail do
GitHub. Execução com falha não vira "backup anterior": o dia seguinte continua conferindo contra a
última âncora boa. No resumo (público) sai só o `sha256` das linhas `empresa,NSR,hash` — qualquer um
recalcula a partir das marcações. A restauração mensal confere a âncora do backup **e a mais antiga
ainda guardada** contra o banco restaurado, recalculando a cadeia com uma **cópia de referência da
fórmula do hash** (`scripts/backup/conferir-ancora.sql`), não com a `fn_ponto_hash` que veio no
backup — quem trocasse a função na produção é acusado.

**Limites:** quem for ao mesmo tempo dono do banco **e** administrador do GitHub pode apagar
execuções e artefatos; uma âncora fora do alcance dele (e-mail para um terceiro, carimbo de tempo
público) é decisão do responsável. Se a fórmula do hash mudar numa migration, a cópia de referência
muda junto. **Execução com âncora acusando = incidente:** não apagar artefatos (a âncora mais antiga
que ainda confere mostra até onde a cadeia é confiável) e acionar o `seguranca`.

**Guardar a `BACKUP_SENHA` fora do GitHub** (gerenciador de senhas). Sem ela, a cópia não abre.

Para restaurar de verdade (desastre), numa máquina com o Supabase CLI:

```bash
gpg --decrypt producao-AAAAMMDD-HHMM.tar.gz.gpg > copia.tar.gz   # pede a BACKUP_SENHA
mkdir copia && tar -xzf copia.tar.gz -C copia
psql "<conexão do projeto novo>" --single-transaction -v ON_ERROR_STOP=1 \
  -f copia/roles.sql -f copia/schema.sql -c 'set session_replication_role = replica' -f copia/data.sql
```

**Fora do backup:** os arquivos do bucket `documentos` (Storage). Enquanto não houver cópia
automática, baixe o bucket pelo painel do Supabase uma vez por mês.

## Limpeza periódica

Automática desde a migration 39: `fn_limpeza_logs()` roda todo dia às 03h17, agendada por
`supabase/setup/cron.sql`. Apaga o log de webhook com mais de 30 dias, os alertas com mais de 90 e
o histórico do `pg_cron` com mais de 7 e, desde a migration 45, o conteúdo enviado
(`payload_envio`) das notificações com mais de 90 dias. Para rodar na hora:

```sql
select fn_limpeza_logs();
```

O `pg_cron` roda 1.440 vezes por dia e o histórico cresce rápido no plano gratuito.

## Trocar o servidor da Evolution (migração do canal)

**O roteiro completo está em [`evolution-propria.md`](evolution-propria.md)** — §E (a virada, com o
plano de volta) e §F (desligar o servidor antigo). Ele nasceu da migração de 28/09, quando a Evolution
saiu de um servidor de terceiros e passou para um servidor da Infoxtec na Oracle Cloud (decisão 43).

O resumo do que muda, e o que se esquece:

| Onde | O quê |
|---|---|
| `config.evolution_url` | o endereço do servidor novo. **O gatilho de `config` não valida esta chave** — uma barra a mais no fim quebra o envio em silêncio |
| `config.evolution_instancia` | se o nome da instância mudou |
| Vault, `EVOLUTION_API_KEY` | a chave da instância nova |
| **Webhook** | `fn_evo_post('/webhook/set/…')` **no servidor novo**. Sem isso, a resposta do técnico nunca chega — e o sintoma é silencioso, porque as escalas continuam saindo |
| `net._http_response` | apagar a resposta do `/webhook/set/`, que guarda a URL com o token |

**Operação do servidor** (no servidor, em `~/infoxtec-escalas/infra/evolution`): `docker compose ps`,
`docker compose logs --tail 100 evolution`, troca da chave-mestra, troca da imagem e
`apt upgrade` uma vez por mês — a tabela está em `evolution-propria.md`.

## Trocar a chave da Evolution

Se o que mudou foi o **servidor**, comece por "Trocar o servidor da Evolution" acima: além da chave, o
webhook precisa ser registrado de novo. Se é só a chave, use o script — ele pede o valor sem eco,
confere na Evolution e ensina a limpar o rastro:

```bash
./scripts/rotacionar-evolution.sh --aplicar
```

Passo a passo completo, com o ensaio e o que não tem volta: `docs/rotacao-de-segredos.md` §3.2.

## Sinais de alerta no WhatsApp

Número não oficial pode ser bloqueado. Reduza o risco:

- `max_tentativas` em 3 e `envios_por_execucao` em 3 — não dispare tudo no mesmo segundo.
- Nunca envie para números que não existem: mantenha `ativo` e `opt_in` corretos.
- Peça a cada técnico novo que salve o número e mande um "oi" antes do primeiro envio.

Se o número cair, a operação para. Não há plano B automático.

## Tabela travada (um UPDATE que não termina)

O SQL Editor do Supabase **não tem limite de espera**: um `update` que encontra a tabela bloqueada por
outra sessão fica parado indefinidamente, sem erro. Quase sempre é uma aba antiga com transação aberta.

Veja quem está com a tabela presa:

```sql
select l.pid,
       case when l.granted then 'SEGURA' else 'ESPERA' end as situacao,
       l.mode, a.state,
       coalesce((now() - a.xact_start)::text, '—') as tempo,
       left(regexp_replace(coalesce(a.query,''), '\s+', ' ', 'g'), 70) as consulta
  from pg_locks l
  join pg_stat_activity a on a.pid = l.pid
 where l.relation = 'backlog_itens'::regclass
 order by l.granted, l.pid;
```

Se não aparecer nada, veja as sessões acordadas:

```sql
select pid, state, wait_event_type, wait_event, coalesce((now() - xact_start)::text, '—') as tempo,
       left(regexp_replace(coalesce(query,''), '\s+', ' ', 'g'), 70) as consulta
  from pg_stat_activity
 where datname = current_database() and pid <> pg_backend_pid() and state <> 'idle'
 order by xact_start nulls first;
```

Encerre quem está atrapalhando (troque o `12345` pelo `pid`):

```sql
select pg_cancel_backend(12345);
```

```sql
select pg_terminate_backend(12345);
```

**Para escrever sem risco de travar**, use `./scripts/backlog-conferir.sh` como referência: por `psql`,
com `lock_timeout` de 5s — se a tabela estiver presa, ele falha em 5 segundos dizendo quem prende, em
vez de esperar para sempre.
