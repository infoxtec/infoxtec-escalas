# Sprint 02–13 de novembro — auditoria de 01/11

**Objetivo:** fechar o que vaza entre contas e o que promete o que não cumpre, antes do primeiro cliente; e proteger o deploy de 06/11.

**Origem:** auditoria de 01/11 (26 achados de oito frentes). **Reunião de planejamento:** consultor SaaS, PO, Scrum Master e CTO — Segurança e Arquiteto de dados não responderam (pendência registrada no fim).

**Ambiente de referência:** homologação (`infoxtec-escalas-dev`). Produção congelada até 05/11.

---

## Decisões que dependem do responsável

| # | Decisão | Quem propõe |
|---|---|---|
| D1 | Ligar MFA obrigatório para admin e plataforma (decisão 67) | CTO |
| D2 | Reabrir a URA com assinatura da Twilio obrigatória (decisões 54/109) | CTO |
| D3 | Aplicar módulo contratado no banco ou vender só pacote completo | CTO + Comercial |
| D4 | Guarda de 5 anos: custo do arquivo e destino | CTO + responsável |
| D5 | Link do pacote de 7 dias: manter (decisão 129) ou reduzir para 24 h | CTO |
| D6 | Exclusão prometida (F8d): implementar ou retirar a promessa agora | PO + CTO |

---

## Kanban

### Backlog (fora desta sprint)

| # | Item | Por quê |
|---|---|---|
| 10 | Link do pacote de 7 dias | Decisão 129 confirmou 7 dias; mexer é reabrir decisão registrada (D5) |
| 13 | Guarda de 5 anos restaurável | Custo e destino são decisão do responsável (D4); 5 anos de mensais não cabem |
| 22 | IP do HMAC falsificável | Medir a borda antes; se a borda sobrescreve, é documentação |
| 25 | /ponto baixa o painel inteiro | Otimização, não bloqueio; segundo cliente |
| 26 | Plano e evidências desatualizados | Chore de documentação, entra no PR do deploy |

### A fazer — P0 até 05/11 (protege a virada de 06/11)

| # | Item | Dono | Esforço |
|---|---|---|---|
| 15 | Numeração de migration acima da 143 | arquiteto-dados | P |
| 16 | Congelamento falha fechado | scrum-master | P |
| 18 | Publicar funções e trocar `ORIGEM_PAINEL` no switch | fullstack | M |
| 23 | CSP em Report-Only no Worker | fullstack | M |
| 1 | Checklist só da plataforma | dev-banco | P |
| 4+6 | Exportação: cofre e máscara de saúde | dev-banco | M |
| 5+14 | Encerramento desligado até a F8d | PO + dev-banco | P |

### A fazer — P1 até 12/11 (a primeira assinatura)

| # | Item | Dono | Esforço |
|---|---|---|---|
| 2+7 | 2FA: recuperação entre contas e fator na sessão | seguranca + dev-banco | M |
| 3 | Teto de códigos e erros por conta | dev-banco | M |
| 8 | Papel `leitura` não vê ASO | dev-banco | P |
| 11 | Módulo contratado aplicado no banco | dev-banco | M |
| 20 | URA com assinatura obrigatória | fullstack | M |
| 21 | Webhook devolve 5xx em falha de infraestrutura | fullstack | P |
| 12 | Expurgo do texto livre (prazo por tipo) | dev-banco + juridico | M |

### Em curso

*(vazio — a sprint começa em 02/11)*

### Revisão

*(vazio)*

### Feito

*(vazio)*

---

## Defesa curta de cada item da sprint

**P0**

- **15 — Numeração acima da 143.** A 143 é `20261115120000` e hoje é 01/11: `migration new` nasce atrás e o `db push` recusa. *Cenário:* A) trava no CI que exige versão maior que a última; B) seguir com a regra em prosa e descobrir no deploy.
- **16 — Congelamento falha fechado.** `CONGELADA_ATE` malformada ou apagada desliga a trava sem erro (`aplicar.yml:91`). *Cenário:* A) regex `AAAA-MM-DD` fatal; B) manter e aceitar que um erro de digitação libera a produção.
- **18 — Funções e origem no switch.** O CI só faz `deno check` e a `ORIGEM_PAINEL` só aceita `*.vercel.app`: no dia 06/11 o OCR, o convite e o 2FA caem. *Cenário:* A) publicar as funções alteradas no mesmo workflow; B) conferência manual no runbook.
- **23 — CSP em Report-Only.** Sem CSP, um XSS leva a sessão do painel e o token do ponto. A virada é a janela. *Cenário:* A) Report-Only com `connect-src` do Supabase; B) só a CSP depois do switch.
- **1 — Checklist só da plataforma.** Qualquer admin de cliente vê cron, Vault, Evolution e volumes de todas as contas (`93:885`, `51:27`). *Cenário:* A) `fn_exigir_plataforma()`; B) dividir em checklist da conta e da operadora.
- **4+6 — Exportação com cofre e máscara.** Um admin sem `rh_folhas` leva folha assinada e texto de saúde no CSV (`143:473`, `121:816`). *Cenário:* A) matriz de acesso única para 4, 6 e 8; B) tirar essas colunas do pacote.
- **5+14 — Encerramento desligado.** O e-mail promete exclusão em 30 dias e ninguém apaga (`142:51`, `143:509`). *Cenário:* A) desligar o botão até a F8d; B) retirar a data e declarar retenção.

