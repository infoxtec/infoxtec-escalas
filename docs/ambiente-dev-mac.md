# Ambiente de desenvolvimento no Mac

Como montar a máquina Linux e o banco de homologação usados para rodar o painel localmente.
É opcional: o fluxo padrão, descrito em [fluxo-de-desenvolvimento.md](fluxo-de-desenvolvimento.md),
funciona só com o Claude Code na web.

Testado em MacBook Air Intel (i3 dois núcleos). Em Mac Intel, **o Homebrew não funciona mais**:
tudo abaixo é instalado por download direto.

## 1. Máquina Linux

Duas opções, ambas com Ubuntu 24.04.

**OrbStack** (https://orbstack.dev/download, versão Intel). Mais integrado: portas chegam ao
`localhost` do Mac. Licença comercial paga.

```bash
orb create ubuntu:24.04 dev
orb -m dev                      # entrar no Linux
```

**Multipass** (https://canonical.com/multipass/install, arquivo `.pkg`). Gratuito, inclusive para
uso comercial. O painel abre pelo IP da máquina, não pelo `localhost`.

```bash
multipass launch 24.04 --name dev --cpus 2 --memory 3G --disk 20G
multipass shell dev             # entrar no Linux
multipass list                  # mostra o IP
```

Com 8 GB de memória no Mac, limite a máquina a 3 GB. Não rode o Supabase local
(`supabase start`): ele sobe mais de dez contêineres e não cabe.

## 2. Ferramentas (dentro do Linux)

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl build-essential unzip gh

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc
nvm install 20 && nvm alias default 20

git config --global user.name  "Seu Nome"
git config --global user.email "seu.email@infoxtec.com.br"

gh auth login                   # GitHub.com → HTTPS → Y → navegador
gh repo clone infoxtec/infoxtec-escalas ~/infoxtec-escalas
cd ~/infoxtec-escalas/web && npm ci
```

Opcional, para usar o Claude Code no terminal do Linux:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

## 3. Banco de homologação

1. Em https://supabase.com/dashboard, crie o projeto `infoxtec-escalas-dev` (região São Paulo,
   plano Free) e anote o **Project ID** em **Project Settings → General**.
2. Gere um token em https://supabase.com/dashboard/account/tokens.
3. No Linux, com o Project ID **no lugar do texto, sem `<` e `>`**:

```bash
cd ~/infoxtec-escalas
npx supabase login
npx supabase link --project-ref IDDOPROJETODEV     # pede a senha do banco
npx supabase db push                               # aplica as migrations; confirme com Y
```

4. No **SQL Editor** do projeto dev, rode o conteúdo de `supabase/seed.sql`.
5. Em **Authentication → Users → Add user**, crie seu usuário com **Auto Confirm User** marcado.
   O e-mail do admin já é cadastrado em `painel_usuarios` pela migration 14; outros e-mails
   precisam ser incluídos lá.

**Não rode `setup/cron.sql` e não cadastre segredos da Evolution nem da Twilio no dev.**

## 4. Rodar o painel

Pegue a **Project URL** e a chave **anon/publishable** em **Project Settings → API** do dev:

```bash
cd ~/infoxtec-escalas/web
cat > .env.local <<'EOF'
VITE_SUPABASE_URL=https://IDDOPROJETODEV.supabase.co
VITE_SUPABASE_ANON_KEY=CHAVEANONDODEV
EOF
npm run dev -- --host
```

Abra `http://localhost:5173` (OrbStack) ou `http://IP-DA-MAQUINA:5173` (Multipass).
O `.env.local` está no `.gitignore` e nunca vai para o GitHub.

## Painel local na homologação ou na produção

Desde o painel 3.2, o repositório traz a configuração dos dois ambientes (`web/.env.homologacao` e
`web/.env.producao`, só com endereço e chave publicável). Não é preciso criar `.env.local`:

```bash
cd ~/infoxtec-escalas/web
npm run dev:homologacao     # faixa amarela no topo: dados fictícios
npm run dev:producao        # faixa vermelha no topo: dados reais, mensagens reais
```

Com a faixa vermelha, criar ou reenviar uma escala manda mensagem de verdade para o técnico.

### Painel no ar sem deixar o terminal aberto

O `npm run dev:...` vive dentro da janela: fechou a janela, o painel para. Para deixá-lo rodando
em segundo plano, use o script (desde o painel 3.3):

```bash
cd ~/infoxtec-escalas
./scripts/painel.sh iniciar             # homologação em http://localhost:5173
./scripts/painel.sh iniciar producao    # produção em http://localhost:5174 (dados reais)
./scripts/painel.sh status              # o que está no ar
./scripts/painel.sh log                 # acompanha a saída; Ctrl+C sai do log, não para o painel
./scripts/painel.sh parar               # para a homologação (ou: parar producao)
```

Depois de iniciar, pode fechar o terminal. O script instala as dependências novas sozinho quando
o `git pull` trouxer alguma. O painel para ao desligar a máquina Linux, ao fechar o OrbStack ou
quando o Mac dorme por muito tempo: é só rodar `iniciar` de novo.

O painel local é para teste. O painel sempre no ar, sem depender do Mac, é o da Vercel: a produção
em https://infoxtec-escalas.vercel.app e, para a homologação, o endereço de *preview* que aparece no
pull request.

## Problemas encontrados na primeira montagem

| Mensagem | Causa | Solução |
|---|---|---|
| `Homebrew on macOS is only supported on Apple Silicon processors!` | Mac Intel | Instalar pelo download direto, como acima |
| `syntax error near unexpected token 'newline'` | Os sinais `<` e `>` de um exemplo foram digitados | Colar só o valor |
| `Cannot find project ref. Have you run supabase link?` | O `link` falhou antes | Refazer o `link` com o Project ID correto |
| `relation "tecnicos" does not exist` | Seed rodado antes das migrations | Rodar `npx supabase db push` primeiro |
| `duplicate key ... painel_usuarios_pkey` | O admin já é criado pela migration 14 | Nada a fazer |
| `npm error Missing script: "dev:homologacao"` | O checkout local está numa versão antiga, sem o script | `cd ~/infoxtec-escalas && git fetch && git checkout <branch> && git pull` |
| Painel cai ao fechar o terminal | `npm run dev` roda preso à janela | `./scripts/painel.sh iniciar` |
| `Acesso não autorizado` no painel | E-mail do login diferente do de `painel_usuarios` | Usar o mesmo e-mail, em minúsculas |

## Cuidado com o `link`

O `npx supabase` age sobre o último projeto ligado com `link`. Antes de qualquer `db push`, confira:

```bash
cat supabase/.temp/project-ref
```

Se aparecer `zpckrxydqqmmcrphrkxz`, você está na **produção**.
