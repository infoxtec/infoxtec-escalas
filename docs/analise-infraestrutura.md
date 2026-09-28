# Análise de infraestrutura — Trilha

27/09/2026 · persona **Infra/BD**, com parecer de **CTO** e **Segurança** (§9). Leitura apenas, sem
tocar em produção, homologação, VPS ou painéis.

**Como ler:** **FATO** é o que se prova pelo repositório (tem `arquivo:linha`). **SUSPEITA** é o que
depende de painel, VPS, Vercel ou conta de terceiro — está listado na §10 e não foi confirmado.
Severidade: **P0** = perda definitiva de dado ou parada silenciosa sem mitigação; **P1** = risco alto
com mitigação parcial; **P2** = higiene. (Não é o "P0 veta merge" da persona Segurança.)

> **Atualização de 28/09/2026:** a produção passou de **01 a 46** para **01 a 49** (as migrations 47,
> 48 e 49 foram aplicadas juntas, a pedido do responsável). A homologação ficou em **48** e a
> convergência é o primeiro item do "hoje". Os **P0 desta análise seguem abertos** — bucket sem
> cópia, monitor externo, composição do backup e o passo de *default privileges* na restauração. O
> controle de cada um, com a referência exata, está no [painel de controle](painel-de-controle.html).

---

## 1. Inventário

| Componente | Onde roda | Custo hoje | Limite do plano gratuito que se aplica |
|---|---|---|---|
| **Supabase produção** `zpckrxydqqmmcrphrkxz` (sa-east-1) | Postgres + pg_cron + pg_net + Vault + Storage + Auth + 3 Edge Functions | R$ 0 | Banco 500 MB; Storage 1 GB; egress 5 GB/mês; **2 projetos por conta**; pausa por inatividade; 8 MB por arquivo |
| **Supabase homologação** `oruwnlxyvznpigbpjjbx` | mesmo stack, dados fictícios | R$ 0 (ocupa a 2ª vaga) | sem cron e sem segredos reais |
| **Painel React** | Vercel Hobby, Root Directory `web` | R$ 0 | **Hobby proíbe uso comercial** |
| **Evolution própria** | Servidor da Infoxtec na Oracle Cloud (São Paulo, `VM.Standard.E2.1.Micro`), Evolution 2.4.0-rc2, endereço `sslip.io` derivado do IP — vigente em `config.evolution_url`. Desde 28/09, decisão 43 | `infra/evolution/` no repositório; o servidor em si, não | canal não oficial: risco de bloqueio do número. **O endereço depende do IP** — se ele mudar, o `evolution_url` muda junto (tema INF-14) |
| **Twilio (URA)** | Edge Function + Twilio | R$ 0,24 por ligação de 40 s; < R$ 20/mês com 10 técnicos | tetos por config: 2/escala, 2/execução, 45 min |
| **Google Vision (OCR)** | desligado hoje | 1.000 páginas/mês, exige faturamento | sem chave, o botão só avisa |
| **GitHub Actions** | CI + backup diário + restauração mensal | R$ 0 | minutos e artefatos não estão no repositório |
| **healthchecks.io** | **não criado** | R$ 0 | — |
| **Máquina Linux do responsável** | única que aplica migration e publica função | OrbStack é licença comercial paga | não roda Supabase local (não cabe em 3 GB) |

**Fato estrutural:** todo o back de produção é **um único projeto Supabase** — regra de negócio,
agendador, segredos e funções vivem nele.

---

## 2. Pontos únicos de falha

