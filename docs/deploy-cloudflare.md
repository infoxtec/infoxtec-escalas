# Painel no Cloudflare Pages (etapa 17)

> **Fase 1 (agora): só a homologação**, no endereço gratuito `https://trilha-homologacao.pages.dev`.
> A produção continua na Vercel. Depois da homologação aprovada vem a produção (`trilha-producao`), e só então o
> domínio próprio `trilha.infoxtec.com.br` (CNAME, sem levar o DNS para o Cloudflare).
> O build já escolhe o banco sozinho (`npm run build:homologacao` lê `web/.env.homologacao`): **nenhuma variável de
> ambiente precisa ser cadastrada no Cloudflare**, e a chave da produção nunca entra neste projeto.

## 1. Criar o projeto (uma vez)

1. Cloudflare → **Workers & Pages → Create → aba Pages → Connect to Git** (não usar "Create Worker": essa tela é
   do Workers e não serve aqui). Se aparecer só Workers, procurar o link **"Looking to deploy Pages? Get started"**.
2. Autorizar o app do Cloudflare no GitHub **só no repositório `infoxtec/infoxtec-escalas`**.
3. **Project name:** `trilha-homologacao` (exatamente; o CORS da leitura de documento usa este nome).
4. **Production branch:** `main`.
5. **Build settings:**

   | Campo | Valor |
   |---|---|
   | Framework preset | `None` |
   | Build command | `npm run build:homologacao` |
   | Build output directory | `dist` |
   | Root directory (advanced) | `web` |
   | Environment variables | nenhuma |

6. **Save and Deploy.** O primeiro build leva de 2 a 4 minutos. A versão do Node vem de `web/.node-version` (22).

Cada branch e cada pull request ganham uma pré-visualização (`<branch>.trilha-homologacao.pages.dev`), sempre
com o banco da homologação.

## 1b. Se o projeto foi criado como Worker (`trilha-homologacao`)

Também funciona: `web/wrangler.jsonc` publica só os arquivos estáticos, com o mesmo `_headers` e a volta ao
`index.html` em qualquer caminho (`/ponto`). No Worker → **Settings → Build**: Root directory `web`, Build command
`npm run build:homologacao`, Deploy command `npx wrangler deploy`, nenhuma variável. O endereço fica
`https://trilha-homologacao.<sua-conta>.workers.dev` (o nome em `web/wrangler.jsonc` precisa ser o do Worker); o CORS da leitura de documento e o login do Supabase usam esse
endereço exato.

## 2. Supabase da homologação: login

Projeto **infoxtec-escalas-dev** → **Authentication → URL Configuration → Redirect URLs**, acrescentar (sem tirar
as da Vercel):

```
https://trilha-homologacao.pages.dev/**
https://*.trilha-homologacao.pages.dev/**
```

## 3. Conferência

- `https://trilha-homologacao.pages.dev` abre o login com a faixa de **homologação**; entrar com o seu usuário.
- `https://trilha-homologacao.pages.dev/ponto` abre o app do ponto (o Renato marca com geolocalização).
- Carimbo de versão no topo igual ao da Vercel da homologação.
- Leitura de documento (OCR) só funciona depois de publicar a `documento-ocr` na homologação (o roteiro do PR traz o
  comando).

## 4. Se o build falhar

Copiar as últimas 30 linhas do log do build (Deployments → o deploy → View details) e mandar para o Claude.
Causas comuns: Root directory sem `web`, Build command `npm run build` (sem `:homologacao`, o painel sobe sem banco)
ou projeto criado como Worker.

## Pendências da etapa 17

- Fechar as pré-visualizações com Cloudflare Access (e-mails do responsável) e CSP em modo Report-Only.
- Produção: projeto `trilha-producao`, `npm run build:producao`, pré-visualizações desligadas, só por comando.
- Domínio próprio, migration nova do `app_url` e redirecionamento permanente do `infoxtec-escalas.vercel.app`
  (nunca apagar o projeto da Vercel: os QR dos espelhos assinados apontam para ele).
