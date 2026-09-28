# Painel de temas

O que falta fazer no Trilha, por área, com **ID para escolher onde atuar**. O responsável aponta o ID
e o trabalho começa por ele.

> **Versão interativa, com a referência exata de cada tema e o controle de quem corrige (Deep ou
> Claude): [`painel-de-controle.html`](painel-de-controle.html).** Abra no navegador — as escolhas
> ficam salvas localmente e o botão *Copiar seleção* devolve a lista pronta para colar aqui.

**Severidade:** **C** = crítico (perda de dado, parada silenciosa, dado pessoal exposto ou bloqueia
venda) · **M** = médio (risco com mitigação, ou dívida que atrapalha a expansão).

**Estado:** `[ ]` aberto · `[~]` em andamento · `[x]` feito. Este documento é vivo: fecha-se um tema,
marca-se aqui.

**Os IDs são estáveis** — `SEG-01` é sempre o mesmo tema, mesmo depois de concluído.

---

## O que dá para resolver hoje

| ID | Tema | Quem | Tempo |
|---|---|---|---|
| **SEG-01** | Rotacionar `EVOLUTION_API_KEY` (a única credencial comprovadamente exposta) | responsável | 10 min |
| **INF-02** | Criar o monitor no healthchecks.io e preencher `monitor_ping_url` | responsável | 15 min |
| **INF-05** | Rodar o backup à mão e conferir se `PRODUCAO_DB_URL` está em dia | responsável | 5 min |
| **SEG-13** | Corrigir o inventário de segredos em `docs/seguranca.md` | Claude | 20 min |
| **Convergência dos ambientes** | Aplicar a **migration 49 na homologação** — a produção já está em 49 e a homologação parou em 48 | responsável | 15 min |
| **DEV-01 + DEV-02** | PR dos defeitos: enviar `tipo`/`teste` e blindar a tela contra erro de render | Claude | 1 h |

---

## Infraestrutura

| ID | Tema | Sev | O que resolve | Quem | Esforço |
|---|---|---|---|---|---|
| **INF-01** | Arquivos de documento (ASO/NR) **fora de qualquer cópia**, com 5 anos de guarda declarada | **C** | tira do papel a retenção prometida | responsável + Claude | 2 h |
| **INF-02** | Monitor externo (healthchecks.io) não criado | **C** | Supabase fora e Evolution caída deixam de ser invisíveis | responsável | 15 min |
| **INF-03** | O backup **não devolve o sistema**: sem `auth`, Vault e cron; o teste confere 7 contagens | **C** | restauração que volta a funcionar, e não só os dados | Claude + responsável | 4 h |
| **INF-04** | Restauração sem o passo de *default privileges* que a CLI exige | **C** | evita devolver `anon`/`authenticated` com privilégio | Claude + responsável | 30 min |
| **INF-05** | `PRODUCAO_DB_URL` pode estar dessincronizado — backup falhando em silêncio | M | RPO deixa de ser indefinido | responsável | 5 min |
| **INF-06** | Backup diário completo é o padrão que estoura a cota de egress | M | semanal completo + diário do núcleo | Claude | 2 h |
| **INF-07** | Nada mede Storage nem egress | M | o primeiro limite a estourar passa a avisar | Claude | 2 h |
| **INF-08** | Edge Functions publicadas à mão, sem paridade com a `main` | M | produção deixa de rodar revisão desconhecida | Claude | 3 h |
| **INF-09** | `db push` cru documentado em dois lugares, fora do script com travas | M | tira o atalho que contorna a confirmação | Claude | 20 min |
| **INF-10** | Aviso de motor parado só dentro da janela 06:00–21:00 | M | parada noturna para de ficar muda ~9 h | Claude | 1 h |
| **INF-11** | Retenção só em 4 alvos; 6 tabelas crescem para sempre | M | prazos para escalas, respostas, ocorrências e ligações | responsável + Claude | 3 h |
| **INF-12** | Vercel Hobby proíbe uso comercial | M | destrava vender sem risco de suspensão | Claude + responsável | 4 h |

## Dev

| ID | Tema | Sev | O que resolve | Quem | Esforço |
|---|---|---|---|---|---|
| **DEV-01** | Tipo de atividade e marca de teste **coletados e nunca enviados** | **C** | a exigência de habilidade volta a ser gravada | Claude | 30 min |
| **DEV-02** | Sem `ErrorBoundary` e `formatDate` sem guarda | **C** | acaba a tela branca em todas as abas | Claude | 1 h |
| **DEV-03** | Publicação em `infoxtec.com.br/trilha` não começou no código | **C** | o painel abre no endereço decidido | Claude + responsável | 3 h |
| **DEV-04** | Substituir técnico falha quando a escala já começou | **C** | o recurso passa a servir no caso urgente | responsável + Claude | 1 h |
| **DEV-05** | Contrato de acesso sem área nem escopo por equipe | **C** | é a fundação dos quatro módulos | Claude | 2–3 semanas |
| **DEV-06** | `fn_aptidao` existe e não é exigida em nenhum caminho | M | "liberação para obra" deixa de ser aviso de tela | responsável + Claude | 1 semana |
| **DEV-07** | Acessibilidade de campo: tabelas cortadas, rótulo, modal, Kanban só no mouse | M | o gestor consegue operar no celular | Claude | 1 semana |
| **DEV-08** | Nenhum teste de banco e nenhum lint | M | rede de proteção para a expansão | Claude | 1 semana |
| **DEV-09** | Duplicação estrutural: 7 versões do dispatcher, fases copiadas, `erroMsg` 31× | M | manutenção deixa de ser arqueologia | Claude | 2 semanas |
| **DEV-10** | 12 colunas mortas, enum `reagendada`, chaves de `config` sem leitor | M | o modelo para de mentir | Claude | 1 dia |
| **DEV-11** | Edge Functions sem `_shared` e sem timeout de banco | M | robustez e diagnóstico | Claude | 1 dia |
| **DEV-12** | Sem modelo de projeto/atividade | M | desbloqueia Kanban → Gantt → Curva S | Claude | G |
| **DEV-13** | Ponto: sem registro real de jornada e sem decisão regulatória | M | desbloqueia o módulo de ponto | responsável + Claude | G |

