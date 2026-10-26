# Recuperação de desastre: o Trilha sem Supabase e sem Cloudflare

**Decisão 116 (25/10/2026).** O responsável pediu uma cópia de todo o projeto, inclusive o banco, no Google Drive e
no OneDrive. O formato precisa restaurar rápido numa plataforma nova, pensando num desastre de verdade: perder o
Supabase, o Cloudflare e o GitHub de uma vez.

## O pacote de desastre

Formato aberto, que restaura em qualquer servidor, sem depender de fornecedor:

| Arquivo | O que é | Restaura com |
|---|---|---|
| `banco.dump` | Banco inteiro (`pg_dump --format=custom`): esquemas `interno`, `public`, `auth` (usuários e senhas com hash; sem sessões, tokens e desafios de MFA), `storage` (metadados), agendamentos; sem `webhook_eventos`, `ponto_sessoes` e `ponto_codigos`, que se refazem | `pg_restore` em qualquer PostgreSQL 17 |
| `banco.sql.zst` | O mesmo banco em SQL puro, compactado | `psql`, para ler sem ferramenta especial |
| `storage.tar.zst` | Arquivos do bucket `documentos` (atestados, documentos dos técnicos) | `tar` |
| `evolution.dump` | Banco da Evolution **sem a sessão nem o histórico de conversas**: a sessão é credencial do número da empresa; na volta, lê-se o QR de novo e trocam-se os tokens da instância e do webhook | `pg_restore` no servidor novo |
| `codigo.bundle` | Repositório inteiro com todo o histórico (`git bundle --all`) | `git clone codigo.bundle` |
| `painel-producao.tar.zst` | Painel e app do ponto já compilados | Qualquer servidor estático (nginx) |
| `MANIFESTO.txt` | Data, versões (migration, PostgreSQL, Node), sha256 de cada arquivo e o roteiro de restauração | Leitura |

- **Criptografia com chave pública:** o pacote é cifrado **antes** de sair, com a chave pública
  `infra/backup/desastre-publica.asc`. A chave privada, que abre o pacote, fica só no cofre do responsável. Nem o GitHub
  nem o servidor da Oracle guardam o que abre o backup. Uma segunda guarda selada da chave privada (sócio ou advogado) é
  decisão do responsável; sem ela, só uma pessoa restaura.
- **Segredos não entram no pacote:** chaves da Evolution, da Twilio, do Google Vision, do banco e a `COFRE_PONTO`. Vai
  só a lista do que cadastrar e onde. Os valores ficam no cofre de senhas do responsável. **Sem a `COFRE_PONTO`, os
  atestados restaurados não abrem.**
- **Destino:** **uma conta dedicada só ao backup** em cada nuvem, sem outro conteúdo. No Google, o `rclone` usa o escopo
  `drive.file` (só os arquivos que ele mesmo criou, inclusive a pasta). No OneDrive pessoal não existe escopo por
  pasta: o token vale para o drive inteiro, por isso a conta dedicada é obrigatória. O token do OneDrive pode expirar
  em 90 dias; o workflow falha alto e o roteiro prevê a troca. Retenção: 30 cópias diárias e 12 mensais, apagadas sem passar pela lixeira.
  O Storage vai em todas as cópias.
- **Onde roda:** banco, Storage, código e painel no GitHub Actions, junto do backup atual. O banco da Evolution roda num
  agendamento no próprio servidor da Oracle.
- **LGPD (P1 do `seguranca`):** o pacote tem dado pessoal e sensível (CPF, ponto, atestados) e vai para fora do Brasil.
  A cifra mitiga o risco, mas conta de consumidor não tem contrato de operador (arts. 11 e 33). Opções, para decidir
  com o Gabriel **antes do primeiro envio**:
  - Google Workspace ou Microsoft 365 empresarial, com contrato de tratamento (cerca de US$ 6 a 7 por usuário/mês);
  - armazenamento com contrato e região no Brasil (AWS São Paulo, Oracle São Paulo);
  - manter as contas de consumidor e registrar o risco aceito no aviso.
  Um dado eliminado a pedido do titular continua até 12 meses nas cópias mensais: isso vai no aviso, e o roteiro de
  restauração reaplica o `log_exclusoes`.

