# Análise global do produto (27/09)

Análise feita pelos subagentes do projeto: PO (produto), Scrum Master (processo), Fullstack
(painel e Edge Functions) e Infra/BD (banco e infraestrutura). As medições de banco são da
homologação, com volume de um ano simulado (200 técnicos, 52 mil escalas, 156 mil notificações)
e desfeito ao final. A produção não foi consultada.

## Resumo

O produto resolve bem a dor principal: saber na véspera que todos os técnicos sabem onde vão estar,
sem ligar para ninguém. O núcleo (criar escala, enviar, cobrar, avisar o supervisor, URA) é sólido.
Os riscos estão em volta do núcleo:

| Área | Situação | Maior risco |
|---|---|---|
| Produto | Núcleo sólido; faltam editar escala, fechar escalas passadas e indicadores | Canal WhatsApp não oficial (Evolution) |
| Processo | Ciclo homologação → produção funcionando desde 26/09 | Responsável é o único que aplica, testa e decide |
| Painel e Edge Functions | Código organizado, build ok | OCR na nuvem não funciona no navegador; chave do Google pode vazar |
| Banco e infra | Rápido no volume atual (motor em 9 a 53 ms) | Sem backup; `notificacoes` sem retenção; excluir técnico antigo estoura o tempo |

## 1. Produto (PO)

**Personas:** gestor e supervisor (montam e acompanham), técnico (recebe e responde pelo WhatsApp
com 1 ou 2), supervisor em campo (recebe alertas), leitura e RH (conformidade de ASO e NR).

**Maturidade:**

| Funcionalidade | Maturidade |
|---|---|
| Criar escala com jornada CLT, conflito e aptidão | Sólido (regra CLT aguarda o RH, decisão 7) |
| Envio, lembretes, alerta ao supervisor, prazo 16h/18h | Sólido na regra, frágil no canal (Evolution) |
| Leitura da resposta | Parcial: texto solto vai para a escala pendente mais recente |
| URA (Twilio) | Sólido no fluxo; falta conferir a assinatura (etapa 12) |
| Importar planilha | Parcial: `xlsx` vulnerável (etapa 13) |
| Operação por local | Parcial: "% concluído" depende de clicar em Concluir |
| Habilidades e aptidão | Sólido |
| Documentos com OCR | Parcial |
| Usuários e papéis | Parcial: sem MFA, senha forte pendente (etapa 6) |

**Lacunas:**
1. Escala confirmada nunca é fechada (etapa 10) e a recusada continua bloqueando o horário (decisão 9).
2. Não existe editar ou reagendar escala, nem "substituir técnico" depois de uma recusa. O status
   `reagendada` existe, mas nenhuma ação leva a ele.
3. Nada registra chegada e término do técnico.
4. Sem indicadores históricos (aceite por técnico, tempo de resposta, recusas por local). O motivo da
   recusa é texto livre.
5. O técnico não consulta "minhas escalas" e não recebe aviso de privacidade.

**Backlog:** `docs/backlog.md` está desatualizado (fala em 9 itens, resumo para no 13); os itens 6 a 9
e 14 a 16 não têm critério de aceite; 14 e 15 se sobrepõem a funções que já existem (decisão 23 e
item 10). A fase 0 de `docs/agente-ia.md` (motivo de recusa estruturado e tempo de resposta, cerca de
1 dia) não está em lugar nenhum e cada semana sem ela é dado perdido.

## 2. Processo (Scrum Master)

- O ciclo está sendo cumprido: tudo por branch e PR, scripts com travas, registro no plano.
- Gargalo: o responsável faz homologação, teste, merge, produção e configuração. As etapas 5, 6 e 7
  param juntas quando ele não está.
- Branch única para vários PRs junta entregas: o PR #2 tem migration, logomarca, scripts e subagentes.
- Passos manuais ficavam fora do plano (o agendamento `vigia-motor` da etapa 7). **Corrigido.**
- Backlog (`docs/backlog.md`) e plano (23 etapas) são duas listas que não conversam.

**Cadência proposta:** um PR por etapa, uma branch por PR; segunda o responsável decide, terça a
quinta o Claude entrega na homologação, sexta 30 a 45 minutos de teste conjunto e produção; no
máximo 2 PRs esperando o responsável.

**Definição de Pronto:**
1. `npm run build` passa; versão atualizada quando muda tela.
2. Migration nova, aplicada em banco vazio sem erro; `plpgsql_check` com zero erros.
3. Revisão do `seguranca` no PR quando há banco ou Edge Function.
4. Documentação atualizada (`banco-de-dados.md`, `decisoes.md`, `README.md`).
5. Passos manuais pós-deploy listados no PR e na etapa.
6. Teste conjunto na homologação aprovado.
7. Merge, `aplicar-producao.sh` e o mesmo teste na produção.
8. `[x]` no plano e linha no registro.

