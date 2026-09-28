# Segurança

## Camadas

1. **Autenticação** — Supabase Auth, e-mail e senha. Cadastro público desligado: só entra quem
   for convidado em Authentication → Users.
2. **Autorização** — tabela `painel_usuarios`, papéis `admin`, `gestor` e `leitura`.
3. **Execução** — o navegador só chama funções `app_*`. Cada uma lê o e-mail de `auth.jwt()`,
   confere o papel e só então executa. A tela nunca informa quem é o usuário.

| Papel | Pode |
|---|---|
| `leitura` | Ver agenda, histórico, técnicos e locais |
| `gestor` | + criar escalas, mudar status, remover escala não recebida, reenviar, editar cadastros |
| `admin` | + excluir técnicos definitivamente e gerenciar usuários do painel |

Quem faz login e não está em `painel_usuarios` vê "Acesso não autorizado".

## O que está fechado

- `revoke execute on all functions ... from public, anon, authenticated` — só as `app_*` têm
  permissão explícita.
- Todas as tabelas com RLS ligado e **sem políticas**: nada é legível pela API pública.
- Views revogadas para `anon` e `authenticated`.
- Todas as funções `app_*` com `search_path` fixo. **Ressalva honesta:** 26 funções antigas foram
  criadas sem isso (S12 na [análise de segurança](analise-seguranca.md)) — hoje não é explorável,
  mas é dívida de endurecimento.
- A chave publicável do Supabase fica no navegador **por design**; sem login ela não abre nada.

## Segredos

| Nome | Onde | Quem lê | Rotação |
|---|---|---|---|
| `EVOLUTION_API_KEY` | Supabase Vault | `fn_evo_post` / `fn_evo_get`, via `fn_segredo` | **Pendente**: esteve exposta 3 h 14 em 21/09 (tema SEG-01) |
| `WEBHOOK_TOKEN` | Supabase Vault **e** a URL registrada na Evolution | `fn_webhook_evolution`, ao validar a chamada | Pendente por precaução (SEG-02) |
| `VOZ_TOKEN` | Supabase Vault | motor (`net.http_post`) e Edge Function `voz-escala` | Nunca exposto; calendário semestral |
| `TWILIO_AUTH_TOKEN` | Supabase Vault | `voz-escala` (Basic auth e assinatura) | Nunca exposto |
| `TWILIO_ACCOUNT_SID` | Supabase Vault | `voz-escala` | Não é rotável — é identificador |
| Senha do banco | Gerenciador de senhas | `scripts/`, `psql` e a cópia de segurança | Rotacionada em 27/09; ao trocar, atualizar `PRODUCAO_DB_URL` no GitHub |

Inventário conferido em 27/09 **pelo próprio Vault** (`select name, created_at, updated_at from
vault.secrets`): são esses cinco, e o `GOOGLE_VISION_KEY` não existe porque o OCR na nuvem nunca foi
ligado. `TWILIO_ASSINATURA` não é segredo, é interruptor, e vive nas variáveis de ambiente da função
— hoje em modo observação (SEG-05).

Nenhum segredo está no repositório. O log de webhook remove a `apikey` antes de gravar. O
procedimento de troca de cada um, com o que pode quebrar, está em
[rotacao-de-segredos.md](rotacao-de-segredos.md).

## Webhook

URL pública protegida por token de 64 caracteres na query string. Token errado recebe 401 e não
chega ao banco. Eventos duplicados são descartados pela unicidade de `respostas.wa_message_id`.

## Dados pessoais (LGPD)

O sistema guarda nome, telefone e histórico de escalas de empregados. Pontos relevantes:

- `opt_in` registra a autorização para envio de mensagens, com data.
- A exclusão definitiva de técnico apaga o histórico dele e registra em `log_exclusoes`
  **sem** nome ou telefone.
- O log de webhook guarda o conteúdo das mensagens recebidas: limpe periodicamente (30 dias).
- **Não há dado de saúde na recusa de escala.** O motivo de saúde saiu do sistema em 28/09 (decisão
  40, migration 49) — o técnico escolhe entre transporte, conflito de agenda, falta de material e
  outro. O atestado médico, quando existir, será tratado **só** no módulo de ponto, com janela de
  48 h e visibilidade própria (decisão 39).
- Retenção em vigor: **30 dias** (log de webhook), **90 dias** (conteúdo enviado e alertas),
  **7 dias** (histórico do cron) e **5 anos** para documentos após o desligamento. Só esses — as
  demais tabelas crescem sem prazo, e isso é o tema **SEG-10**.

## Documentos dos técnicos

Bucket privado `documentos`: criptografia em repouso (AES-256), sem URL pública, link assinado de
2 minutos por abertura, políticas de acesso por papel no próprio banco e trilha de quem enviou
cada arquivo. Retenção de 5 anos após o desligamento (`tecnicos.desligado_em`), com
`vw_documentos_expirados` apontando o que já passou do prazo.

Desde 28/09 (decisão 41) **não existe mais vínculo por link do Google Drive**: todo documento passa
pelo bucket, o que devolve ao sistema o controle de acesso e de retenção. Vínculos antigos, se
existirem, continuam listados — a limpeza deles é o tema **SEG-14**.

O Supabase mantém ISO/IEC 27001 e SOC 2 Tipo 2 para a infraestrutura. Certificação é da
organização, não do código: o que o projeto entrega é o desenho seguro; a conformidade da Infoxtec
depende de política interna, contrato com os titulares e processo de resposta a incidentes.

## Riscos conhecidos

| Risco | Situação |
|---|---|
| `EVOLUTION_API_KEY` e `WEBHOOK_TOKEN` sem rotação | **Aberto** (SEG-01 e SEG-02). A chave da Evolution esteve exposta 3 h 14 em 21/09 |
| Sem MFA nas contas administrativas | **Aberto** (SEG-04). É a primeira pergunta de qualquer questionário de cliente |
| Papel `leitura` e os documentos | **Aberto** (SEG-14): o papel vê o nome e a existência dos arquivos, inclusive ASO |
| Token do webhook e da URA na query string | **Aberto** (SEG-05): o segredo aparece no log da Evolution, do proxy e da Twilio |
| Banimento do número na Evolution | Aceito e mitigado (limites e chip dedicado). Sem plano B automático |
| VPS da Evolution | Fora do Supabase; backup e atualização são responsabilidade da Infoxtec |
| ~~Painel Retool ainda ativo~~ | **Resolvido em 27/09**: senha do banco trocada e conexão apagada (etapa 16) |
| ~~`xlsx` 0.18.5 com alertas conhecidos~~ | **Resolvido em 27/09**: 0.20.3 oficial em `web/vendor/`, com o CI bloqueando vulnerabilidade alta (decisão 37) |

**Revisado em 28/09/2026.** Esta tabela é o resumo; a análise completa, com evidência por achado,
severidade e as pendências de LGPD, está em [analise-seguranca.md](analise-seguranca.md). O que
responder a um cliente está em [evidencias-seguranca.md](evidencias-seguranca.md).