## Para onde restaurar: alternativas

| # | Plataforma | O que funciona | Tempo de volta estimado | Custo | Esforço de código |
|---|---|---|---|---|---|
| **1** | **Supabase de código aberto, instalado num servidor próprio** (Docker Compose) em qualquer nuvem (Oracle, Hetzner, AWS, Azure, Google). Não depende da empresa Supabase | Tudo: banco, login, Storage, API e Edge Functions. O painel aponta para o endereço novo | 4 a 8 h | Servidor de 4 GB, cerca de US$ 10 a 30/mês, só durante o desastre | Nenhum: trocar endereço e chaves |
| 2 | PostgreSQL gerenciado em outro fornecedor (AWS RDS, Azure, Google Cloud SQL, Neon) + PostgREST + um serviço de login próprio | Banco e API. Login, Storage e Edge Functions precisam ser refeitos | 3 a 10 dias | US$ 15 a 60/mês | Alto: o login e as funções que leem o token precisam mudar |
| 3 | Só o PostgreSQL numa máquina, em modo de consulta | Leitura e exportação: ponto, espelhos, AFD. Cumpre a obrigação legal de apresentar o ponto | 1 a 2 h | Mínimo (o Mac ou uma máquina gratuita) | Nenhum |

**Recomendação do time:**
- **Plano principal: alternativa 1.** O Trilha usa recursos do Supabase (login, `auth.jwt()`, Storage, PostgREST, Edge
  Functions em Deno), e a versão de código aberto traz tudo isso sem mudar o código.
- **Contingência legal imediata: alternativa 3.** Em uma ou duas horas, o ponto pode ser apresentado a quem pedir,
  enquanto a 1 sobe.
- **Alternativa 2:** só se o objetivo for sair de vez do modelo Supabase, que é outra decisão estratégica (CTO).

**Painel:** qualquer hospedagem estática serve, porque o build é estático. A Vercel, o Cloudflare e o nginx no mesmo
servidor da alternativa 1 funcionam igual. **WhatsApp:** a Evolution é reinstalada pelo `infra/evolution`, com o banco
restaurado e o QR lido de novo se a sessão não voltar.

## Metas e ensaio

- **Perda máxima de dado (RPO):** 24 h, a cópia diária. **Tempo de volta (RTO):** 8 h na alternativa 1 e 2 h na 3.
- **Primeiro passo de toda restauração:** `update cron.job set active = false;`, antes de cadastrar qualquer segredo.
  Sem isso, o servidor novo dispara lembretes e ligações.
- **Ensaio a cada três meses**, conduzido pelo `arquiteto-cloud`, num ambiente efêmero e controlado (como o
  `restauracao.yml`) ou numa máquina do responsável apagada no fim, sem Evolution ligada. Restaurar o pacote mais recente pela alternativa 1, entrar no painel, conferir a cadeia do ponto (`app_ponto_verificar`) e medir o
  tempo. O resultado vai para a tabela do `docs/plano-de-trabalho.md`.

## O que o responsável precisa fazer (uma vez)

O workflow é `.github/workflows/desastre.yml` (diário, 04:17 em Salvador). O script do banco da Evolution é
`infra/evolution/backup-desastre.sh`, que roda no servidor da Oracle. **O envio fica travado** até existir a variável
`DESASTRE_LGPD_DECIDIDO=sim`.

0. **[Gabriel]** Decidir a base legal da transferência (seção LGPD acima) e registrar em `docs/decisoes.md`. Só
   depois criar a variável do passo 4.