**Roteiro padrão de teste conjunto:** `git pull` da branch → `aplicar-homologacao.sh` → `painel.sh
iniciar` → caminho feliz → caminho de erro → entrar como `leitura` e confirmar que não altera nada →
abrir Agenda, Operação e Roadmap para ver que nada fora da etapa quebrou → merge → `aplicar-producao.sh`
→ passos manuais → repetir no painel de produção sem criar dado fictício → registrar.

## 3. Painel e Edge Functions (Fullstack)

**Medido:** 4.338 linhas; chunk principal 532 kB (145 kB gzip), dos quais react + supabase-js são
369 kB. tesseract, pdfjs e xlsx **já** carregam sob demanda. `npm audit --omit=dev`: 1 alta (`xlsx`).
As 42 funções `app_*` chamadas pelo painel existem nas migrations.

**Achados, por gravidade:**

| Nível | Achado | Onde |
|---|---|---|
| Alto | `documento-ocr` não responde ao OPTIONS nem manda CORS: o botão "Tentar leitura na nuvem" falha sempre no navegador, sem mensagem | `supabase/functions/documento-ocr/index.ts:43`, `web/src/components/DocumentosArquivos.tsx:261` |
| Alto | Chave do Google na URL e `err.message` devolvido ao cliente: a chave pode vazar | `documento-ocr/index.ts:70,96` |
| Alto | `voz-escala` não confere `X-Twilio-Signature`; token na query fica nos logs | `voz-escala/index.ts:146` (etapa 12) |
| Alto | `xlsx` 0.18.5 vulnerável | `web/package.json` (etapa 13) |
| Médio | `documento-ocr` lê o JWT sem conferir a assinatura | `documento-ocr/index.ts:15` (etapa 11) |
| Médio | `fetch` sem timeout e corpo sem limite nas três funções | `supabase/functions/*` |
| Médio | Sem ErrorBoundary: erro de render deixa a tela em branco | `web/src/main.tsx:9` |
| Médio | Tabelas cortadas no celular (falta `overflow-x-auto`) | `UsuariosPage.tsx:67`, `HabilidadesPage.tsx:132,320`, `DocumentosArquivos.tsx:136` |
| Médio | `datasEncontradas` duplicada e divergente (a da função usa UTC) | `web/src/lib/ocr.ts:26`, `documento-ocr/index.ts:29` |
| Baixo | Acessibilidade: rótulo não ligado ao campo, modal sem foco preso, toast sem `aria-live`, abas sem nome no celular | `web/src/components/ui.tsx`, `web/src/App.tsx:133` |
| Baixo | Tipo `Documento.ocr_em` não vem mais do banco | `web/src/lib/types.ts:224` |
| Baixo | Sem Content-Security-Policy | `web/vercel.json` |

**Estrutura sem custo:** ESLint (`typescript-eslint`, `react-hooks`, `jsx-a11y`); Vitest para as funções
puras de `ocr.ts` e `types.ts`; pgTAP nas funções `app_*` (maior retorno, porque a regra mora no
banco); Playwright depois, com um teste curto de login e criação de escala. Tudo no CI da etapa 14.

## 4. Banco e infraestrutura (Infra/BD)

**Medido (um ano simulado):**

| O quê | Resultado |
|---|---|
| Núcleo em 1 ano | 199 MB, dos quais `notificacoes` = 174 MB |
| Motor completo | 53, 10 e 9 ms |
| `vw_acoes_pendentes` (cache frio) | 150 ms |
| Excluir técnico com 260 escalas | **3.526 ms** sem índice, **39 ms** com índices em `respostas(notificacao_id)` e `ocorrencias(escala_id)`; o limite do painel é 8 s |
| `fn_limpeza_logs` | 272 ms |

**Achados:**
- **Sem backup nenhum.** Cuidado na etapa 18: dump diário completo por 30 dias passa da cota de
  5 GB de egress; fazer semanal completo e diário do núcleo, sem `webhook_eventos` e `cron.*`. O
  plano gratuito permite só dois projetos, então a restauração de teste roda num Postgres dentro do
  próprio GitHub Actions. O Storage precisa de cópia própria.
- **`notificacoes` sem retenção:** no volume simulado, o limite de 500 MB chega em cerca de 2,5 anos
  (no volume atual, bem mais). Anular `payload_envio` depois de 90 dias resolve.
