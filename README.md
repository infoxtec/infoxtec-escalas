# Infoxtec Escalas

Gestão de escalas da equipe técnica de campo, com envio e confirmação pelo WhatsApp.

O produto se chama **Trilha** — *toda jornada deixa uma trilha*. Este repositório é o módulo de
escalas e documentos, que é a base dele; a visão comercial (módulos, pacotes e preço) está no
[Plano comercial](docs/plano-comercial.md) e a marca na [Marca](docs/marca.md).

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
| [Plano comercial](docs/plano-comercial.md) | O que é vendido, para quem, a que preço, o que ainda não existe e o que bloqueia a venda |
| [Marca](docs/marca.md) | Trilha: nome, narrativa, posicionamento, identidade e o que a marca não promete |
| [Arquitetura](docs/arquitetura.md) | Como as peças se encaixam e por que o banco é o centro |
| [Banco de dados](docs/banco-de-dados.md) | Tabelas, views, funções, gatilhos e parâmetros |
| [Operação](docs/operacao.md) | Diagnóstico do dia a dia: o que consultar quando algo falha |
| [Segurança](docs/seguranca.md) | Login, papéis, segredos, LGPD e riscos conhecidos |
| [Análise de segurança e LGPD](docs/analise-seguranca.md) | Os riscos abertos, o inventário de dados pessoais, os prazos e o que se pode afirmar |
| [Análise de infraestrutura](docs/analise-infraestrutura.md) | Componentes, pontos únicos de falha, capacidade, backup e observabilidade |
| [Análise do código](docs/analise-codigo.md) | Banco, painel e Edge Functions: estrutura, duplicação, defeitos e o que fazer primeiro |
| [Decisões](docs/decisoes.md) | O que foi decidido, o que foi descartado e por quê |
| [Backlog](docs/backlog.md) | Análise de viabilidade dos 16 itens planejados (o quadro vive na aba Roadmap) |
| [Análise do backlog](docs/analise-backlog.md) | Revisão consolidada: o que está pronto sem estar marcado, duplicidades, bloqueios por decisão e a fila recomendada |
| [Agente de IA](docs/agente-ia.md) | Roteiro para predições: instrumentar, consultar, prever, sugerir |
| [Segurança e homologação](docs/seguranca-homologacao.md) | Caminho para uso comercial: ordem das tarefas, LGPD e o que afirmar sobre certificação |
| [Telefonia (item 2)](docs/telefonia.md) | URA de voz: fornecedor, custos, script e resultado do piloto |
| [**Plano de trabalho**](docs/plano-de-trabalho.md) | **O que falta fazer, na ordem, e o ciclo homologação → produção de cada mudança** |
| [**Análise da topologia**](docs/analise-topologia.md) | **Desempenho medido, estrutura do banco, microserviços e achados por prioridade** |
| [**Fluxo de desenvolvimento**](docs/fluxo-de-desenvolvimento.md) | **Ambientes, caminho de uma mudança até a produção e roteiro de adoção** |
| [Ambiente de desenvolvimento no Mac](docs/ambiente-dev-mac.md) | Máquina Linux e banco de homologação para rodar o painel localmente |
| [Publicar no Vercel](docs/deploy-vercel.md) | Passo a passo do deploy e da liberação de usuários |
| [Retool (legado)](docs/retool.md) | Painel antigo, a ser desligado |

## Materiais por área

**O que falta fazer, com ID para escolher onde atuar:** [Painel de temas](docs/painel-de-temas.md)
(o texto) e **[Painel de controle](docs/painel-de-controle.html)** (a versão interativa, com a
referência exata de cada tema no banco, no painel ou no script e o controle de quem corrige).

Três áreas concentram as análises e as decisões. Cada documento responde a uma pergunta diferente.

### Segurança e LGPD

| Documento | Pergunta que responde |
|---|---|
| [Segurança](docs/seguranca.md) | Como o acesso é controlado hoje e quais riscos já são conhecidos |
| [Análise de segurança e LGPD](docs/analise-seguranca.md) | O que ainda não está protegido, quais dados pessoais existem, por quanto tempo ficam, e o que a Segurança veta |
| [Evidências de segurança](docs/evidencias-seguranca.md) | O que responder ao questionário de segurança de um cliente, com a consulta que comprova cada afirmação |
| [Rotação de segredos](docs/rotacao-de-segredos.md) | O passo a passo para trocar cada credencial, o que pode quebrar e o inventário que precisa ser mantido |
| [Segurança e homologação](docs/seguranca-homologacao.md) | O que falta para vender com segurança e o que é honesto afirmar sobre certificação |

### Código e infraestrutura

| Documento | Pergunta que responde |
|---|---|
| [Análise de infraestrutura](docs/analise-infraestrutura.md) | Onde cada coisa roda, quanto custa, o que quebra primeiro, como se recupera e o que fica invisível |
| [Análise do código](docs/analise-codigo.md) | Como o banco, o painel e as Edge Functions estão escritos: o que está morto, o que duplica e o que consertar primeiro |
| [Análise da topologia](docs/analise-topologia.md) | Desempenho medido e estrutura do banco |
| [Banco de dados](docs/banco-de-dados.md) · [Operação](docs/operacao.md) | Referência do modelo e diagnóstico do dia a dia |

### Comercial

| Documento | Pergunta que responde |
|---|---|
| [Plano comercial](docs/plano-comercial.md) | O que se vende, para quem, a que preço, o que ainda não existe e o que bloqueia a venda |
| [Marca](docs/marca.md) | Trilha: nome, narrativa, posicionamento e o que a marca não promete |
| [Análise do backlog](docs/analise-backlog.md) | O que existe, o que duplica, o que está bloqueado por decisão e a fila recomendada |
| [Backlog](docs/backlog.md) | Análise de viabilidade item a item |

