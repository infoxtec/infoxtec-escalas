# Sprint 04–17 de novembro — virada da produção para o Cloudflare e MFA de administrador

**Meta:** a produção do painel roda no Cloudflare, publicada só pelo workflow Aplicar com a aprovação do responsável, e o
administrador entra com MFA obrigatório. **Reunião de 03/11** com CTO, PO, `seguranca` e `arquiteto-cloud` (decisão 133);
aprovada pelo responsável em 03/11. Artefato da reunião com a votação completa: https://claude.ai/artifact/2TAHjv4sVhmtaSXYdnD1ep

**Capacidade:** cerca de um pacote por dia útil (o limite é o teste do responsável). Se faltar, saem os últimos do Bloco B.

## Decisões do responsável

| Prazo | Decisão | Recomendação do time |
|---|---|---|
| 03/11 | Painel só vai ao ar com aprovação | Opção A (CTO, `seguranca`, `arquiteto-cloud`; PO depois da virada): desligar o deploy automático da Vercel já (feito em 04/11 por `git.deploymentEnabled: false` no `web/vercel.json`; a opção Ignored Build Step não existe mais no painel da Vercel) e, na virada, publicar o Worker só pelo Aplicar |
| 07/11 | Domínio próprio na virada ou depois | Na virada só se o DNS estiver no Cloudflare até 07/11; senão, obrigatório antes da 1ª venda (custo do responsável) |
| 05/11 | Revisão da decisão 128 (bloqueia B3) | Membro de mais de uma conta recupera o 2FA só por e-mail |
| 04/11 | D3, módulo contratado | Vender só o pacote completo na 1ª venda |
| 04/11 | Pendência 4, plataforma baixar exportação de cliente | Proibir |
| Antes do 1º envio | Pacote de desastre (decisão 116) | Os 4 P1 do `seguranca` primeiro |

## Kanban

### Bloco A — virada (04 a 10/11)

