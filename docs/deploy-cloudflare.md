# Painel da homologação no Cloudflare (etapa 17, decisão 110)

> **No ar:** https://trilha-homologacao.david-cerqueira.workers.dev — Worker `trilha-homologacao` (arquivos estáticos, `web/wrangler.jsonc`).
> **Produção fica na Vercel** (https://infoxtec-escalas.vercel.app). O build escolhe o banco sozinho
> (`npm run build:homologacao` lê `web/.env.homologacao` e aborta se a URL for de outro banco): **nenhuma variável de
> ambiente no Cloudflare**, e a chave da produção nunca entra neste Worker.

## Painel da produção: Worker `trilha` (A3 da sprint 04–17/11, decisão 133)

Dois painéis no Cloudflare: **homologação** em https://trilha-homologacao.david-cerqueira.workers.dev (banco
`infoxtec-escalas-dev`) e **produção** em https://trilha.david-cerqueira.workers.dev (banco `infoxtec-escalas`). O build
de cada um só aceita o seu banco (`web/vite.config.ts` aborta se a URL for de outro), e nenhum dos dois tem variável no
Cloudflare. As Edge Functions da produção aceitam o Worker `trilha` por nome exato desde o A1.

**Criar o Worker (responsável, uma vez):** Workers & Pages → Create → Import a repository → `infoxtec/infoxtec-escalas`.

| Campo | Valor |
|---|---|
| Project name | `trilha` (precisa ser exatamente este: é o endereço que as Edge Functions aceitam) |
| Production branch | `main` (sem efeito: **Disable builds ligado**, A2). Quem publica é o workflow Aplicar, com destino `producao` e painel `sim`, depois da aprovação, usando o segredo `CLOUDFLARE_API_TOKEN` do ambiente `producao` |
| Build command | `cd web && npm ci && npm run build:producao` |
| Deploy command | `npx --yes wrangler@4.151.3 deploy --config wrangler.producao.jsonc` |
| Root directory | vazio (raiz; o comando entra em `web/` sozinho) |
| Non-production branch builds / Previews | **desligado** (a produção não tem pré-visualização) |
| Variáveis | nenhuma |

**Conferência:** abrir https://trilha.david-cerqueira.workers.dev — a tela de login aparece, o rodapé mostra a mesma
versão da Vercel, e o login com a conta da produção funciona (o Supabase da produção já tem o endereço nas Redirect
URLs, A1). Até a virada (A5, 10/11) ninguém usa este endereço: o oficial continua sendo a Vercel.

## 1. Configuração do Worker (Settings → Build)

| Campo | Valor |
|---|---|
| Root directory | `web` (o Cloudflare ignora neste Worker; o comando de build é que entra em `web/`) |
| Build command | `cd web && npm ci && npm run build:homologacao` |
| Deploy command | `npx --yes wrangler@4.151.3 deploy` (versão fixa: sem ela, cada build baixa a mais nova; revisão de 25/10) |
| Aba "Previews Base": Root directory | `web` |
| Aba "Previews Base": Build command | `cd web && npm ci && npm run build:homologacao` (igual ao da aba Production) |
| Aba "Previews Base": Preview command | o build roda `npx wrangler preview` (Worker Previews), que exige o bloco `previews` no `wrangler.jsonc` (já está, vazio) |
| Variáveis | nenhuma |

O nome em `web/wrangler.jsonc` precisa ser o do Worker (`trilha-homologacao`). **O Cloudflare ignora o Root directory
neste Worker** (25/10: o build rodava na raiz mesmo com `web` nas duas abas): por isso o comando de build entra em `web/`
sozinho e a raiz tem um `wrangler.jsonc` igual ao de `web/`, apontando para `web/dist`. Mudança em um dos dois
`wrangler.jsonc` vai também no outro. **Nunca pôr `package.json` na raiz:** o Deno passa a exigir `node_modules` e o
`deno check` (e o deploy das Edge Functions) quebra com `Could not find a matching package for 'npm:postgres'`. Cada PR ganha uma versão de
pré-visualização (`<versão>-trilha-homologacao.david-cerqueira.workers.dev`), sempre com o banco da homologação.

