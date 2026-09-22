# Infoxtec Escalas

Gestao de escalas da equipe tecnica de campo com notificacao e confirmacao via WhatsApp.

O gestor cadastra a escala no painel (um ou varios tecnicos de uma vez). Em ate um minuto o
tecnico recebe no WhatsApp a escala completa com dois botoes — "Ciente, confirmado" e
"Tenho um problema" — ou pode responder 1 ou 2. A resposta volta sozinha para o painel.
Sem resposta, o sistema manda lembrete a cada 30 minutos (ate 3 envios) e aciona os supervisores.

## Stack

| Camada | Ferramenta | Custo |
|---|---|---|
| Painel | App React proprio (pasta `web/`), hospedado no Vercel | R$ 0 |
| Login | Supabase Auth (e-mail e senha) | R$ 0 |
| Banco, regras, agendamento, segredos | Supabase free: Postgres, pg_cron, pg_net, Vault | R$ 0 |
| Webhook | Supabase Edge Function `webhook-evolution` | R$ 0 |
| WhatsApp | Evolution API 2.4.0 em VPS propria (instancia `infoxtec`) | VPS |

Projeto Supabase: `infoxtec-escalas` (ref `zpckrxydqqmmcrphrkxz`, sa-east-1).
Painel: app React em `web/` publicado no Vercel (o Retool fica como legado ate ser desligado).

## Fluxo

```
Painel web --(app_criar_escalas, com o login do usuario)--> escalas [agendada]
pg_cron (1/min) --> fn_dispatcher_whatsapp
    FASE 1  confere resposta da Evolution -> enviada + ID real, ou falha
    FASE 2  envia o que vw_acoes_pendentes mandar (botoes; reenvio de falha em texto)
    FASE 3  alerta supervisores (escalonar)
Evolution --webhook--> Edge Function --> fn_webhook_evolution
    messages.update  -> entregue / lida
    messages.upsert  -> botao ou 1/2 -> confirmada / recusada, respostas automaticas
```

Toda regra de negocio mora em SQL. A view `vw_acoes_pendentes` decide o que fazer; o
dispatcher so executa. Parametros ficam na tabela `config`:

| Chave | Padrao | Efeito |
|---|---|---|
| `intervalo_reenvio_min` | 30 | Minutos entre lembretes |
| `max_tentativas` | 3 | Envios por escala antes de escalonar |
| `avisar_supervisor_na` | 2 | Tentativa que aciona o supervisor |
| `janela_envio_inicio` / `_fim` | 06:00 / 21:00 | Nada e enviado fora da janela |
| `usar_botoes` | true | false = so texto com opcoes 1/2 |
| `webhook_ativo` | true | false = sem lembretes por falta de resposta |
| `envios_por_execucao` | 3 | Espacamento entre envios |

## Controle de acesso

- **Autenticacao**: Supabase Auth, e-mail e senha. Cadastro publico desligado: so entra quem
  for convidado em Authentication > Users > Invite user.
- **Autorizacao**: tabela `painel_usuarios` com papeis `admin`, `gestor` e `leitura`.
- O app web so chama funcoes `app_*` (migration 16). Cada uma identifica o usuario pelo token
  de login (`auth.jwt()`), confere o papel e so entao executa. Nenhum parametro da tela diz
  quem e o usuario.
- Sem login, nenhuma funcao responde; tabelas tem RLS sem politicas; views fechadas para anon.
- A chave publicavel do Supabase fica no navegador por design; a seguranca esta no banco.

## Segredos

Nada sensivel neste repositorio. Ver `supabase/setup/segredos.md`.

## Estrutura

```
supabase/
  migrations/                 espelho exato do banco (01 a 14)
  functions/webhook-evolution Edge Function do webhook
  setup/                      config por ambiente, cron e segredos (rodar uma vez)
  seed.sql                    dados ficticios
web/                          painel React (Vite + TypeScript + Tailwind)
docs/
  deploy-vercel.md            publicar o painel e liberar usuarios
  retool.md                   painel antigo (legado)
```


## Montar em um projeto novo

1. `supabase link --project-ref <ref>` e `supabase db push`
2. `supabase functions deploy webhook-evolution --no-verify-jwt`
3. Rodar `supabase/setup/config.sql` (ajustando a URL) e criar os segredos
4. Configurar o webhook na Evolution (comando em `segredos.md`)
5. Rodar `supabase/setup/cron.sql`

## Observacao sobre a importacao de planilhas

A importacao usa `xlsx` 0.18.5 (ultima versao publicada no npm), que tem alertas conhecidos para
arquivos maliciosos. Como so gestores logados importam planilhas proprias, o risco e baixo.

## Historico

- [x] Banco, painel, envio pela Evolution com botoes
- [x] Webhook: entrega, leitura, confirmacao, recusa e detalhe do problema
- [x] Lembretes de 30 em 30 minutos e alerta aos supervisores
- [x] Exclusao definitiva de tecnico e escala para varios tecnicos
- [x] Controle de acesso por papel no banco
- [x] Painel proprio no Vercel com login, papeis, aba Usuarios, ordenacao, remover e reenviar escala
- [ ] Desligar o painel Retool
- [ ] Piloto com a equipe
