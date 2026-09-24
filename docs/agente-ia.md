# Agente de IA para escalas e operação

Roteiro para chegar a um agente que apoie decisões e faça predições. Escrito em 23/09/2026,
com o sistema em produção há 3 dias.

## O ponto de partida honesto

| O que o sistema tem hoje | Volume |
|---|---|
| Escalas | 38 |
| Escalas com resposta do técnico | 28 |
| Mensagens enviadas | 68 |
| Técnicos ativos | 13 |
| Locais | 7 |
| Habilidades atribuídas | 3 |

**Isso não é suficiente para prever nada.** Qualquer modelo treinado com 28 desfechos vai decorar
o passado, não aprender o padrão. Uma regra prática razoável: **30 a 50 eventos por variável que
se quer usar**. Para prever recusa a partir de técnico, dia da semana, horário, local e tipo de
atividade, o piso fica em torno de **400 a 600 escalas respondidas** — com o volume atual, entre
**3 e 6 meses** de operação.

Isso não é motivo para esperar de braços cruzados. É motivo para **instrumentar agora** e
construir em cima do que já dá resposta útil hoje.

## As três camadas, na ordem certa

```
Camada 1 — REGRAS          hoje          "quem está apto e livre na terça de manhã?"
Camada 2 — ESTATÍSTICA     ~60 dias      "este técnico costuma demorar a responder"
Camada 3 — PREDIÇÃO        ~4-6 meses    "60% de chance de recusa nesta escala"
```

Pular para a camada 3 é o erro clássico: o agente erra nas primeiras semanas, o supervisor perde a
confiança, e a ferramenta morre antes de ter dados para acertar.

---

## Fase 0 — Instrumentar (esta semana, 1 dia de trabalho)

Sem isso, os meses de dados que vierem não servem para treinar.

**Registrar o que hoje se perde:**

| Dado | Por que importa | Onde |
|---|---|---|
| Tempo até responder | É o melhor sinal de engajamento | calcular de `notificacoes.enviada_em` até `respostas.recebida_em` |
| Motivo da recusa categorizado | Hoje é texto livre em `ocorrencias.detalhe` | acrescentar o motivo estruturado ao fluxo do WhatsApp |
| Se a escala foi cumprida | Diferente de "confirmada" | vem do checklist (item 1 do backlog) |
| Quem montou a escala e quando | Antecedência muda a taxa de aceite | já existe em `escala_eventos` |
| Clima e trânsito no dia | Explica atraso e recusa | API externa gratuita, gravar no dia |

**Criar a tabela de fatos.** Uma linha por escala com tudo achatado — técnico, dia da semana,
horário, turno, local, distância, tipo de atividade, antecedência, tentativas, tempo de resposta,
desfecho. É dela que qualquer modelo vai ler, e ela também acelera relatórios.

**Congelar o histórico.** Uma tarefa diária que grava o estado do dia anterior, para que edição
retroativa não reescreva o passado usado no treino.

---

## Fase 1 — Assistente que consulta (2 a 3 semanas, funciona com os dados de hoje)

Um campo de pergunta no painel: *"quem está sem escala quinta?"*, *"quantas recusas o Diego teve
este mês?"*, *"quais locais tiveram mais problema?"*.

**Como funciona:** a pergunta vai para um modelo de linguagem junto com o dicionário das tabelas;
ele devolve **SQL somente leitura**; o sistema executa com um papel restrito e mostra a resposta
em tabela ou gráfico, **junto com o SQL usado**.

**Travas obrigatórias:** papel de banco só com `select` nas views; tempo máximo de execução;
nenhuma função `app_*` exposta ao modelo; toda pergunta e SQL gerado registrados em log.

**Por que começar aqui:** entrega valor imediato, ensina a equipe a confiar (ou desconfiar) do
agente com risco baixo, e o log de perguntas revela **o que o gestor realmente quer saber** — que
é a melhor fonte de requisitos para as fases seguintes.

**Custo:** centavos por pergunta em qualquer API de LLM. Com uso moderado, menos de R$ 30/mês.

---

## Fase 2 — Estatística descritiva (após ~60 dias de operação)

Ainda sem modelo treinado: são médias e contagens que já respondem muito.

