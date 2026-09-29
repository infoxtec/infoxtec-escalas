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

## Subir tudo com um comando

Um comando sobe o painel e o harness:

```bash
cd ~/infoxtec-escalas
./scripts/ambiente-dev.sh iniciar            # painel (5173) + harness (3080)
./scripts/ambiente-dev.sh iniciar producao   # painel apontando para a produção (dados reais)
./scripts/ambiente-dev.sh status             # o que está no ar, em que porta
./scripts/ambiente-dev.sh parar painel       # para o painel
```

O painel continua sendo cuidado pelo `scripts/painel.sh` (instala dependências novas, cuida do pid e
do log); este script acrescenta o harness e o diagnóstico dos dois juntos.

**`parar harness` encerra a sessão que você estiver usando** — o script pede a palavra `HARNESS` para
confirmar, e não para o painel junto.

## Sem interação humana: serviços do systemd

Para o painel e o harness subirem sozinhos quando a máquina Linux liga, sem ninguém abrir terminal:

```bash
./scripts/ambiente-dev.sh instalar       # instala e já sobe os dois
./scripts/ambiente-dev.sh status         # confere
journalctl --user -u dsh-web -f          # log do harness
systemctl --user restart painel-dev      # reiniciar só o painel
```

O que ele faz: liga `infra/dev/painel-dev.service` e `infra/dev/dsh-web.service` em
`~/.config/systemd/user/`, habilita e inicia. Os dois **reiniciam sozinhos** se caírem
(`Restart=on-failure`), e o log vai para o journal — melhor que um `nohup` sem supervisão.

**Funciona sem login**, porque o *linger* do usuário está ligado:

```bash
loginctl show-user macbookair -p Linger      # Linger=yes
```

Sem o linger, serviço de usuário só roda com sessão aberta. Se algum dia voltar a `no`:
`sudo loginctl enable-linger macbookair`.

Para desfazer: `./scripts/ambiente-dev.sh desinstalar`.

## Depois de reiniciar o computador

**O passo 3 é uma vez só.** Depois dele os serviços sobem sozinhos, e este roteiro encolhe para os
passos 1, 4 e 5.

**1. No Mac: OrbStack e a máquina Linux no ar.** Se o OrbStack não abriu sozinho, abra-o. Se a máquina
`dev` não voltou, no terminal do Mac: `orb start dev`.

**2. Dentro do Linux, atualize o repositório:**

```bash
cd ~/infoxtec-escalas && git checkout main && git pull
```

**3. Instale os serviços (uma vez só):**

```bash
./scripts/ambiente-dev.sh instalar
```

Liga `painel-dev` e `dsh-web` e já sobe os dois. **A partir daqui, todo reinício é automático** — os
passos 2 e 3 só voltam quando você quiser atualizar o código.

**4. Confira:**

```bash
./scripts/ambiente-dev.sh status
```

Esperado: painel na 5173, harness na 3080, e os dois serviços como `habilitado, active`.

**5. No navegador do Mac:**

- painel na **homologação**: http://localhost:5173
- harness: o endereço **com token** que o serviço imprime no log:

```bash
journalctl --user -u dsh-web -n 40 | grep -i http
```

O endereço pode mudar quando o serviço reinicia — confira o atual em vez de usar um favorito antigo.

### Se algo não subir

```bash
systemctl --user status painel-dev dsh-web    # o que falhou, e por quê
journalctl --user -u painel-dev -n 30         # o log do painel
```

Se o `git pull` trouxe dependências novas (o `package-lock.json` mudou), o painel pode subir com a
versão antiga do `node_modules`. O caminho:

```bash
cd ~/infoxtec-escalas/web && npm ci && systemctl --user restart painel-dev
```

**Se você rodar `instalar` com um harness já aberto à mão**, o `dsh-web` falha com *address already in
use*: a porta 3080 está ocupada. Ou reinicie a máquina, ou pare o manual antes
(`./scripts/ambiente-dev.sh parar harness` — ele pede a palavra `HARNESS`, porque isso encerra a sessão).

## O que só se resolve no Mac (OrbStack)

**Esta máquina Linux é convidada do OrbStack, e o OrbStack roda no macOS.** Nada aqui dentro consegue
iniciá-lo: se ele não estiver no ar, as portas 5173 e 3080 não aparecem no navegador do Mac, mesmo
com os dois serviços rodando perfeitamente nesta máquina.

No Mac:

1. **OrbStack → Settings → Start at login** — para o OrbStack abrir sozinho.
2. Confirme que a máquina **`dev`** volta sozinha. O OrbStack religa as máquinas que estavam rodando
   quando ele fechou; se não voltar, `orb start dev` no terminal do Mac resolve — e dá para criar um
   item de login do macOS que rode esse comando.
3. As portas chegam ao Mac pelo encaminhamento do próprio OrbStack: o `localhost` do Mac aponta para
   o `127.0.0.1` desta máquina. Não há redirecionamento a configurar.

**A divisão:** o Mac liga o OrbStack e esta máquina; os serviços do systemd cuidam de tudo o que roda
dentro dela. Uma coisa não substitui a outra.

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