**Ordem de leitura para quem chega agora:** plano comercial (o que se pretende) → análises de
infraestrutura e de código (o que existe de fato) → análise de segurança (o que falta proteger) →
[plano de trabalho](docs/plano-de-trabalho.md) (a ordem de execução).

## Stack

| Camada | Tecnologia | Custo |
|---|---|---|
| Painel | React 18 + TypeScript + Vite + Tailwind, na Vercel | R$ 0 |
| Login | Supabase Auth (e-mail e senha) | R$ 0 |
| Banco, regras, agendamento, segredos | Supabase: PostgreSQL, pg_cron, pg_net, Vault | R$ 0 |
| Edge Functions | Supabase (Deno): `webhook-evolution`, `voz-escala` e `documento-ocr` | R$ 0 |
| Ligação de voz | Twilio (URA) | ~R$ 0,24 por ligação |
| WhatsApp | Evolution API 2.4 em VPS própria | custo da VPS |

Painel em produção: **https://infoxtec-escalas.vercel.app**
Projeto Supabase: `infoxtec-escalas` (ref `zpckrxydqqmmcrphrkxz`, região sa-east-1).
Homologação: projeto Supabase `infoxtec-escalas-dev`, sem WhatsApp nem ligações reais.

## Estrutura

```
web/                          painel React (o que vai para a Vercel, Root Directory = web)
supabase/
  migrations/                 01 a 43 — espelho do banco (conferido contra a produção em 26/09)
  functions/                  Edge Functions: webhook-evolution, voz-escala, documento-ocr
  setup/                      config por ambiente, cron e segredos (rodar uma vez)
  seed.sql                    dados fictícios para desenvolvimento
scripts/                      aplicar-homologacao.sh e aplicar-producao.sh (migrations com travas)
docs/                         a documentação da tabela acima
```

## Integração do Supabase com o GitHub

O nome do arquivo de migration **precisa ser idêntico à versão gravada no banco** — é assim que a
verificação do Supabase confere o repositório. Para listar as versões reais:

```sql
select version || '_' || name || '.sql' from supabase_migrations.schema_migrations order by version;
```

Se a verificação acusar *"Remote migration versions not found in local migrations directory"*, é
porque algum arquivo está com nome diferente da versão aplicada. Renomear resolve; não é erro de
permissão.

A verificação **reexecuta todo o histórico num banco vazio**, então uma migration antiga não pode
depender do estado atual. Em especial: nenhum `grant` deve citar assinatura de função — use o laço
sobre o prefixo `app_`, como fazem todas as migrations deste repositório.

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
- [x] Itens 11, 12 e 13: perfil de teste, indicadores clicáveis e submenu da Agenda
- [x] Item 10: documentos em armazenamento privado ou vinculados ao Drive, com leitura de PDF e imagem no navegador
- [x] Sessão expira em 30 min de inatividade e cada publicação recarrega o painel aberto
- [x] Habilidades e documentos separados, envio em lote com classificação automática, atribuição no cadastro do técnico
- [x] Escala sempre no futuro (mínimo 5 minutos) e escala de teste fora das estatísticas
- [x] Item 5 do backlog: habilidades, requisitos por tipo de atividade e gestão de documentos (NRs, CNH, ASO)
- [x] Item 3 do backlog (parcial): painel de acompanhamento por local
- [x] Ambiente de homologação: projeto Supabase dev com as migrations e dados fictícios
- [x] Migration 39: fuso do motor, acesso aos documentos, permissões e limpeza de logs (homologação)
- [x] Produção comparada com o repositório; migration 40 sincroniza a fase 6 do motor
- [x] Migration 41: habilidades voltam a salvar, motor isola falha por escala, fuso no webhook (homologação)
- [x] Backlog numerado em sequência (001) e painel local nos dois ambientes (painel 3.2)
- [x] Painel 3.3: alerta de motor parado (migration 44), logomarca Infoxtec, painel local em segundo plano (`scripts/painel.sh`) e subagentes especialistas em `.claude/agents/` (homologação)
- [x] Migrations 45 e 46, Edge Functions corrigidas, CI, backup diário e painel 3.4 com senha forte (homologação, 27/09)
- [x] Painel 3.4.1: aba esquecida em segundo plano não encerra mais a sessão da aba em uso (27/09)
- [x] Painel 3.4.2: senha de 8 com letras e números e biblioteca de planilhas sem vulnerabilidade (27/09)
- [x] Painel 3.5: motivo de recusa por número, editar escala e substituir técnico (homologação, 27/09)
- [x] Migrations 47 a 49 na produção: motivo de recusa, editar e substituir escala (28/09)
- [x] Sem motivo de saúde na recusa e sem vínculo por Google Drive: decisões 40 e 41, migration 49 e painel 3.5.1 (28/09)
- [x] Painel de controle interno: 47 temas pendentes com referência exata e as avaliações de segurança, infraestrutura e código atualizadas (28/09)
- [ ] Próximas etapas: ver [docs/plano-de-trabalho.md](docs/plano-de-trabalho.md)
- [ ] Fluxo por pull request com CI (ver [docs/fluxo-de-desenvolvimento.md](docs/fluxo-de-desenvolvimento.md))
- [ ] Desligar o painel Retool e remover as funções da bancada de teste
- [ ] Backlog de 60 dias (ver [docs/backlog.md](docs/backlog.md))