| Quando cai | O que acontece |
|---|---|
| **Supabase produção** | Para tudo: painel, login, Storage, funções, cron. O vigia roda **dentro** do banco (`fn_vigiar_motor`, a cada 5 min), então não avisa; só o healthchecks pegaria — e ele não existe |
| **VPS da Evolution** | Nenhuma mensagem sai. O motor continua "concluindo" e gravando `ultima_execucao_ok`, então **o vigia fica calado**; o alerta sai pelo mesmo canal quebrado. O sinal `/fail` só existe se `monitor_ping_url` estiver preenchido — default **vazio** |
| **Número bloqueado** | "A operação para. Não há plano B automático" |
| **Twilio** | A URA para; o WhatsApp segue (a URA é opcional e `ligacao_ativa` já é `false` por padrão) |
| **Vercel** | Painel fora, mas **o motor continua e os envios saem** — ninguém opera nem vê |
| **GitHub Actions** | Backup, CI e teste mensal param; sem alarme além do e-mail padrão do GitHub |
| **Máquina do responsável** | Ninguém aplica migration nem publica Edge Function |
| **A pessoa** | Quem aplica, testa, decide e guarda a senha do backup é a mesma. As etapas 5, 6 e 7 do plano "param juntas quando ele não está" |
| **Senha do backup** | Sem `BACKUP_SENHA`, as 30 cópias cifradas não abrem. Não há segunda via nem custódia alternativa |

---

## 3. Capacidade, com a conta explícita

| Limite | Conta | Quando estoura |
|---|---|---|
| **Banco 500 MB** | 199 MB/ano no volume simulado de 200 técnicos (174 MB só em `notificacoes`) → teto em ~2,5 anos. Alerta preventivo em 350 MB, 1×/dia. **Ressalva:** a medição é anterior à retenção de `payload_envio`, então é teto superior. Volume real hoje: 13 técnicos, 47 escalas, 91 notificações | ~2,5 anos no volume simulado; muito depois no real |
| **Storage 1 GB** | 4 arquivos × 3 MB = 12 MB/técnico → **~80 técnicos por GB** (≈341 arquivos). **Nada mede nem alerta Storage** | ~80 técnicos |
| **Egress 5 GB/mês** | (a) backup: 1 dump completo/dia × 30 = **~6 GB/mês** com o banco em 199 MB — o padrão que a própria análise previu e mandou evitar; hoje a cópia tem 80 KB, então é irrelevante **por enquanto**; (b) painel: 2 telas recarregam a cada 60 s = 1.440 req/dia **por aba**; (c) 1 GB de documento baixado = 5 GB | quando o banco crescer |
| **2 projetos** | produção + homologação ocupam as duas vagas | **no 1º cliente novo** — é o teto mais duro para o modelo "uma instalação por cliente" |
| **Artefatos 30 cópias** | hoje 80 KB → ~2,4 MB/mês; projetado ~2 GB quando o banco chegar a 199 MB | quando o banco crescer |

**Sem retenção nenhuma:** `escalas`, `notificacoes` (linhas), `respostas`, `ocorrencias`, `ligacoes`
e `escala_eventos`. A limpeza cobre só `webhook_eventos` (30 d), `alertas_enviados` (90 d),
`cron.job_run_details` (7 d) e `payload_envio` (90 d).

---

## 4. Backup e restauração

**Copiado:** `roles.sql`, `schema.sql` e `data.sql` (COPY, sem triggers), exceto
`public.webhook_eventos`. Cifrado AES-256, artefato por 30 dias, ambiente `producao-backup` restrito
à `main`. **RPO: até 24 h. RTO: não medido e manual.**

### 4.1 O backup não é "cópia completa do banco" (verificado)

O cabeçalho do workflow diz "cópia completa do banco (papéis, estrutura e dados)". A documentação
oficial do `supabase db dump` diz o contrário:

