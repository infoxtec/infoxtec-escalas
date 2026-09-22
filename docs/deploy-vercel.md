# Publicar o painel no Vercel

> **Endereço de produção:** https://infoxtec-escalas.vercel.app
> O projeto no Vercel usa **Root Directory `web`**. O carimbo de versão no topo do painel
> (ex.: `v1.3 · 22/09 16:40`) diz qual build está no ar.

## 1. Supabase: login por e-mail e senha

No painel do Supabase, projeto **infoxtec-escalas**:

1. **Authentication → Sign In / Providers → Email**: deixe **Email** ligado.
2. Na mesma tela, **desligue "Allow new users to sign up"**. So entra quem for convidado.
3. **Authentication → URL Configuration**:
   - **Site URL**: `https://infoxtec-escalas.vercel.app` (já configurado)
   - **Redirect URLs**: `https://infoxtec-escalas.vercel.app/**` (já configurado)
   Sem isso, os links de convite e de "esqueci a senha" abrem no lugar errado.

## 2. GitHub

Suba o conteudo do pacote para o repositorio `infoxtec-escalas` (privado). A pasta `web/` e o painel.

## 3. Vercel

No projeto `infoxtec-escalas` do Vercel:

1. **Settings → Git**: conecte ao repositorio do GitHub.
2. **Settings → Build & Deployment**:
   - **Root Directory**: `web`
   - **Framework Preset**: Vite (o Vercel detecta sozinho)
3. **Settings → Environment Variables** (Production e Preview):

   | Nome | Valor |
   |---|---|
   | `VITE_SUPABASE_URL` | `https://zpckrxydqqmmcrphrkxz.supabase.co` |
   | `VITE_SUPABASE_ANON_KEY` | `sb_publishable__OGrWORMd_gTj5PL_tqjfA_xda9Kddt` |

   A chave publicavel e feita para ficar no navegador; a seguranca esta nas permissoes do banco.
4. **Deployments → Redeploy** (variaveis so valem a partir do proximo deploy).

## 4. Primeiro acesso

1. Supabase → **Authentication → Users → Invite user** → seu e-mail.
2. Abra o e-mail, clique no link: o painel abre pedindo para criar a senha.
3. Seu e-mail ja esta como **admin** em `painel_usuarios`, entao o painel abre completo.

## 5. Liberar mais alguem

1. Supabase → Authentication → Users → **Invite user** → e-mail da pessoa.
2. No painel, aba **Usuarios** → **Adicionar usuario** → mesmo e-mail e o papel.

Quem tem login mas nao esta na aba Usuarios ve "Acesso nao autorizado".

## Observacao sobre e-mails

O servidor de e-mail padrao do Supabase envia poucas mensagens por hora e serve para convites
eventuais. Se um convite nao chegar, confira o spam ou aguarde alguns minutos.
