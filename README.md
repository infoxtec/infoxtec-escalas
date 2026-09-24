# Infoxtec Escalas

Gestão de escalas da equipe técnica de campo, com envio e confirmação pelo WhatsApp.

O gestor cadastra a escala no painel, para um ou vários técnicos. Em até um minuto o técnico
recebe no WhatsApp a escala completa — data, horário com término pela jornada CLT, local,
endereço, mapa e tarefa — com dois botões, "Ciente, confirmado" e "Tenho um problema", e a
alternativa de responder 1 ou 2. A resposta volta sozinha para o painel. Sem resposta, o sistema
reenvia a cada 30 minutos, até 3 vezes, e aciona os supervisores. Todo dia às 16h os supervisores
são lembrados da escala do dia seguinte, com prazo às 18h.

## Documentação

| Documento | Para quê |
|---|---|
| [**Manual de uso**](docs/manual.md) | **Tela a tela: o que cada botão faz e o que o técnico recebe** |
| [Arquitetura](docs/arquitetura.md) | Como as peças se encaixam e por que o banco é o centro |
| [Banco de dados](docs/banco-de-dados.md) | Tabelas, views, funções, gatilhos e parâmetros |
| [Operação](docs/operacao.md) | Diagnóstico do dia a dia: o que consultar quando algo falha |
| [Segurança](docs/seguranca.md) | Login, papéis, segredos, LGPD e riscos conhecidos |
| [Decisões](docs/decisoes.md) | O que foi decidido, o que foi descartado e por quê |
| [Backlog](docs/backlog.md) | Análise de viabilidade dos 13 itens planejados (o quadro vive na aba Roadmap) |
| [Agente de IA](docs/agente-ia.md) | Roteiro para predições: instrumentar, consultar, prever, sugerir |
| [Telefonia (item 2)](docs/telefonia.md) | URA de voz: fornecedor, custos, script e resultado do piloto |
| [Publicar no Vercel](docs/deploy-vercel.md) | Passo a passo do deploy e da liberação de usuários |
| [Retool (legado)](docs/retool.md) | Painel antigo, a ser desligado |

## Stack

| Camada | Tecnologia | Custo |
|---|---|---|
| Painel | React 18 + TypeScript + Vite + Tailwind, na Vercel | R$ 0 |
| Login | Supabase Auth (e-mail e senha) | R$ 0 |
| Banco, regras, agendamento, segredos | Supabase: PostgreSQL, pg_cron, pg_net, Vault | R$ 0 |
| Webhooks | Supabase Edge Functions (Deno): `webhook-evolution` e `voz-escala` | R$ 0 |
| Ligação de voz | Twilio (URA) | ~R$ 0,24 por ligação |
| WhatsApp | Evolution API 2.4 em VPS própria | custo da VPS |

Painel em produção: **https://infoxtec-escalas.vercel.app**
Projeto Supabase: `infoxtec-escalas` (ref `zpckrxydqqmmcrphrkxz`, região sa-east-1).

## Estrutura

```
web/                          painel React (o que vai para a Vercel, Root Directory = web)
supabase/
  migrations/                 01 a 18 — espelho exato do banco
  functions/webhook-evolution Edge Function que recebe os eventos da Evolution
  setup/                      config por ambiente, cron e segredos (rodar uma vez)
  seed.sql                    dados fictícios para desenvolvimento
docs/                         a documentação da tabela acima
```

## Montar em um projeto novo

```bash
supabase link --project-ref <ref>
supabase db push
supabase functions deploy webhook-evolution --no-verify-jwt
```

Depois: rodar `supabase/setup/config.sql`, criar os segredos conforme
`supabase/setup/segredos.md`, apontar o webhook na Evolution e rodar `supabase/setup/cron.sql`.
O painel é publicado pela Vercel com Root Directory `web` e as duas variáveis de ambiente.

## Histórico

- [x] Banco, painel, envio pela Evolution com botões
- [x] Webhook: entrega, leitura, confirmação, recusa e detalhe do problema
- [x] Lembretes de 30 em 30 minutos e alerta aos supervisores
- [x] Exclusão definitiva de técnico e escala para vários técnicos
- [x] Painel próprio na Vercel com login, papéis e aba Usuários
- [x] Jornada CLT automática, painel de técnicos sem escala, alerta das 18h, colunas ajustáveis
- [x] Escala cancelada libera o horário
- [x] Item 2 do backlog: URA de voz pela Twilio, testada em produção (1 aprova, 2 nega)
- [x] Aba Roadmap: backlog, entregas e dívidas técnicas dentro do painel, com Kanban
- [x] Item 5 do backlog: habilidades, requisitos por tipo de atividade e gestão de documentos (NRs, CNH, ASO)
- [x] Item 3 do backlog (parcial): painel de acompanhamento por local
- [ ] Desligar o painel Retool e remover as funções da bancada de teste
- [ ] Backlog de 60 dias (ver [docs/backlog.md](docs/backlog.md))