| Ordem | Item | Dono | Esf. | Aceite |
|---|---|---|---|---|
| A1 | #18 Origem dupla nas 6 Edge Functions e no convite | fullstack + seguranca | M | `OPTIONS` aceita a Vercel e o Worker por nome exato e nega pré-visualização; publicação pelo Aplicar verde; na produção até 07/11, junto com o Worker por nome exato nas Redirect URLs do Auth da produção (nunca curinga) e um convite saído do Worker testado |
| A2 | Produção só pelo Aplicar, com aprovação (entrada `painel`: o próprio Aplicar aprovado faz o build e o deploy do Worker `trilha` com o token do Cloudflare do ambiente `producao`; Disable builds ligado no Worker) | fullstack (merge do responsável) | M | Merge na `main` não muda a produção; só o disparo aprovado |
| A3 | Worker de produção `trilha` (https://trilha.david-cerqueira.workers.dev, banco da produção; o da homologação continua em `trilha-homologacao`) | fullstack | M | Build aponta só para o banco da produção; `_headers` com HSTS; sem pré-visualização; versão igual à da Vercel |
| A4 | Ensaio da virada e da volta, aviso aos usuários | infra-bd | P | Ensaio verde; volta para a Vercel em menos de 15 min; gestores e técnicos avisados |
| A5 | Virada antecipada para 04/11 a pedido do responsável (migration 148 da `app_url`; Site URL já no Worker), sozinha | dev-banco + responsável | P | `app_url`, Site URL e redirects na produção apontam para o Worker; convite, senha e espelho abrem lá |

Veto do CTO: nada vai junto com a virada; se o A1 não estiver validado na produção até 07/11, a data muda.

### Etapa 1 do celular (pedido do responsável, 04/11, antes do B1)

| Ordem | Item | Dono | Esf. | Aceite |
|---|---|---|---|---|
| C1 | Trilha instalável no celular (PWA) e responsivo | fullstack | M | Painel e app do ponto instaláveis pela tela de início (iPhone e Android), com ícone próprio; telas públicas sem rolagem lateral em 360 e 390 px; tabelas do gestor roláveis dentro do quadro; sem zoom do iPhone ao tocar num campo |

App nativo na loja (Capacitor, mesmo código) fica para depois, só se a venda exigir (CTO e PO decidem; Apple US$ 99/ano,
Google US$ 25). O xtool foi avaliado e descartado: só iPhone, só Swift.

### Bloco B — primeira venda (11 a 17/11)

| Ordem | Item | Dono | Esf. | Aceite |
|---|---|---|---|---|
| B1 | #23 CSP em Report-Only | fullstack | P | Nenhum aviso em login, 2FA, OCR, `/ponto`, `/v` e QR; vale de fato após 7 dias sem aviso |
| B2 | D1 MFA obrigatório para administrador | dev-banco + fullstack | M | Admin sem fator só cadastra o fator; gestor e leitura não mudam |
| B3 | #2+7 2FA entre contas | seguranca + dev-banco | M | Admin da conta A não troca o fator de membro da conta B |
| B4 | #21 Webhook 5xx em falha de infraestrutura | fullstack | P | Falha de banco devolve 5xx; reenvio não duplica a resposta |
| B5 | #3 Teto de códigos e erros por conta | dev-banco | M | 300 erros na conta A não bloqueiam o ponto da conta B |
| B6 | Furos do #15 e testes da 147 | dev-banco | P | CI recusa migration renomeada, apagada ou repetida; T86 com conta inativa e gestor; T49 à meia-noite |
| B7 | Vercel vira redirecionamento (nunca apagada), antecipado para 04/11 a pedido do responsável | fullstack | P | Com a semana estável, 301 para o Worker; QR antigo abre a verificação |
| B8 | Pedido do responsável (09/11): sábado de 4h e régua de avisos (decisão 135) | dev-banco + fullstack | M | Sábado 08:00–12:00; +1h lembrete, +2h uma ligação, +3h último e aviso ao gestor; nada depois das 18h |

### Backlog, em ordem
#12 + #13 (expurgo e guarda de 5 anos, com o jurídico; o `seguranca` reprovou cortar o 13), #19 (RLS do Storage no CI),
pacote de desastre, #17, #24, #9 (medir antes), #20 (antes de religar a URA), #11 (D3), ICP-Brasil (parecer de 07/11),
P2 da 147 (lista de ASO no download, ramos mortos de saúde). Cortes mantidos: #10 (registrado), #22, #25; #26 entra no A5.

## Avaliação da proposta do DeepSeek (`docs/sprint-02-13-nov.md`)

Dos 21 cartões: 6 já entregues, 6 aprovados nesta sprint, 7 para o backlog, 4 cortes mantidos, 1 corte reprovado (#13).
Acertos: lastro no código em cada cartão e respeito às decisões registradas. Falhas: a premissa "produção congelada até
05/11" (131 a 143 subiram em 30/10), cerca de 14 pacotes para cerca de 7 de capacidade, o CSP Report-Only como P0 (só
observa), e não viu o deploy automático da Vercel nem o token da produção inválido.

## Estado em 04/11 (daily; PRs #198 a #208)

| Item | Estado | Falta para estar pronto |
|---|---|---|
| A1 Origem dupla | Na produção (Aplicar 04/11) | Tirar a Vercel das origens das Edge Functions (ela só redireciona) |
| A2 Painel só pelo Aplicar | Na produção (#202, #203); 1ª publicação aprovada em 04/11 | — |
| A3 Worker `trilha` | Na produção (#199, #200); Disable builds ligado | — |
| A4 Ensaio | **Pulado** (risco aceito pelo responsável ao antecipar a virada) | Roteiro de volta escrito, mesmo depois |
| A5 Virada | **Na produção, pendente de teste**: antecipada de 10/11 para 04/11 (migration 148, Site URL) | Testes do responsável: link do WhatsApp e convite; aviso aos usuários |
| B7 Vercel só redireciona | **Na produção, pendente de teste** (#206–#208): `/`, `/?verificar=`, `/v?c=`, `/ponto?espelho=` conferidos por fora | QR de um espelho real escaneado |
| Painel 3.67.1 | Na produção: sem a tarja vermelha | — |
| C1 PWA e responsivo | Na produção (3.68.0, 05/11), testado pelo responsável no celular | — |
| B1 CSP em observação e B2 MFA para administrador | Na produção (painel 3.71.0, 10/11); a 149 entrou antes pela integração do Supabase (incidente de 09/11) | — |
| Pedido 09/11: sábado 4h e régua de avisos | Na produção (migration 150, painel 3.71.0, 10/11), testado pelo responsável | — |
| B3 2FA entre contas | Homologação testada pelo responsável em 12/11; produção pedida (migration 151, Edge `recuperar-duas-etapas`, painel 3.72.0) | Conferência na produção |
| B4–B6 | A fazer | — |

Nenhum item ganha `[x]` no plano até a produção ser conferida pelo responsável.

### Incidentes do dia
0. **(09/11) Reincidência:** o "Deploy to production" da integração do Supabase estava ligado de novo e aplicou a 149
   (06/11) e a 150 (09/11) na produção sem aprovação. Desligado em 09/11; trava nova no Aplicar (`aplicar_registro`).
   No mesmo dia, o deploy do painel 3.71.0 falhou no Cloudflare ("No access to the specified service").
1. **A integração GitHub do Supabase publicava na produção sem aprovação** ("Deploy to production" ligado): todo merge
   na `main` aplicava migrations e publicava as Edge Functions do `config.toml`. Achado em 04/11 pelo log do Aplicar;
   explica o congelamento furado de 30/10. **Desligado pelo responsável em 04/11.**
2. A Vercel publicava a `main` no merge (03/11). Desligado (#201).
3. Token do Supabase da produção vencido: a Edge Function falhou duas vezes (03/11).
4. Vercel pausada sem plano (04/11): QR e links do WhatsApp fora do ar por cerca de 1h30, até o B7.
5. Instruções de tela do Claude dadas de memória e erradas (Ignored Build Step, Branch control).
6. Tarja vermelha "PRODUÇÃO" publicada (ninguém olhou o build de produção); raiz da Vercel sem redirecionamento
   (achado só depois do deploy); arquivo desta sprint apagado por um comando do Claude no #206 (restaurado).
7. Retrabalho: 5 de 11 PRs foram correção do anterior; 2 revisões do `seguranca` voltaram no A2 por desenho codado antes
   de revisado; 2 execuções do roteiro da 147 perdidas por erro do script.

### Ações corretivas (daily de 04/11: Scrum Master e gestor de pedidos)
| # | Ação | Dono | Prazo |
|---|---|---|---|
| 1 | Inventário de todo caminho automático até a produção (Supabase, Vercel, Cloudflare, Aplicar, tokens) com dono, estado esperado e validade; conferido em todo PR de infraestrutura | Claude + `arquiteto-cloud` | **Feito em 04/11** (`docs/caminhos-de-producao.md`); 6 pendências do responsável |
| 2 | Checklist de virada com condição de entrada (ensaio, roteiro de volta, aviso enviado); sem ela, a virada não sai; mudança fora dela só com o risco registrado | Scrum Master | 05/11 |
| 3 | Roteiro fixo de teste pós-produção com todas as entradas de usuário (login, link do WhatsApp, convite, QR, raiz) | Claude (roteiro), responsável (testes 2 e 4) | 04/11 |
| 4 | Usuário de QA na homologação para o Claude testar telas | Responsável decide | 05/11 |
| 5 | Dono e validade dos tokens da produção (Supabase, Cloudflare) registrados, com lembrete antes de vencer | Claude registra, responsável renova | 06/11 |
| 6 | Instrução de tela só com a documentação atual consultada (link na resposta); SQL de teste roda antes na homologação; desenho revisado pelo `seguranca` antes de codar infraestrutura; build de produção conferido na tela antes de publicar | Claude | Imediato |

### Mudanças no rito
- Daily curta todo dia, com a pergunta fixa: "algo vai à produção hoje fora do plano?".
- Revisão de desenho (`seguranca`, `arquiteto-cloud`) antes do primeiro PR de infraestrutura.
- Ensaio obrigatório para qualquer virada; antecipar é decisão do responsável com o risco escrito aqui.
- No máximo uma entrega grande por vez na produção.