## Segurança

| ID | Tema | Sev | O que resolve | Quem | Esforço |
|---|---|---|---|---|---|
| **SEG-01** | `EVOLUTION_API_KEY` exposta por 3 h 14 na janela da migration 12 | **C** | torna inútil a leitura da chave | responsável | 10 min |
| **SEG-02** | `WEBHOOK_TOKEN` criado 5,8 s depois do carimbo da correção | **C** | fecha a incerteza da margem | responsável | 15 min |
| **SEG-03** | ~~Papel `leitura` recebe motivo de saúde cru~~ — **fechado e em produção em 28/09** (decisão 40, migration 49): o motivo de saúde saiu do sistema | — | — | — | — |
| **SEG-14** | Papel `leitura` enxerga `caminho`/`url` dos documentos (NR, CNH e **ASO**). A decisão 41 tirou o caminho do link direto do Drive (**parte 1 em produção em 28/09**); resta o nome e a existência dos arquivos, e a limpeza dos vínculos antigos | **C** | o documento pessoal deixa de aparecer para quem só lê | responsável + Claude | 2 h |
| **SEG-04** | Sem MFA nas contas administrativas | **C** | é a primeira pergunta de qualquer cliente | responsável | 15 min |
| **SEG-05** | Tokens do webhook e da URA na query string; assinatura da Twilio em observação | **C** | tira o segredo do log de terceiros | Claude | 1 dia |
| **SEG-06** | Hardening incompleto: *sequences* e *default privileges* fora do `revoke` | M | fecha a migration 39 | Claude | 1 h |
| **SEG-07** | Sem CSP no painel | M | reduz o alcance de um XSS | Claude | 1 h |
| **SEG-08** | Nenhuma Edge Function limita taxa; `app_ligar_escala` sem limite de frequência | M | abuso de custo por ligação | Claude | 3 h |
| **SEG-09** | LGPD: sem inventário formal, aviso ao titular e canal de direitos | M | pré-requisito das etapas 20 e 21 | responsável + Claude | 1 semana |
| **SEG-10** | Expurgo de documentos sem executor e arquivo órfão ao excluir técnico | M | direito de eliminação deixa de ser declaração | Claude | 3 dias |
| **SEG-11** | Sem trilha de acesso a documento (item 015 do backlog) | M | responde "quem abriu o ASO" | Claude | 3 dias |
| **SEG-12** | Transferências a terceiros sem registro de base legal | M | fecha a parte de LGPD do contrato | responsável | 1 h |
| **SEG-13** | ~~`docs/seguranca.md` com inventário de segredos errado~~ — **corrigido em 28/09**: cinco segredos reais, rotação pendente marcada e Retool/xlsx como resolvidos | — | — | — | — |

## Comercial

| ID | Tema | Sev | O que resolve | Quem | Esforço |
|---|---|---|---|---|---|
| **COM-01** | Decidir o canal oficial do WhatsApp (item **023** do quadro) | **C** | destrava vender a terceiros | responsável | decisão |
| **COM-02** | Preço, mínimo mensal e política de desconto (item **030**) | **C** | proposta deixa de ser caso a caso | responsável | decisão |
| **COM-03** | Contrato e anexo de tratamento de dados (portão G3) | **C** | é o que permite assinar | responsável + jurídico | 1 semana |
| **COM-04** | Publicar em `infoxtec.com.br/trilha` e produzir o material de venda | **C** | o produto passa a ter endereço e proposta | Claude + responsável | 3 dias |
| **COM-05** | Os 3 RH são usuário final ou canal/revenda? | **C** | define marca, preço e esforço | responsável | decisão |
| **COM-06** | INPI e endereço da marca Trilha | M | protege o nome antes de aparecer | responsável | 2 h + prazo |
| **COM-07** | Confirmar o Plano Diretor Comercial no quadro e liberar os filhos | M | fecha a análise do backlog | responsável | 5 min |
| **COM-08** | Migrar o painel para o Cloudflare Pages | M | permite uso comercial (liga com INF-12) | Claude | 4 h |
| **COM-09** | Dossiê de conformidade exportável | M | é o que mais vende sozinho | Claude | 2 semanas |
| **COM-10** | Validar preço e modelo com 3 clientes piloto (item **030**) | M | preço deixa de ser hipótese | responsável | 3 conversas |

---

## Como escolher

- **Para destravar venda:** `COM-01`, `COM-02`, `COM-03`, `SEG-04`.
- **Para parar de perder dado:** `INF-01`, `INF-02`, `INF-03`.
- **Para consertar o que o cliente vê:** `DEV-01`, `DEV-02`, `DEV-03`, `DEV-04`.
- **Para a plataforma de quatro módulos:** `DEV-05` primeiro; depois `DEV-06`, `DEV-07`, `DEV-12`.
- **Mais barato por risco removido:** `SEG-01`, `SEG-02`, `INF-02`, `INF-05`, `DEV-01`, `DEV-02`.

Os cinco primeiros foram escolhidos por esse último critério — é a fila do "hoje".
