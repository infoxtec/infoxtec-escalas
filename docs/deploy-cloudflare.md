# Painel da homologação no Cloudflare (etapa 17, decisão 110)

> **No ar:** https://trilha-homologacao.david-cerqueira.workers.dev — Worker `trilha-homologacao` (arquivos estáticos, `web/wrangler.jsonc`).
> **Produção fica na Vercel** (https://infoxtec-escalas.vercel.app). O build escolhe o banco sozinho
> (`npm run build:homologacao` lê `web/.env.homologacao` e aborta se a URL for de outro banco): **nenhuma variável de
> ambiente no Cloudflare**, e a chave da produção nunca entra neste Worker.

## 1. Configuração do Worker (Settings → Build)

| Campo | Valor |
|---|---|
| Root directory | `web` |
| Build command | `npm run build:homologacao` |
| Deploy command | `npx wrangler deploy` |
| Aba "Previews Base": Root directory | `/web` (a aba é separada: sem ela o build de PR roda na raiz e falha) |
| Aba "Previews Base": Preview command | `npx wrangler versions upload` (botão "Builds for Preview branches" ligado) |
| Variáveis | nenhuma |

O nome em `web/wrangler.jsonc` precisa ser o do Worker (`trilha-homologacao`). Cada PR ganha uma versão de
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
(`Could not read package.json`; em 25/10 foi o da aba Previews Base, que não herda o da aba Production), nome do Worker diferente do `web/wrangler.jsonc`, Worker apagado com a ligação ao
GitHub ainda ativa (`This Worker does not exist on your account`).

## Pendências

- Desligar o projeto `infoxtec-escalas-homologacao` da Vercel depois de uma semana sem problema (até 31/10).
- Fechar as pré-visualizações com Cloudflare Access e CSP em modo Report-Only.
- Produção continua na Vercel (decisão 110). Domínio próprio e migração da produção ficam para depois; o projeto da
  Vercel da produção nunca é apagado (QR dos espelhos assinados).