- **10 chaves estrangeiras sem índice**; duas pesam de verdade (acima).
- **Motor sem trava contra execução paralela:** o pg_cron não sobrepõe o mesmo job, mas uma chamada
  manual no SQL Editor junto com o cron pode enviar a mesma escala duas vezes. Correção: advisory
  lock no início e `statement_timeout` local.
- **Falhas silenciosas:** Evolution fora do ar ou sessão do WhatsApp caída não param o motor, então o
  vigia não percebe; e o aviso do vigia sai pelo próprio WhatsApp. Supabase fora ou pausado não avisa
  ninguém. Proposta sem custo: ping do motor num serviço gratuito de "dead man's switch"
  (healthchecks.io) que manda e-mail se o ping parar, e checagem do `connectionState` da Evolution.
- **Drift:** a homologação roda PostgreSQL 17.6 (a documentação diz 15); conferir a produção. Ficam
  fora das migrations: `config`, cron, Vault, Auth e Edge Functions (publicadas da máquina de alguém).
- **Scripts:** `npx supabase` sem versão fixa; `aplicar-homologacao.sh` aceita qualquer branch sem
  confirmação. O `painel.sh` usava `npm install`, que podia reescrever o `package-lock.json` e travar
  o `aplicar-producao.sh`. **Corrigido para `npm ci`.**
- Restrição `documentos_origem_coerente` está `NOT VALID`; `idx_notif_wa` duplicado (etapa 9).

## 5. Prioridades consolidadas

Ordem sugerida, juntando as quatro análises. Etapa nova proposta aparece como "nova".

| # | O quê | Por quê | Quem | Etapa |
|---|---|---|---|---|
| 1 | Etapa 7 na produção (teste conjunto, merge, script, `vigia-motor`) | Já está pronta | Responsável | 7 |
| 2 | Configurações de 10 minutos: login da homologação, senha mínima 12, desligar o Retool | Destravam o resto e fecham acesso SQL à produção | Responsável | 5, 6, 16 |
| 3 | Backup diário gratuito com teste de restauração | Hoje uma perda de dados é irrecuperável | Claude | 18, adiantada |
| 4 | CI (build, lint, migrations em banco vazio, `plpgsql_check`, audit) | Tira do responsável a conferência manual | Claude | 14, adiantada |
| 5 | Correções das Edge Functions: CORS e chave do `documento-ocr`, assinatura Twilio, JWT, timeouts, `xlsx` | Um recurso quebrado e três riscos altos | Claude | 11, 12, 13 |
| 6 | Robustez do banco: índices das FKs, retenção de `notificacoes`, trava e timeout do motor, validação de `config`, limpeza do legado | Evita travar exclusão, encher o banco e envio duplicado | Claude | 8, 9 + nova 9b |
| 7 | Monitor externo (ping por e-mail) e sessão do WhatsApp | Hoje as piores falhas são silenciosas | Claude | nova 7b |
| 8 | Decisões de negócio: fechar escalas passadas, recusa libera horário, suspensão/advertência, CNH, CPF | Travam as etapas 10, 20 e 21 | Responsável | 10, 20, 21 |
| 9 | Fase 0 de dados: motivo de recusa estruturado e tempo de resposta | Barata; pré-requisito de indicadores | Claude | nova |
| 10 | Editar e reagendar escala, substituir técnico após recusa | Maior atrito diário do gestor | Claude | nova (backlog) |
| 11 | Data para a API oficial da Meta | Evolution pode bloquear o número e derrubar o produto | Responsável | 22 |

## 6. Decisões que só o responsável pode tomar

1. Escala confirmada vira concluída sozinha quantas horas depois do término previsto? A recusada libera o horário?
2. Suspensão e advertência: quem vê (só admin, ou admin e gestor)? Por quanto tempo ficam guardadas? Ou ficam no sistema do RH?
3. CNH continua como categoria de documento?
4. O cadastro passa a ter CPF? Com cerca de 13 técnicos, casar pelo nome e deixar uma pessoa conferir evita coletar mais um dado pessoal.
5. Aceita adiantar o CI (14) e o backup (18) para antes das etapas 8 a 13?
6. Aceita incluir no plano as etapas novas 7b (monitor externo), 9b (retenção e índices), fase 0 de dados e editar/reagendar escala?
7. Aceita o custo por uso da API oficial da Meta (estimado em R$ 8 a R$ 11 por mês)? Em que data?

## Feito durante a análise

- Homologação: dados fictícios do `supabase/seed.sql` carregados (estava sem técnico e sem local; o
  seed tinha falhado na montagem) e espaço das simulações recuperado com `vacuum full` (14 MB).
- `scripts/painel.sh` usa `npm ci`.
- Plano de trabalho: passo manual do `vigia-motor` na etapa 7 e registro corrigido.