- Taxa de aceite por técnico, por dia da semana e por faixa de horário
- Tempo mediano de resposta por técnico — identifica quem sempre precisa de lembrete
- Locais com mais recusa
- Efeito da antecedência: escala enviada com 2 dias aceita mais que a enviada na véspera?

Isso vira um **painel de indicadores** e alimenta a primeira forma de "predição" honesta:
*"o Fulano responde em média 4 horas depois; a escala de amanhã dele saiu há 6 horas"*.

---

## Fase 3 — Predição de verdade (a partir de ~400 escalas respondidas)

Três modelos, em ordem de valor:

**1. Probabilidade de recusa.** Entrada: técnico, dia, horário, turno, local, tipo, antecedência,
histórico recente. Saída: risco de 0 a 100%. Uso: ao montar a escala, o painel avisa "risco alto
de recusa" e sugere alternativa. Técnica: **regressão logística** — simples, roda no próprio
Postgres, e tem a vantagem decisiva de ser **explicável**: dá para mostrar o que pesou.

**2. Tempo até responder.** Saída: horas previstas. Uso: disparar a ligação antes, para quem
historicamente demora, em vez de esperar os 30 minutos fixos.

**3. Previsão de demanda.** Quantas escalas por tipo e região nas próximas semanas, a partir de
sazonalidade e do sistema de chamados (item 8 do backlog). É o que alimenta o item 7.

**Como treinar sem virar projeto de laboratório:** exportar a tabela de fatos, treinar fora do
sistema, e trazer de volta **só os coeficientes**, gravados numa tabela. A pontuação roda em SQL,
sem serviço de IA no caminho crítico, sem custo por escala e sem latência. Retreinar uma vez por
mês.

**Medir antes de confiar:** rodar o modelo em paralelo por 30 dias, comparando a predição com o
que aconteceu, sem mostrar nada ao supervisor. Só entra na tela se acertar mais que o palpite
óbvio ("todo mundo aceita").

---

## Fase 4 — Agente que sugere (depois da fase 3)

Aí sim o item 6 do backlog completo: o agente monta a escala da semana e **explica cada escolha** —
"João, porque tem NR-35 válida, está livre e não foi escalado nos últimos 3 dias; risco de recusa
12%". O supervisor aprova, ajusta ou recusa, e **cada correção vira dado de treino**.

Regra que não muda: **o agente propõe, o humano decide.** Escala enviada sozinha para a equipe,
sem aprovação, é o caminho mais curto para perder a confiança de todos.

---

## Governança — três limites

**Predição sobre pessoas exige cuidado.** Um modelo que diz "este técnico provavelmente vai
recusar" pode virar, sem ninguém perceber, um critério de punição. A regra: usar para **apoiar a
operação** (ligar antes, ter plano B), nunca para avaliar desempenho individual. Vale escrever
isso e comunicar à equipe — inclusive pela LGPD, que exige transparência no tratamento
automatizado de dados de trabalhadores.

**O modelo aprende o passado, inclusive o que estava errado.** Se um técnico foi pouco escalado
por preferência pessoal de um supervisor, o modelo vai aprender que ele "não costuma ser escalado"
e reforçar isso. Revisar a distribuição periodicamente.

**Nada de decisão silenciosa.** Toda sugestão do agente precisa mostrar em que se baseou, e toda
ação dele fica em `escala_eventos`, como já acontece com o dispatcher.

---

## Resumo do caminho

| Fase | Quando | Entrega | Esforço |
|---|---|---|---|
| 0 — Instrumentar | Agora | Tabela de fatos, tempo de resposta, motivo estruturado | 1 dia |
| 1 — Assistente de consulta | 2 a 3 semanas | Perguntas em português sobre os dados | M |
| 2 — Estatística | ~60 dias | Painel de indicadores e padrões por técnico | P |
| 3 — Predição | ~4 a 6 meses | Risco de recusa, tempo de resposta, demanda | G |
| 4 — Agente que sugere | Depois da 3 | Escala proposta com justificativa | G |

**O que fazer hoje:** a fase 0. Ela custa um dia, não depende de nada externo, e é o que determina
se daqui a seis meses haverá dados para treinar — ou seis meses de registros incompletos.
