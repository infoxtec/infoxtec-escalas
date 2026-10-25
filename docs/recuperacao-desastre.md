# Recuperação de desastre: o Trilha sem Supabase e sem Cloudflare

**Decisão 116 (25/10/2026).** O responsável pediu uma cópia de todo o projeto, inclusive o banco, no Google Drive e
no OneDrive. O formato precisa restaurar rápido numa plataforma nova, pensando num desastre de verdade: perder o
Supabase, o Cloudflare e o GitHub de uma vez.

## O pacote de desastre

Formato aberto, que restaura em qualquer servidor, sem depender de fornecedor:

| Arquivo | O que é | Restaura com |
|---|---|---|
| `banco.dump` | Banco inteiro (`pg_dump --format=custom`): esquemas `interno`, `public`, `auth` (usuários e senhas com hash), `storage` (metadados), agendamentos | `pg_restore` em qualquer PostgreSQL 17 |
| `banco.sql.zst` | O mesmo banco em SQL puro, compactado | `psql`, para ler sem ferramenta especial |
| `storage.tar.zst` | Arquivos do bucket `documentos` (atestados, documentos dos técnicos) | `tar` |
| `evolution.dump` | Banco da Evolution (sessões do WhatsApp das instâncias) | `pg_restore` no servidor novo |
| `codigo.bundle` | Repositório inteiro com todo o histórico (`git bundle --all`) | `git clone codigo.bundle` |
| `painel-producao.tar.zst` | Painel e app do ponto já compilados | Qualquer servidor estático (nginx) |
| `MANIFESTO.txt` | Data, versões (migration, PostgreSQL, Node), sha256 de cada arquivo e o roteiro de restauração | Leitura |

- **Criptografia:** o pacote é cifrado (AES-256) **antes** de sair do servidor. Sem a senha, que só o responsável
  guarda fora de qualquer nuvem do projeto, o arquivo não abre. É a mesma regra do backup de hoje (decisão 70).
- **Segredos não entram no pacote:** chaves da Evolution, da Twilio, do Google Vision e do banco. Vai só a lista do que
  cadastrar e onde. Os valores ficam no cofre de senhas do responsável.
- **Destino:** uma pasta própria no Google Drive e outra no OneDrive, gravadas pelo `rclone`, com acesso só à pasta do
  backup. Retenção: 30 cópias diárias e 12 mensais. A cópia mensal leva também o pacote completo do Storage.
- **Onde roda:** banco, Storage, código e painel no GitHub Actions, junto do backup atual. O banco da Evolution roda num
  agendamento no próprio servidor da Oracle.
- **LGPD:** o pacote tem dado pessoal (CPF, ponto, atestados) e vai para o Google e a Microsoft, fora do Brasil. A
  mitigação é a cifra antes do envio, como na decisão 70. O registro da transferência entra no aviso de privacidade,
  para o parecer do Gabriel.

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
- **Ensaio a cada três meses**, conduzido pelo `arquiteto-cloud`: restaurar o pacote mais recente numa máquina
  descartável pela alternativa 1, entrar no painel, conferir a cadeia do ponto (`app_ponto_verificar`) e medir o
  tempo. O resultado vai para a tabela do `docs/plano-de-trabalho.md`.

## O que o responsável precisa fazer (uma vez)

1. **Criar a pasta** `Trilha-Backup` no Google Drive e no OneDrive.
2. **Gerar a configuração do `rclone`** na máquina `ubuntu`, com acesso aos dois. O roteiro vem com o pull request do
   workflow.
3. **Cadastrar os segredos** no ambiente `producao-backup` do GitHub:
   - `RCLONE_CONFIG`, a configuração gerada no passo 2;
   - `DESASTRE_SENHA`, a senha da cifra, diferente da `BACKUP_SENHA`.
4. **Guardar a senha** no cofre pessoal, fora do Google e da Microsoft.