1. **[navegador]** Criar uma conta dedicada só ao backup no Google e outra na Microsoft (OneDrive).
2. **[ubuntu] Par de chaves da cifra.** A privada vai para o cofre e sai da máquina. A pública é enviada ao Claude, que
   a grava em `infra/backup/desastre-publica.asc` (não é segredo):
   ```bash
   gpg --quick-generate-key "Trilha Backup Desastre" rsa4096 encrypt never   # pede uma frase-senha: guardar à parte
   gpg --armor --export "Trilha Backup Desastre" > ~/desastre-publica.asc
   gpg --armor --export-secret-keys "Trilha Backup Desastre" > ~/desastre-PRIVADA.asc
   cat ~/desastre-publica.asc
   gpg --show-keys --with-colons ~/desastre-publica.asc | awk -F: '$1=="fpr"{print $10; exit}'   # impressão digital
   ```
   Guardar o `desastre-PRIVADA.asc` no cofre pessoal (e na segunda guarda, se houver). Depois:
   `gpg --batch --yes --delete-secret-keys "Trilha Backup Desastre"; shred -u ~/desastre-PRIVADA.asc`.
3. **[Supabase da produção]** Em Storage → Settings → **S3 Access Keys**, gerar uma chave para o backup. Ela vale para
   todos os buckets, com leitura, escrita e apagamento: trocar a cada 90 dias e revogar ali mesmo se houver suspeita.
4. **[ubuntu]** Instalar o `rclone` na versão do workflow e criar os três remotos:
   ```bash
   curl -fsSL -o /tmp/rclone.zip https://github.com/rclone/rclone/releases/download/v1.75.2/rclone-v1.75.2-linux-amd64.zip \
     && echo "349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702  /tmp/rclone.zip" | sha256sum -c - \
     && unzip -qj /tmp/rclone.zip '*/rclone' -d ~/.local/bin && rclone version | head -1
   rclone config
   ```
   - `gdrive`: tipo `drive`, **scope `drive.file`**, autorizado com a conta dedicada do Google.
   - `onedrive`: tipo `onedrive`, conta pessoal, autorizado com a conta dedicada da Microsoft.
   - `storage`: tipo `s3`, provider `Other`, com a chave, o endpoint e a região do passo 3.

   Para testar: `rclone mkdir gdrive:Trilha-Backup && rclone mkdir onedrive:Trilha-Backup && rclone lsd storage:`. O
   esperado é ver o bucket `documentos`.
5. **[GitHub]** Em Settings → Environments, criar o ambiente **`producao-desastre`** e restringir à branch `main`.
   - Segredos: `PRODUCAO_DB_URL`, a mesma do backup, e `RCLONE_CONFIG`, o conteúdo de
     `cat ~/.config/rclone/rclone.conf`.
   - Depois, **sempre** apagar o arquivo da `ubuntu`: `shred -u ~/.config/rclone/rclone.conf`. Para restaurar, gera-se
     um novo.
   - Variáveis (aba Variables): `DESASTRE_FPR` = a impressão digital do passo 2; e, só depois do passo 0,
     `DESASTRE_LGPD_DECIDIDO` = `sim`.
6. **[servidor da Oracle]** Para o banco da Evolution:
   - gerar um `rclone.conf` próprio, só com `gdrive` e `onedrive`, e copiar para `/etc/trilha/rclone.conf` com
     permissão 600;
   - copiar a chave **pública** para `/etc/trilha/desastre-publica.asc`;
   - copiar o script para `/opt/trilha/` e agendar com a linha de cron do cabeçalho, pondo o nome do contêiner do
     PostgreSQL (`docker ps`).

   O workflow falha se não houver cópia da Evolution nas últimas 48 h. **Risco a aceitar pelo responsável:** o token do
   servidor enxerga também a pasta dos pacotes do GitHub; quem invadir o servidor pode apagá-los, mas não abri-los.
7. **[GitHub]** Depois do passo 6, em Actions → **Pacote de desastre** → Run workflow, rodar à mão uma vez. O esperado é
   o resumo com o sha256 e o arquivo nas duas pastas.
8. **A cada 90 dias:** trocar a chave S3 do Storage e o token do OneDrive (refazendo o passo 4 só para esses dois
   remotos) e atualizar o `RCLONE_CONFIG`.
