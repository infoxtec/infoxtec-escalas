# Caminhos até a produção

Inventário de **tudo o que pode mudar a produção** (banco, Edge Functions, painel, endereço) e das credenciais que
abrem esses caminhos. Ação 1 da daily de 04/11 (sprint 04–17/11, decisão 133), depois do achado de que a integração
GitHub do Supabase publicava na produção sem aprovação.

**Regra:** a produção só muda pelo workflow **Aplicar** aprovado no ambiente `producao` do GitHub. Todo outro caminho
automático fica **desligado**. Os caminhos manuais ficam só para contingência, com o motivo registrado.

**Quando conferir:** todo PR que mexe em infraestrutura (workflow, `vercel.json`, `wrangler*.jsonc`, `config.toml`,
integração de fornecedor) confere a tabela 1 e diz no PR se algo mudou. Revisão completa no início de cada sprint.
Quem confere o painel de fornecedor é o responsável, porque o Claude não tem login lá. O Claude confere pelos logs e
pelos checks do GitHub.

## 1. Caminhos que mudam a produção

| # | Caminho | O que muda | Estado esperado | Como conferir | Situação em 04/11 |
|---|---|---|---|---|---|
| 1 | Workflow **Aplicar**, destino `producao` (`.github/workflows/aplicar.yml`) | Migrations, Edge Functions (`funcoes`), painel (`painel = sim`) | **Único caminho.** Só roda depois da aprovação do responsável no ambiente `producao` | GitHub → Settings → Environments → `producao`: Required reviewers = responsável; restrito à branch `main`; sem bypass para administrador | Em uso |
| 2 | **Integração GitHub do Supabase** no projeto da produção (Project Settings → Integrations → GitHub) | Migrations e as Edge Functions do `config.toml`, a cada push na `main` | **Deploy to production desligado.** Automatic branching desligado | No painel do Supabase. No GitHub, o check "Supabase Preview" dos merges não pode mais aplicar nada: no **próximo Aplicar com destino `producao`** que tiver migration nova, o log deve mostrar `Applying migration` (e não `Remote database is up to date`) | Desligado em 04/11 pelo responsável. Estava ligado desde antes de 30/10. **Ligado de novo em algum momento entre 04/11 e 06/11: aplicou a 149 (06/11) e a 150 (09/11) sem aprovação; desligado de novo em 09/11.** Desde 09/11 o próximo Aplicar para se achar migration que ele não aplicou (trava `aplicar_registro`: detecta, não impede; não cobre Edge Functions) |
| 3 | Integração GitHub do Supabase no projeto da **homologação** | Homologação (não a produção) | Se estiver ligada, a homologação recebe migration antes do `plpgsql_check` do Aplicar. Preferível desligada | No painel do Supabase da homologação | **A conferir pelo responsável** |
| 4 | **Vercel**, projeto `web` | Só o redirecionamento para o Worker (B7) | `git.deploymentEnabled: false` no `web/vercel.json`. Projeto **nunca apagado** (os QR dos espelhos apontam para ele) | Nenhum status "Vercel – web" nos merges da `main` | Desligado (#201, #208) |
| 5 | Vercel, projeto `infoxtec-escalas-homologacao` | Reserva da homologação | Pausado. Se for despausado, redirecionaria para a produção, porque usa o mesmo `vercel.json` | No painel da Vercel | Pausado |
| 6 | **Cloudflare**, Worker `trilha` (painel da produção) | Painel da produção | **Disable builds ligado.** Só o Aplicar publica, com o `CLOUDFLARE_API_TOKEN`. `preview_urls: false` | No GitHub, o check "Workers Builds: trilha" não deveria aparecer | **Divergência:** o check ainda aparece nos PRs (#205–#209). São versões sem endereço público e o endereço oficial não muda, mas o build automático continua ligado em algum nível. A conferir no painel |
| 7 | Cloudflare, Worker `trilha-homologacao` | Painel da homologação | Build da `main` e pré-visualização por branch: é o fluxo da homologação | Check "Workers Builds: trilha-homologacao" | Em uso, sem efeito na produção |
| 8 | **Painel do Supabase da produção** (SQL Editor, deploy de função, Storage, Auth) | Tudo | Só o responsável, e só para o que o Aplicar não faz: Site URL e Redirect URLs, segredos, backlog (exceção de 26/09) | Sem conferência automática | Usado em 04/11 para a Site URL e a integração |
| 9 | **Conector do Supabase do Claude** (MCP) | Tudo: o conector alcança a produção | Proibido pelo CLAUDE.md. O Claude só usa na homologação | Cada chamada pede confirmação do responsável | **Risco:** restringir o conector ao projeto da homologação, se o Supabase permitir |
| 10 | `scripts/aplicar-producao.sh` | Migrations | Contingência, com o motivo registrado. Conferir `supabase/.temp/project-ref` antes | Uso registrado no plano | Não usado |
| 11 | Conector do Cloudflare e da Vercel do Claude (MCP) | Workers e projetos da conta | Não usados para publicar | Sem conferência | Não usados |
| 12 | `scripts/rotacionar-evolution.sh --aplicar` | Vault da produção (token da Evolution) | Só na rotação, pelo responsável, com `~/.infoxtec/producao.env` | Uso registrado em `docs/rotacao-de-segredos.md` | Contingência |
| 13 | Painel local apontando para a produção (`ambiente-dev.sh iniciar producao`, porta 5174) | **Dados** reais (não código) | Só o responsável, com a tarja vermelha | — | Uso eventual |
| 14 | Manager da Evolution e SSH do servidor da Oracle; DNS do `{$DOMINIO}` do `infra/evolution/Caddyfile` | WhatsApp: webhook e token da instância `infoxtec`; quem mexe no DNS desvia o WhatsApp | Só o responsável | `docs/evolution-propria.md` | — |
| 15 | Console da Twilio (URL de voz do número); conta do Cloudflare dona do subdomínio `david-cerqueira.workers.dev` (alvo do painel e do redirecionamento da Vercel) | URA; endereço do painel | Só o responsável; subdomínio nunca renomeado (decisão 133) | — | URA **ligada** (183 ligações em 30 dias até 06/11; o "desligada" de 04/11 estava errado). Desde a migration 150: só da conta da operadora, teto de 20 por dia |

**Caminhos que só leem a produção:** os workflows `backup.yml` (diário, transação só de leitura) e `desastre.yml`
(diário), com o segredo `PRODUCAO_DB_URL` dos ambientes `producao-backup` e `producao-desastre`; o `desastre.yml` lê o
Storage com uma chave S3 que **tem escrita** (no `RCLONE_CONFIG`). O `restauracao.yml` (mensal) só usa a `BACKUP_SENHA`
e restaura num banco temporário do próprio runner. O DeepSeek lê para diagnóstico, sempre em
transação só de leitura (decisão 47).

**O que roda dentro da produção sem deploy** (não é caminho de mudança de código): `pg_cron`, com o motor de envio, a
limpeza e o vigia (`supabase/setup/cron.sql`); o webhook da Evolution; a URA da Twilio (ligada; ver linha 15).

## 2. Credenciais que abrem esses caminhos

| Credencial | Onde fica | Abre | Dono | Validade | Situação |
|---|---|---|---|---|---|
| `DB_URL` (produção) | GitHub, ambiente `producao` | Banco da produção (Aplicar) | Responsável | Senha do banco, sem vencimento | Em uso |
| `SUPABASE_ACCESS_TOKEN` | GitHub, ambiente `producao` | Deploy de Edge Function em **qualquer** projeto da conta | Responsável | **A registrar** (o anterior venceu sem aviso em 03/11) | Trocado em 03/11 |
| `CLOUDFLARE_API_TOKEN` (token `github-aplicar-painel`, de usuário) | GitHub, ambiente `producao` | **Quase toda a conta do Cloudflare**: Workers Scripts e todo o Developer Platform, todas as zonas (DNS, WAF, SSL, rotas), e **User → API Tokens e Memberships: Edit** (cria tokens e mexe em membros) | Responsável | **Sem validade**, sem filtro de IP | Valor girado em 10/11. **Risco aceito pelo responsável em 10/11** (não reduzir); rever em 17/11 (fim da sprint 04–17/11), junto com a decisão sobre o `deepseek_full_access`. O inventário de 04/11 dizia "Workers Scripts: Edit, 90 dias": estava errado |
| `CLOUDFLARE_ACCOUNT_ID` | GitHub, ambiente `producao` | Identifica a conta (não é segredo) | — | — | Cadastrado |
| `PRODUCAO_DB_URL` | GitHub, ambientes `producao-backup` e `producao-desastre` | Banco da produção (leitura no uso) | Responsável | Senha do banco | Em uso |
| `BACKUP_SENHA`, `RCLONE_CONFIG` | GitHub, ambientes de backup | Abrir o backup; Drive e OneDrive; Storage S3 (com escrita) | Responsável | Chave S3: troca a cada 90 dias (`desastre.yml`) | Em uso |
| Tokens de build do Cloudflare (`infoxtec-escalas build token`, `trilha-ti build token`) | Cloudflare (gerenciados por ele) | Deploy dos Workers pelo build do próprio Cloudflare | Cloudflare | — | O `trilha-ti` foi usado em 09/11, quando o build da homologação foi religado. Com Disable builds, não deveriam publicar o `trilha` |
| Outros tokens de usuário no Cloudflare (10/11): `cloudfare_engenharia` (rotas de Workers e membros; usado em 09/11), `deepseek_full_access` (Access e **User → API Tokens**; nunca usado), `Cloudflare Agent Token - 2026-10-25` | Cloudflare do responsável | Variável | Responsável | — | **A decidir pelo responsável:** apagar o `deepseek_full_access` (recomendado: cria qualquer token) e dizer para que serve o `cloudfare_engenharia` |
| GitHub App do Supabase | GitHub (Installed apps) | Leitura do repositório e checks | Responsável | — | Instalado (só leitura depois do Deploy to production desligado) |
| GitHub App da Vercel e do Cloudflare | GitHub (Installed apps) | Leitura do repositório e checks | Responsável | — | Instalados |
| Segredos das Edge Functions (Twilio, SMTP, Vision) e o Vault | Supabase da produção | Serviços externos | Responsável | `docs/rotacao-de-segredos.md` | — |
| Chave global da Evolution | Só no servidor da Oracle | WhatsApp | Responsável | — | Nunca em Vault nem em repositório |
| `DB_URL` (homologação) | GitHub, ambiente `homologacao` | Banco da homologação | Responsável | Senha do banco | Em uso |
| `~/.infoxtec/producao.env` | Máquina do responsável | Senha completa do banco da produção (scripts de contingência) | Responsável | Senha do banco | Contingência |
| Login da Supabase CLI (`~/.supabase/access-token`) e `vercel login` | Máquina do responsável | Deploy e banco por linha de comando (`aplicar-producao.sh`, `configurar-vercel-homologacao.sh`) | Responsável | Do fornecedor | Contingência |
| Token do GitHub do Claude | Sessão do Claude Code | Merge na `main` (o controle é o CI obrigatório e o merge do responsável em PR de workflow) | Responsável | Da sessão | Em uso |
| SSH da Oracle e `/etc/trilha/rclone.conf` | Servidor da Oracle | Evolution e backup dela | Responsável | — | Em uso |
| Token do OneDrive (no `RCLONE_CONFIG`) | GitHub, ambiente `producao-desastre` | Cópia de desastre | Responsável | Vence a cada 90 dias | Em uso |

**Lembretes de validade:** o Claude avisa na daily da semana do vencimento. Para o `SUPABASE_ACCESS_TOKEN`, o
responsável informa a data de validade escolhida para entrar nesta tabela.

## 3. Contas com acesso aos painéis

Supabase, GitHub, Cloudflare, Vercel, Oracle, Twilio e Google (Drive): quem é membro e se usa duas etapas. **A
preencher pelo responsável**, uma linha por conta (membro, papel, duas etapas sim ou não).

## 4. Pendências do inventário

1. Responsável: conferir a integração GitHub do Supabase da **homologação** (linha 3).
2. Responsável: conferir por que o Worker `trilha` ainda gera build nos PRs com Disable builds ligado (linha 6). Se o
   painel do Cloudflare não tiver outra chave, desconectar o repositório do Worker `trilha` (Settings → Builds →
   Disconnect): o Aplicar publica sem precisar do Git ligado.
3. Responsável: conferir no ambiente `producao` do GitHub os revisores obrigatórios e o bypass de administrador (linha 1); no repositório, GitHub Pages e webhooks desligados (não há Dependabot: `.github/dependabot.yml` não existe).
6. Responsável: preencher a seção 3 (contas e duas etapas).
4. Responsável: informar a validade do `SUPABASE_ACCESS_TOKEN` (tabela 2).
5. Claude: ver se o conector do Supabase pode ser limitado ao projeto da homologação (linha 9).

## 5. Trava do Aplicar (desde 09/11)

O Aplicar guarda em `supabase_migrations.aplicar_registro` as versões do repositório presentes no banco ao fim de cada
execução, mais a base de 09/11 (até a 150). Se a produção tiver uma migration que não está lá, o **próximo** Aplicar para
com o erro "Migration na produção que o Aplicar não aplicou". Isso quer dizer que algum caminho da tabela 1 mudou a
produção. A trava detecta, não impede (a integração ligada aplica no merge do mesmo jeito), e não cobre Edge Functions
nem o painel. O responsável investiga (integração do Supabase, SQL Editor, CLI) e só
então libera a versão, no SQL Editor da **produção**:

```sql
-- PRODUÇÃO. Conferir antes: a versão é mesmo a do repositório e o caminho por onde entrou já foi fechado.
select s.version, s.name from supabase_migrations.schema_migrations s
 where not exists (select 1 from supabase_migrations.aplicar_registro r where r.version = s.version);
-- Liberar (troque a versão; uma linha por versão investigada):
insert into supabase_migrations.aplicar_registro (version, origem)
values ('AAAAMMDDHHMMSS', 'aceita pelo responsável em DD/MM: <motivo>');
-- Esperado depois: a primeira consulta volta vazia.
```

Esse insert manual é a única exceção ao "só pelo Aplicar" e vale só para esta tabela.

A primeira execução depois desta trava registra o estado da produção como base (a 149 e a 150, que entraram pela
integração em 06/11 e 09/11, já conferidas).