## 2. Supabase da homologação: login

Projeto **infoxtec-escalas-dev** → **Authentication → URL Configuration**:
- **Site URL:** `https://trilha-homologacao.david-cerqueira.workers.dev`
- **Redirect URLs** (acrescentar; as da Vercel saem quando ela for desligada):

```
https://trilha-homologacao.david-cerqueira.workers.dev/**
https://*-trilha-homologacao.david-cerqueira.workers.dev/**
```

**Tirar**, se tiverem sido cadastradas pelo roteiro antigo, `https://trilha-homologacao.pages.dev/**` e
`https://*.trilha-homologacao.pages.dev/**`: o nome `pages.dev` não é nosso e qualquer conta poderia registrá-lo e
receber links de convite e de troca de senha (revisão do `seguranca`).

## 3. Conferência

- `https://trilha-homologacao.david-cerqueira.workers.dev` abre o login com a faixa de **homologação**; `/ponto` abre o app do ponto.
- Troca de senha e convite chegam com o link no endereço novo.
- Leitura de documento (OCR) funciona depois de publicar a `documento-ocr` na homologação.
- Links do WhatsApp da homologação (espelho, ponto) abrem no endereço novo depois do `app_url` trocado.

## 4. Se o build falhar

Deployments → o build → View logs: copiar as últimas 30 linhas para o Claude. Causas já vistas: Root directory vazio
(`Could not read package.json`; desde 25/10 o Cloudflare ignora o campo neste Worker, ver acima), nome do Worker diferente do `web/wrangler.jsonc`, Worker apagado com a ligação ao
GitHub ainda ativa (`This Worker does not exist on your account`).

## Pendências

- ~~Desligar o projeto `infoxtec-escalas-homologacao` da Vercel~~ *(pausado em 25/10, não apagado: fica de reserva para
  emergência; o endereço dele segue liberado no CORS da `documento-ocr` e saiu das Redirect URLs do login)*. **Se for apagado, tirar o endereço do CORS da
  `documento-ocr` no mesmo dia** (o nome fica livre para outra conta registrar).
- Fechar as pré-visualizações com Cloudflare Access e CSP em modo Report-Only.
- Produção continua na Vercel (decisão 110). Domínio próprio e migração da produção ficam para depois; o projeto da
  Vercel da produção nunca é apagado (QR dos espelhos assinados).
- **Não renomear nem liberar o subdomínio `david-cerqueira.workers.dev`** enquanto as Edge Functions confiarem nele
  (`ORIGEM_PAINEL` da produção e `ORIGEM_HOMOLOGACAO_CF`, decisão 133): outra conta poderia registrá-lo.
- **PWA (painel 3.68.0):** `manifest.webmanifest` (painel) e `manifest-ponto.webmanifest` (app do ponto, início em
  `/ponto`), trocados por um script curto no `index.html`. Sem service worker (o painel confere a versão publicada e
  um cache local esconderia a versão nova). O script fica em `public/manifesto.js` (B1), para a CSP aceitar só scripts do próprio site.
- **CSP em observação (B1, painel 3.69.0, decisão 133):** `Content-Security-Policy-Report-Only` no `web/public/_headers`
  (os dois Workers). Só registra no console do navegador, não bloqueia. Libera: scripts e estilos do próprio site; os
  dois bancos do Supabase (`connect-src`, `img-src`); o verificador de senha vazada (`api.pwnedpasswords.com`); o OCR
  no navegador servido pelo **próprio site** (`/ocr`: worker, motor LSTM e português, copiados do `node_modules` por
  `web/scripts/copiar-ocr.mjs` em todo build; fora do Git), com WebAssembly (`wasm-unsafe-eval`). Nenhum CDN. Passa a
  valer de fato (troca para `Content-Security-Policy`) depois do roteiro de teste sem aviso; antes disso, um coletor de
  relatórios (`report-uri`) para ver o navegador dos técnicos (P2 do `seguranca`).

