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
- Todas as funções com `search_path` fixo.
- A chave publicável do Supabase fica no navegador **por design**; sem login ela não abre nada.

## Segredos

| Nome | Onde | Quem lê |
|---|---|---|
| `EVOLUTION_API_KEY` | Supabase Vault | `fn_segredo`, dentro do banco |
| `WEBHOOK_TOKEN` | Supabase Vault | `fn_webhook_evolution`, ao validar a chamada |
| Senha do banco | Só no Retool (legado) | — |

Nenhum segredo está no repositório. O log de webhook remove a `apikey` antes de gravar.

## Webhook

URL pública protegida por token de 64 caracteres na query string. Token errado recebe 401 e não
chega ao banco. Eventos duplicados são descartados pela unicidade de `respostas.wa_message_id`.

## Dados pessoais (LGPD)

O sistema guarda nome, telefone e histórico de escalas de empregados. Pontos relevantes:

- `opt_in` registra a autorização para envio de mensagens, com data.
- A exclusão definitiva de técnico apaga o histórico dele e registra em `log_exclusoes`
  **sem** nome ou telefone.
- O log de webhook guarda o conteúdo das mensagens recebidas: limpe periodicamente (30 dias).

## Riscos conhecidos

| Risco | Situação |
|---|---|
| Banimento do número na Evolution | Aceito e mitigado (limites e chip dedicado). Sem plano B automático |
| Painel Retool ainda ativo | Quem tem acesso de edição lá executa SQL no banco. Desligar |
| `xlsx` 0.18.5 com alertas conhecidos | Aceito: só gestores logados importam planilhas próprias |
| VPS da Evolution | Fora do Supabase; backup e atualização são responsabilidade da Infoxtec |
