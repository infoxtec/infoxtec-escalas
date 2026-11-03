# Sprint 04–17 de novembro — virada da produção para o Cloudflare e MFA de administrador

**Meta:** a produção do painel roda no Cloudflare, publicada só pelo workflow Aplicar com a aprovação do responsável, e o
administrador entra com MFA obrigatório. **Reunião de 03/11** com CTO, PO, `seguranca` e `arquiteto-cloud` (decisão 133);
aprovada pelo responsável em 03/11. Artefato da reunião com a votação completa: https://claude.ai/artifact/2TAHjv4sVhmtaSXYdnD1ep

**Capacidade:** cerca de um pacote por dia útil (o limite é o teste do responsável). Se faltar, saem os últimos do Bloco B.

## Decisões do responsável

| Prazo | Decisão | Recomendação do time |
|---|---|---|
| 03/11 | Painel só vai ao ar com aprovação | Opção A (CTO, `seguranca`, `arquiteto-cloud`; PO depois da virada): desligar o deploy automático da Vercel já (Ignored Build Step `exit 0`) e, na virada, publicar o Worker só pelo Aplicar |
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
| A2 | Produção só pelo Aplicar, com aprovação | fullstack (merge do responsável) | M | Merge na `main` não muda a produção; só o disparo aprovado |
| A3 | Worker de produção `trilha` | fullstack | M | Build aponta só para o banco da produção; `_headers` com HSTS; sem pré-visualização; versão igual à da Vercel |
| A4 | Ensaio da virada e da volta, aviso aos usuários | infra-bd | P | Ensaio verde; volta para a Vercel em menos de 15 min; gestores e técnicos avisados |
| A5 | Virada em 10/11, sozinha | dev-banco + responsável | P | `app_url`, Site URL e redirects na produção apontam para o Worker; convite, senha e espelho abrem lá |

Veto do CTO: nada vai junto com a virada; se o A1 não estiver validado na produção até 07/11, a data muda.

### Bloco B — primeira venda (11 a 17/11)

| Ordem | Item | Dono | Esf. | Aceite |
|---|---|---|---|---|
| B1 | #23 CSP em Report-Only | fullstack | P | Nenhum aviso em login, 2FA, OCR, `/ponto`, `/v` e QR; vale de fato após 7 dias sem aviso |
| B2 | D1 MFA obrigatório para administrador | dev-banco + fullstack | M | Admin sem fator só cadastra o fator; gestor e leitura não mudam |
| B3 | #2+7 2FA entre contas | seguranca + dev-banco | M | Admin da conta A não troca o fator de membro da conta B |
| B4 | #21 Webhook 5xx em falha de infraestrutura | fullstack | P | Falha de banco devolve 5xx; reenvio não duplica a resposta |
| B5 | #3 Teto de códigos e erros por conta | dev-banco | M | 300 erros na conta A não bloqueiam o ponto da conta B |
| B6 | Furos do #15 e testes da 147 | dev-banco | P | CI recusa migration renomeada, apagada ou repetida; T86 com conta inativa e gestor; T49 à meia-noite |
| B7 | Vercel vira redirecionamento (nunca apagada) | fullstack | P | Com a semana estável, 301 para o Worker; QR antigo abre a verificação |

### Backlog, em ordem
#12 + #13 (expurgo e guarda de 5 anos, com o jurídico; o `seguranca` reprovou cortar o 13), #19 (RLS do Storage no CI),
pacote de desastre, #17, #24, #9 (medir antes), #20 (antes de religar a URA), #11 (D3), ICP-Brasil (parecer de 07/11),
P2 da 147 (lista de ASO no download, ramos mortos de saúde). Cortes mantidos: #10 (registrado), #22, #25; #26 entra no A5.

## Avaliação da proposta do DeepSeek (`docs/sprint-02-13-nov.md`)

Dos 21 cartões: 6 já entregues, 6 aprovados nesta sprint, 7 para o backlog, 4 cortes mantidos, 1 corte reprovado (#13).
Acertos: lastro no código em cada cartão e respeito às decisões registradas. Falhas: a premissa "produção congelada até
05/11" (131 a 143 subiram em 30/10), cerca de 14 pacotes para cerca de 7 de capacidade, o CSP Report-Only como P0 (só
observa), e não viu o deploy automático da Vercel nem o token da produção inválido.