> "Runs `pg_dump` in a container with additional flags to **exclude Supabase managed schemas. The
> ignored schemas include auth, storage**, and those created by extensions."
> — [Supabase CLI · db dump](https://supabase.com/docs/reference/cli/supabase-db-dump)

| Fica **fora** da cópia | Consequência real |
|---|---|
| `auth.users` | Depois de um desastre **ninguém entra no painel**: os usuários precisam ser reconvidados e criar senha de novo. O RTO não é "restaurar", é "restaurar + reconvidar todo mundo" |
| `vault.secrets` | Todos os segredos recriados à mão (Evolution, webhook, Twilio, Google) |
| `cron.job` | Os três agendamentos recriados rodando `setup/cron.sql` — **o motor só volta quando alguém lembrar** |
| `storage.objects` | O bucket `documentos` continua fora (já era sabido) |
| provavelmente `supabase_migrations` | O banco restaurado fica **sem histórico de migrations**; um `db push` depois tentaria reaplicar tudo (a confirmar) |

E o **teste mensal passa verde** em tudo isso: confere sete contagens de `public` e exige
`escalas > 0`. Ele prova que o dump abre e que os dados de `public` voltam — não que o sistema volta
a funcionar.

### 4.2 O passo de privilégio que falta no roteiro (verificado)

A mesma documentação avisa:

> "When restoring to a new project, tables inherit ALL privileges from default privileges in the
> target database. To preserve specific privileges from your dump, **revoke defaults before
> restoring**: `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;`"

O roteiro de restauração (`docs/operacao.md`) e o teste mensal **não têm esse passo**. Um banco
restaurado pode voltar com `anon` e `authenticated` recebendo privilégio nas tabelas novas. As
tabelas estão protegidas por RLS sem políticas — mas as **views** são o ponto sensível, e o projeto
já teve exatamente esse problema antes (`vw_ligacoes_pendentes` legível por `anon`, corrigido na
migration 39). **P1, a confirmar** em qual extensão o dump carrega os `REVOKE`.

**Correção mínima:** acrescentar as duas linhas ao roteiro (revogar defaults **antes** de restaurar)
e fazer o teste mensal conferir permissão, não só contagem:

```sql
select has_table_privilege('anon', 'tecnicos', 'select')                 as anon_tabela,   -- esperado false
       has_table_privilege('anon', 'vw_ligacoes_pendentes', 'select')    as anon_view;     -- esperado false
```

### 4.3 Desastre real: tudo manual

Criar projeto novo esbarra nas **duas vagas já ocupadas**. Depois: recriar 5+ segredos do Vault,
reapontar o webhook na Evolution, reconvidar usuários de Auth, rodar `setup/config.sql` (que traz
placeholder `<ref-do-projeto>`) e `setup/cron.sql`, republicar 3 Edge Functions, refazer variáveis na
Vercel e `PRODUCAO_DB_URL` no GitHub. **Nenhum desses passos é ensaiado pelo teste mensal.**

---

## 5. Segredos

| Segredo | Onde vive | Rotação |
|---|---|---|
| `EVOLUTION_API_KEY` | Vault | **Sim** — `vault.update_secret` documentado |
| `WEBHOOK_TOKEN` | Vault + URL do webhook | **Não há procedimento** |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` | Vault | **Não** (girar o auth token invalida a conferência de assinatura) |
| `VOZ_TOKEN` | Vault + query string | **Não** |
| `GOOGLE_VISION_KEY` | Vault (hoje nem existe) | **Não** |
| `TWILIO_ASSINATURA` | segredo de ambiente da função | **Não**; fora do inventário |
| `PRODUCAO_DB_URL`, `BACKUP_SENHA` | GitHub environment, só `main` | **Não**; trocar a senha do backup invalida os artefatos |
| Senha do banco | gerenciador do responsável | reset documentado, **sem** o passo de atualizar `PRODUCAO_DB_URL` |
| `SUPABASE_DB_URL`, `SUPABASE_ANON_KEY` | injetados no runtime das funções | **Não** — a credencial de banco mais ampla do sistema está nas 3 funções |

- **Sem secret scanning no CI** (só 3 workflows, nenhum gitleaks/trufflehog).
- **Inventário documentado está errado:** `docs/seguranca.md` lista 3 itens, omite Twilio, `VOZ_TOKEN`
  e Google, e diz que a senha do banco vive "só no Retool" — desligado em 27/09.
- "Rotação e inventário de segredos" é item **não concluído** do bloco 3 de segurança.

---

## 6. Entrega e deploy

```
branch → PR → CI → preview Vercel (homologação) → merge main → Vercel publica produção
      → aplicar-producao.sh (migrations) → deploy manual das 3 Edge Functions
      → SQL manual de cron/config/Vault → variáveis da Vercel digitadas à mão
```

| Passo manual | Risco |
|---|---|
| Publicar as 3 Edge Functions | Nada compara o publicado com a `main`; o CI só faz `deno check`. **É o item mais sujeito a rodar versão antiga** |
| Agendar `vigia-motor` / `limpeza-logs` / `dispatcher` | Agendamento não é migration: job faltando não quebra deploy, quebra a operação |
| `setup/config.sql` | placeholder `<ref-do-projeto>`: config digitada por ambiente, sem detecção de divergência |
| Segredos do Vault | sem verificação automática de existência (o banco só reclama em runtime) |
| `PRODUCAO_DB_URL` após reset de senha | **o backup passa a falhar em silêncio** |
| `monitor_ping_url` | vazio por default: o monitor externo fica desligado sem ninguém notar |

**Divergências conhecidas:** produção em 01-46 × repositório em 01-48; `config.toml` diz PostgreSQL
17 e `docs/arquitetura.md` diz 15; README fala "01 a 43"; `deploy-vercel.md` nomeia o projeto Vercel
como `infoxtec-escalas` enquanto o vínculo local aponta para o projeto **`web`** (o próprio backlog
registra a dúvida).

**Riscos de processo:** merge na `main` **publica produção** (a Vercel publica sozinha) e a proteção
da branch é item em aberto; o `npx supabase db push` **cru** na produção está documentado em dois
lugares, fora do script com travas; o `aplicar-homologacao.sh` não tem trava de branch nem de árvore
suja; migrations sem rollback escrito (só 39-41 têm "como desfazer"); ações do CI em tags móveis
enquanto os workflows com segredo usam SHA; sem Dependabot com `npm audit` bloqueante; nenhum job tem
`timeout-minutes`.

---

## 7. Observabilidade

**Existe:** estado do motor no banco e na aba Operação; aviso por WhatsApp a supervisores e a
`alerta_tecnico_telefones`; alerta de banco a 350 MB (1×/dia, dentro da janela); ping ao healthchecks
com `/fail` quando a Evolution falha — **com o monitor não criado**; retenção de logs; consultas de
diagnóstico em `operacao.md`; logs da plataforma.

**Não existe:** monitor externo do painel e do Supabase; medição de **Storage e egress**; alerta de
webhook mudo; alerta de erro de Edge Function; verificação do `connectionState` da Evolution; alerta
de falha de backup; alarme do próprio healthchecks; segunda pessoa de plantão; paridade função
publicada × `main`.

### Quanto tempo uma falha fica invisível

| Falha | Tempo até alguém saber |
|---|---|
| Motor parado **dentro** da janela | ~5 a 10 min |
| Motor parado **fora** da janela (21h–6h) | **até ~9 h** — o aviso é condicionado à janela, justamente antes do pico da manhã |
| Evolution fora / sessão caída | **indefinido** — o motor segue "ok" e o alerta sai pelo canal quebrado |
| Supabase fora ou pausado | **indefinido** até o healthchecks existir |
| Webhook caído | **indefinido** (consulta manual) |
| Backup falhando | **até 30 dias** (teste mensal) |
| Storage/egress no limite | **indefinido** — não há medição |

---

## 8. Achados priorizados

### P0

| # | Achado | Onde | Impacto |
|---|---|---|---|
| 1 | **Arquivos de documento (ASO/NR) fora de qualquer cópia**, com guarda declarada de 5 anos e só uma instrução manual mensal, sem registro de execução | `backup.yml:9`; `operacao.md:194-195`; `setup/documentos.md:14-16` | Numa perda do projeto, o acervo some de forma irrecuperável |
| 2 | **Monitor externo (healthchecks.io) não criado** | `plano-de-trabalho.md:97`; `roteiro-producao.md:158-170` | A pior falha (Supabase fora, Evolution caída) fica invisível por tempo indeterminado |

### P1

| # | Achado | Onde |
|---|---|---|
| 3 | **O backup não cobre `auth`, `vault`, `cron` nem Storage** — e o teste mensal não confere nada disso (ver §4.1) | [CLI db dump](https://supabase.com/docs/reference/cli/supabase-db-dump); `restauracao.yml:57-71` |
| 4 | **Falta o passo de revogar *default privileges* antes de restaurar**, que a própria CLI exige (ver §4.2) | `operacao.md:185-192`; `restauracao.yml:49-52` |
| 5 | Backup **diário completo** é o padrão que a análise previu estourar o egress; a recomendação (semanal completo + diário do núcleo) não foi seguida | `backup.yml:14,43-51` |
| 6 | Reset da senha do banco **não sincroniza `PRODUCAO_DB_URL`** → backup falha em silêncio | `roteiro-producao.md:60-64` |
| 7 | `voz_url` com a **ref de produção** como default de migration | `migration 23:35` |
| 8 | `evolution_url` de produção fixo como default | `migration 08:4` |
| 9 | Edge Functions publicadas **à mão**, sem checagem de paridade com a `main` | `roteiro-producao.md:128-135`; `ci.yml:50-58` |
| 10 | **Um push direto na `main` publica produção**; proteção de branch não verificável | `fluxo-de-desenvolvimento.md:144-146` |
| 11 | `db push` cru na produção **documentado**, fora do script com travas | `analise-topologia.md:216-219`; `README.md:87-91` |
| 12 | `aplicar-homologacao.sh` **sem trava** de branch e de árvore suja | `aplicar-homologacao.sh:6-24` |
| 13 | Migrations **sem plano de volta** (só 39-41 têm) | `analise-topologia.md:230-232` |
| 14 | Aviso de motor parado só **dentro da janela** 06:00–21:00 | `migration 45:245,263-264` |
| 15 | Retenção cobre 4 alvos; **6 tabelas crescem para sempre** | `migration 45:292-312` |
| 16 | **Nada mede Storage nem egress** — o primeiro limite a estourar é o único sem sinal | `migration 45:204,248-257` |
| 17 | A cópia cifrada depende de **uma senha só do responsável** | `operacao.md:183` |
| 18 | **Produção 01-46 × repositório 01-48** convivem sem sinalização | `plano-de-trabalho.md:13-15,171` |
| 19 | `setup/config.sql` com **placeholder** `<ref-do-projeto>` | `setup/config.sql:5` |
| 20 | **Sem secret scanning** no CI | `.github/workflows` |
| 21 | **Vercel Hobby proíbe uso comercial** — o painel pode ser suspenso quando o produto for vendido | `decisoes.md:45-47` |
| 22 | Projeto do plano free **pausa por inatividade** | `fluxo-de-desenvolvimento.md:184` |

### P2

| # | Achado | Onde |
|---|---|---|
| 23 | `jsr:@supabase/functions-js` sem versão e **sem `deno.lock`** | `functions/*/index.ts` |
| 24 | Sem Dependabot; `npm audit` bloqueia PR e a correção é manual | `ci.yml:36-48` |
| 25 | Assimetria de pinagem (SHA nos workflows com segredo, tags móveis no CI) | `backup.yml:30-31` × `ci.yml:27,65` |
| 26 | Nenhum job tem `timeout-minutes`; o teste mensal sobe a stack inteira | `restauracao.yml:41` |
| 27 | `net._http_response` não é limpo pela limpeza de logs (suspeita: TTL do pg_net) | `migration 45:292-312` |
| 28 | Sem CSP no painel | `web/vercel.json:3-12` |
| 29 | Documento por link do Drive: retenção manual e acesso fora do sistema | `setup/documentos.md:27-34` |
| 30 | Convite de usuário depende do e-mail padrão do Supabase | `deploy-vercel.md:53-56` |
| 31 | Divergências de documentação de infra (PostgreSQL 15×17, "01 a 43"×48, projeto Vercel `infoxtec-escalas`×`web`) | `arquitetura.md:18`; `README.md:60`; `deploy-vercel.md:24` |

---

## 9. Parecer

### CTO

A arquitetura continua certa para o tamanho atual: um projeto, tudo no banco, custo zero. O que os
achados mostram não é problema de desenho, é **de operação**: seis passos manuais no caminho até
produção, nenhum com verificação de paridade, e nada que confirme que a cópia de segurança volta a
funcionar **como sistema**. O risco deixa de ser aceitável no momento em que o produto passa a ser
vendido — e é aí que **dois achados deixam de ser técnicos e passam a ser comerciais**: o Vercel
Hobby (P1 21) e o teto de **2 projetos** (§3), que inviabiliza "uma instalação por cliente".

Recomendação de ordem: (1) ligar o monitor externo; (2) cobrir o Storage; (3) ensaiar a restauração
**com o sistema voltando a funcionar** (login, segredos, cron), cronometrada.

### Segurança

**Veto** a transformar a restauração em rotina sem o passo de *default privileges* (P1 4): restaurar
sem revogar os defaults pode devolver `anon` e `authenticated` com privilégio em tabelas e views do
projeto novo, que é exatamente a classe de falha corrigida na migration 39. **Veto** também a seguir
o `db push` cru documentado (P1 11): ele contorna a trava de confirmação e deixa o link apontado para
a produção.

O resto é dívida aceitável e priorizável — com uma exceção: o **inventário de segredos está errado**
(P1 30), e inventário errado dá falsa sensação de controle.

**Três ações até o fim de outubro:** criar o monitor externo; cobrir o bucket `documentos` e ensaiar
a restauração completa; escrever a rotação dos cinco segredos sem procedimento.

---

## 10. O que só se confirma fora do repositório

Tamanho atual de banco, Storage e egress · **quais schemas o `db dump` 2.118.0 realmente copia** ·
papel do banco em `SUPABASE_DB_URL` nas Edge Functions · TTL do `pg_net` · versão do Postgres em
produção · proteção da `main` · se o deploy da Vercel vem deste repositório e qual projeto serve o
endereço de produção · custo, backup e monitoração da VPS da Evolution · se a conta Twilio ainda é
trial · existência de faturamento no Google Cloud · cota real de minutos e artefatos do GitHub ·
estado do monitor no healthchecks.io · **se alguma cópia manual do bucket já foi feita**.

## 11. Fontes

`supabase/config.toml`, `supabase/setup/*`, `scripts/*`, `.github/workflows/*` (3),
`web/vercel.json`, `web/.env.*`, `web/package.json`, `web/vite.config.ts`, as 48 migrations,
`CLAUDE.md`, `AGENTS.md`, `README.md`, `.gitignore`, `.vercel/*`, `supabase/.temp/*` e os documentos
`operacao.md`, `analise-global.md`, `analise-topologia.md`, `fluxo-de-desenvolvimento.md`,
`roteiro-producao.md`, `plano-de-trabalho.md`, `ambiente-dev-mac.md`, `deploy-vercel.md`,
`arquitetura.md`, `banco-de-dados.md`, `decisoes.md`, `seguranca.md`, `seguranca-homologacao.md`,
`telefonia.md`, `backlog.md`, `plano-comercial.md`.

Documentação externa: [Supabase CLI — `db dump`](https://supabase.com/docs/reference/cli/supabase-db-dump),
usada para verificar o escopo real da cópia e a exigência de revogar *default privileges* na
restauração (§4.1 e §4.2).