**P1**

- **2+7 — 2FA.** O fator é global em `auth.users` e o telefone de recuperação é por conta: admin de A derruba o 2FA de B (`140:276`, `140:194`). *Cenário:* A) dois canais para membro de mais de uma conta + fator fora da sessão da senha; B) aceite escrito.
- **3 — Tetos por conta.** 300 erros põem todos em modo restrito e o login do ponto de todos os clientes para (`129:36`). *Cenário:* A) contar por conta e avisar a conta que estourou; B) limite contratado.
- **8 — `leitura` e ASO.** O papel vê o tipo do documento, inclusive ASO, sem `ve_saude` (`120:83`). *Cenário:* A) filtrar saúde e manter NR/CNH; B) aceite formal.
- **11 — Módulo aplicado.** `conta_modulos` não é lido por nenhuma função: quem comprou escala usa o ponto (`116:66`). *Cenário:* A) aplicar nas famílias `app_*`/`ponto_*`; B) vender só pacote completo.
- **20 — URA assinada.** Token na URL é a única defesa e a assinatura é ignorada (`voz-escala:23`): confirmação forjada (`130:33`). *Cenário:* A) `TWILIO_ASSINATURA=obrigatoria` após 10 ligações válidas; B) mais 30 dias com aceite.
- **21 — Webhook 5xx.** Erro de banco vira 200 e a mensagem do técnico some (`webhook:63`). *Cenário:* A) 5xx só em infra, com idempotência já provada; B) varredura de `ERRO:%`.
- **12 — Expurgo do texto livre.** O aviso promete 5 anos e `respostas.texto_livre` nunca expira (`55:472`). *Cenário:* A) prazo por tipo com o jurídico; B) registrar base e manter.

---

## O que a reunião recomendou cortar

**10** (link de 7 dias) — decisão 129 é de 30/10 e o CTO não a reabre sem você.
**13** (guarda de 5 anos) — custo e destino são seus; 5 anos de cópias mensais não cabem no plano atual.
**22** (IP no HMAC) — medir a borda primeiro; pode ser só documentação.
**25** (/ponto com bundle inteiro) — otimização; o funcionário consegue bater ponto.
**26** (plano e evidências velhos) — chore de documentação, entra no PR do deploy.

---

## Pareceres da reunião

**Consultor SaaS.** O que trava a primeira venda é LGPD (retenção, exclusão e dado sensível) e MFA de admin, não o Cloudflare. P0 é só o que protege 06/11; P1 é a fila da assinatura. Exportação em memória, link de 7 dias, backup de 5 anos, CSP estrito e bundle do /ponto esperam o segundo cliente; o HMAC do IP sai.

**PO.** A sprint fecha o que um admin ou leitor de cliente já alcança hoje: checklist, 2FA entre contas, cofre e saúde na exportação, ASO para leitura e URA assinada. Retenção e expurgo são dívida G, não remendo de semana.

**Scrum Master.** Antes de 06/11, só o P0: 16, 15 e 18. Definição de pronto comum: branch, migration nova, versão do painel, CI verde, caso novo na regressão, revisão do segurança e do arquiteto de dados, documento no mesmo PR e homologação testada por você.

**CTO.** O 06/11 é virada de infraestrutura, não estreia do multiempresa. Encerramento não vai ao ar prometendo exclusão que não existe. MFA, URA, módulo, guarda e link de 7 dias são decisão do responsável — eu recomendo, não reabro sozinho.

---

## Pendências

- **Segurança e Arquiteto de dados não responderam** nesta rodada; os dois revisam cada PR de migration e de Edge Function antes do merge.
- **Credencial de leitura da homologação** não existe: tudo que depende de medir o banco vivo segue sem verificação.
- **P0 fecha até 05/11**; o 06/11 só sobe com o ensaio do switch verde.
