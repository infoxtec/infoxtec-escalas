# Análise do código — Trilha

27/09/2026 · personas **Dev (banco)** e **Fullstack**, consolidadas por **Infra/BD**, com parecer de
**CTO**, **PO** e **Segurança** (§5). Somente leitura: nada foi executado no banco, nenhum arquivo
alterado, nenhum build rodado.

**Medido, não estimado:** 48 migrations e **6.259 linhas** de SQL · **23 tabelas** · **8 views** ·
**113 funções distintas** (110 vivas: a migration 45 remove 3) · **53 `app_*`** · **7 gatilhos** ·
48 chaves de `config` em migrations + 3 em `supabase/setup/config.sql` · painel com **4.564 linhas**
em 28 arquivos · **377 linhas** nas 3 Edge Functions.

> **Atualização de 28/09/2026:** três achados desta auditoria foram resolvidos depois dela — o **dado
> de saúde entregue ao papel `leitura`** (S1, pela remoção do motivo de saúde, decisão 40), o **modo
> Drive** (L12, descontinuado na decisão 41) e o **cabeçalho desatualizado do `banco-de-dados.md`**
> (D4, corrigido: agora diz 23 tabelas, 8 views, 110 funções, 01 a 49). O defeito **C1** — `tipo` e
> `teste` coletados e nunca enviados — **continua aberto**, e é o tema DEV-01 no
> [painel de controle](painel-de-controle.html).

> **Correção de número:** `docs/banco-de-dados.md` diz 5 gatilhos; são **7**. Não é o pior erro do
> documento — ver §1.5.

---

## 1. Banco de dados

### 1.1 Onde está o risco real: 28 funções recriadas, 48 versões descartadas

28 nomes de função têm de 2 a 7 definições ao longo das migrations — 76 `create` para 110 funções
vivas. Saber o que vale exige contar até a última ocorrência ou consultar o banco.

| Função | Versões | Vigente |
|---|---|---|
| `fn_dispatcher_whatsapp` | **7** (11, 17, 19, 40, 41, 44, 45) | `45:61` |
| `fn_pendencias_escala` · `fn_mudar_status` · `fn_criar_escala` · `app_resumo` | 4 cada | `46:6` · `18:11` · `30:33` · `35:4` |
| `fn_wh_mensagem` · `fn_painel_locais` · `fn_alerta_certificacoes` · `app_registrar_documento` · `app_documentos` · `app_definir_habilidades` · `app_criar_escalas` | 3 cada | `47:23` · `35:26` · `36:141` · `37:106` · `37:140` · `41:41` · `31:6` |
| mais 17 funções | 2 cada | — |

**Isto não é hipótese — já custou caro.** A comparação de hora local com UTC
(`(data_servico + hora_inicio) > now()`) sobreviveu em **5 versões de 3 objetos**
(`vw_acoes_pendentes` 03 e 10, `fn_wh_mensagem` 12, `vw_ligacoes_pendentes` 23 e 29) e só foi
corrigida na 39 e na 41. Quem recriar aquela view copiando a 29 **reintroduz o motor parando 3 horas
antes**. O caso mais didático: a migration 03 já tinha a CTE `agora` e mesmo assim comparava com
`now()` — a correção ficou pela metade por 20 migrations.

Pares perigosos do mesmo tipo: `fn_excluir_tecnico` da 09 **não tem trava de papel** (a vigente tem);
`fn_remover_escala` da 15 não conhece escala de teste; `app_backlog` da 26 não devolve
`coluna`/`posicao`; `app_registrar_documento` foi anunciada como "versão final" na 33 e mudou na 34 e
na 37.

### 1.2 Duplicação de lógica

1. **O motor é copiado inteiro.** As fases 1–3 do dispatcher estão repetidas em **6 arquivos**
   (~74 linhas idênticas). Foi assim que a fase 6 ficou fora do repositório e obrigou a migration 40
   a reproduzir a produção.
2. **`fn_wh_mensagem` (243 linhas) × `fn_voz_resposta` (51)** implementam "o técnico disse 1/2" com
   efeitos diferentes. Duas divergências concretas: a **URA nunca pede o motivo da recusa** (o fluxo
   1–5 existe só no WhatsApp), então o indicador de recusas conta as de telefone como "não
   informado"; e a URA grava `respostas` sem `notificacao_id` nem `wa_message_id`, então essas
   respostas **não aparecem** na linha do tempo da escala.
3. **Fuso repetido 33 vezes** em 19 migrations (≈12 pontos vigentes), sem `fn_agora_local()`. Cada
   ponto novo é uma chance de repetir o bug acima.
4. **`vw_resumo_dia` × `app_resumo`**: a mesma agregação em dois lugares, com filtros diferentes — a
   view não exclui teste nem supervisor, a função exclui. Dois números para a mesma pergunta.

### 1.3 Objetos mortos

**Funções vivas sem chamador:** `fn_set_ator` (zero uso), `app_config` e `app_documentos_expirados`
(não estão em `api.ts`), `app_salvar_tecnico_habilidade` (substituída por `app_definir_habilidades`),
`fn_evo_get`/`fn_http_resposta` (só uso manual no SQL Editor).

**Colunas só de escrita ou nunca usadas:** `escalas.observacao_gestor` (nunca escrita **nem** lida),
`ocorrencias.resolvida_em`, `ocorrencias.status` (nunca sai de `aberta`), `documentos.ocr_texto` e
`ocr_em`, `respostas.button_payload`, `notificacoes.template_nome`, `escala_eventos.detalhe` (gravado
e **não** exposto pela linha do tempo), `tecnicos.opt_in_em`, `ligacoes.preco` (`app_ligacoes` não
devolve), `motor_estado.atualizado_em`.

**Outros mortos:** o valor de enum `escalas.status = 'reagendada'` (nenhuma função atribui — o
reagendamento volta para `notificada`); as chaves `template_escala`, `template_lembrete`,
`documento_tamanho_max_mb` e `whatsapp_provedor` (zero leitores); e
`update config ... where chave = 'evolution_versao'` (migration 11) que **não faz nada** num banco
montado pelo repositório, porque nenhuma migration cria essa chave.

### 1.4 Complexidade e testabilidade

| Função | Linhas | Por que é cara |
|---|---|---|
| `fn_wh_mensagem` (47:23) | **243** | 30 variáveis, **4 caminhos** de resolução de escala (botão, citação, heurística de 12 h, motivo por número), 3 `insert` em `respostas` e 2 em `ocorrencias`. É 10% de todo o SQL de funções |
| `fn_dispatcher_whatsapp` (45:61) | **131** | 7 fases; a fase 1 varre **todas** as notificações `enfileirada` sem limite; a fase 3 varre a view inteira e faz **1 HTTP por supervisor** em laço. Só a fase 2 é limitada |
| `app_editar_escala` (48:26) | **81** | Duplicada quase integralmente da 47 (mudaram 3 linhas) |

**Testabilidade:** não existe **nenhum** teste de SQL. O portão do CI é `plpgsql_check` (estático) +
a checagem de que toda `app_*` tem `security definer` e `app_exigir` — **nenhuma asserção de
comportamento**. É impossível testar sem banco, rede e Vault: todo o motor depende de `net.http_post`,
`fn_segredo` e `net._http_response`. As views do motor dependem de `fn_config` **e do relógio**.
Melhores candidatos, em ordem de retorno: contrato por `app_*` com papel `leitura`/`gestor`;
`fn_wh_mensagem` com payloads reais da Evolution; `fn_calcular_jornada`, que é praticamente pura.

### 1.5 Fragmentos perigosos de manutenção

| Onde | O que |
|---|---|
| `36:73-76` | `drop view ... cascade` derruba `app_tecnico_habilidades` (declarada `returns setof` da view) e **só a migration seguinte a recria**; dois `drop column` sem volta; e `delete from habilidades where exige_validade` apaga NR/CNH/ASO semeados nas migrations 20 e 22 |
| `45:28-31` | `create unique index` novo sem tolerar dado preexistente, **enquanto a mesma migration trata o caso gêmeo com `exception`** |
| `14:145` × `30:110` | Duas políticas opostas de exclusão: `fn_excluir_tecnico` apaga **todas** as escalas (inclusive concluídas), `fn_remover_escala` protege as respondidas |
| `37:60` | `delete from tipos_documento` em cascata apaga a validade de **todos** os técnicos; o `p_forcar` só troca a mensagem |
| `20:4` e `30:53` | `drop function if exists <assinatura>`: se a assinatura não bater exatamente, vira no-op silencioso e ficam dois overloads |
| `45:187` vs `45:194` | `fn_dispatcher_whatsapp` chama `fn_evolution_falhando()` **antes** de ela ser criada no mesmo arquivo (funciona em plpgsql, quebra leitura estática) |
| `05`, `10`, `19`, `25`, `30`, `32`, `33`, `36` | **8 migrations cujo cabeçalho declara não conter o que foi aplicado.** A 25 diz que o dispatcher completo "está aplicado no banco" — foi exatamente isso que obrigou a migration 40 |
| `16:11` | `app_exigir` confere papel e devolve **e-mail**, não escopo: filtrar por equipe exige tocar as 53 `app_*` |

### 1.6 O que ajuda e o que resiste à expansão em quatro módulos

**Ajuda:** `fn_calcular_jornada` (17:17) é a peça mais bem isolada do repositório — só depende de
`config`, é `stable`, já tem porta de leitura (`app_simular_jornada`) e carrega a matemática CLT
(noturno, hora reduzida de 52,5 min, intervalo, Súmula 60). Serve de base para **ponto** sem
reescrever nada. Documentos já têm as três pontas (catálogo, exigência por tipo de serviço, aptidão
calculada) e `escalas.tipo_atividade_id` é a âncora natural para projeto/atividade.

**Resiste:**

- **Ponto:** não existe registro real de jornada — só o previsto. `fn_concluir_escalas` marca
  `concluida` **pelo relógio**, não por entrada/saída. Exige tabela nova e apuração que não existe.
  (O status `em_execucao` já está lá, pronto para ancorar o ciclo real.)
- **Liberação para obra:** `fn_aptidao` existe e **não é exigida em nenhum caminho de criação** —
  `fn_criar_escala` e `app_criar_escalas` não a chamam, e o aviso da tela não bloqueia. O portão
  nasce **fora** do banco, contra a decisão 1.
- **Projetos/Gantt/Curva S:** não existe tabela de projeto, atividade, vínculo com escala, baseline
  ou medição. `backlog_itens.depende_de` é **texto livre** — não dá grafo, caminho crítico nem curva
  S. E o Kanban da tela está amarrado a `ItemBacklog`, com as colunas numa constraint de
  `backlog_itens`: reusar exige generalizar componente **e** banco.
- **Acesso por área:** `painel_usuarios` tem só e-mail/nome/papel/ativo; `tecnicos.equipe` é texto
  livre **sem nenhum leitor**; e o único ponto central (`app_exigir`) não devolve escopo.

---

## 2. Painel e Edge Functions

### 2.1 Estrutura e concentração

- `App.tsx` acumula quatro responsabilidades (sessão, inatividade, versão publicada, acesso e abas)
  e a permissão aparece inline em **três pontos** do mesmo arquivo.
- **Não há rota:** trocar de aba desmonta a página e **perde filtros e período da Agenda**, refazendo
  as RPCs.
- Dono do dado inconsistente: 3 páginas recebem cadastros por props, 4 buscam sozinhas; o mesmo
  `app_habilidades()` é chamado por duas telas.
- `HabilidadesPage.tsx`: **515 linhas** com quatro componentes — três módulos do produto num arquivo
  (documentos, habilidades, tipos). `EscalaDrawer.tsx`: **323 linhas**, 8 estados, 3 overlays.

**Ponto forte a preservar:** `api.ts` é o único gateway (46 `app_*`, nenhuma chamada órfã) e
**não existe `any`** em `web/src`.

### 2.2 Duplicação

O esqueleto `carregar/useEffect/try-catch/erroMsg` aparece **7 vezes**; `erroMsg` tem **31 pontos**
em 13 arquivos; o rodapé de modal "Cancelar/Salvando/Salvar" **9 vezes**; "Larguras padrão" 4 vezes;
**cinco formatos** de "rótulo + classe" para o mesmo dado do banco (`SEMAFORO_CLASSES`,
`STATUS_BACKLOG`, `SITUACAO_DOC`, `PRIORIDADE_BADGE`, `STATUS_CLASSE`); `semAcento` duas vezes; e o
limite de arquivo **8 MB tem três fontes** (tela de arquivos, tela de lote e a configuração do banco).

E a regra de extrair/escolher a data de validade existe em **três cópias**, sendo duas linguagens
(`web/src/lib/ocr.ts` e `supabase/functions/documento-ocr/index.ts`) — regra de negócio duplicada
fora do banco.

### 2.3 Tipagem e contrato com o banco

- `rpc<T>` devolve `data as T` sem validação, para 46 funções, com o contrato **espelhado à mão** em
  `types.ts` (não há `supabase gen types`). Renomear uma chave no `jsonb_build_object` vira
  `undefined` silencioso na tela.
- **Drift já existente:** `Documento.ocr_em` é declarado no painel e o banco **deixou de devolver**
  na migration 37. Nada quebra porque a tela não lê o campo — é a prova de que o tipo não acompanha.
- **Uniões fechadas usadas como índice, sem fallback:** `SITUACAO_DOC[...]`, `STATUS_BACKLOG[...]` e
  `PAPEL_LABEL[...]` geram `TypeError` (ou rótulo vazio) quando o banco manda um valor novo — e
  **papel novo é exatamente o que o acesso por área vai introduzir**.
- Payload por `Record<string, unknown>` e `Partial<T>` justamente onde o banco lê por nome: um erro
  de digitação em `nome_arquivo`, `mime` ou `tamanho_bytes` vira `NULL` **sem erro**.

### 2.4 Erro e carregamento

- **Nenhum `ErrorBoundary`** em `web/src` e nenhum handler global: exceção de render = **tela
  branca**, sem relato. Agrava: a recarga automática de build propaga um build quebrado para todas
  as abas em até 3 minutos.
- **Erros engolidos:** habilidades (`catch {}` → a seção diz "Nenhuma habilidade cadastrada"), jornada
  e aptidão (`setJornada(null)` → "Calculando a jornada…" eterno), motor/indicadores (`setMotor(null)`
  → o gestor não distingue "não agendado" de "falhou").
- **Vazio enganoso:** "Nenhum técnico encontrado" aparece com a lista vazia **enquanto carrega**.
- **Atualização de 60 s sem checar `document.visibilityState`** (ao contrário do resto do produto) e
  **sem cancelamento** — consultas multiplicadas por aba e suspeita de resposta antiga sobrescrevendo
  a atual.

### 2.5 Acessibilidade e uso em campo

O gestor usa isso **no celular**, e é onde está pior: nenhum formulário tem rótulo ligado ao campo
(`label` sem `htmlFor`); toast e caixa de erro sem `aria-live`/`role="alert"`; modal sem foco inicial,
sem trap e sem `aria-labelledby` (**Escape fecha dois overlays de uma vez**); sete botões de navegação
**sem nome acessível** em tela pequena; linha de tabela e Kanban **só funcionam com mouse** (o Kanban
usa drag-and-drop HTML5, que não funciona em toque — e "projetos" tende a repetir o Kanban); e
**tabelas com ações cortadas e inalcançáveis** em `UsuariosPage`, `DocumentosArquivos` e
`HabilidadesPage`, justamente onde ficam os botões de editar e excluir.

### 2.6 Desempenho e dependências

Bundle único (8 páginas importadas de forma estática, só `ImportarEscalas` é `lazy`), sem
`manualChunks`. Insumos instalados: `pdfjs-dist` 35 MB, `lucide-react` 31 MB, `xlsx` 7,2 MB,
`react-dom` 4,4 MB. **Tamanho do bundle não medido** (build não foi rodado nesta auditoria).

O OCR do navegador depende de **CDN de terceiro em tempo de execução** (`cdn.jsdelivr.net`, ~15 MB na
primeira leitura): em rede ruim no campo, "Ler de novo" falha — e o comentário do código sugere
autonomia total. `xlsx` está vendorizado fora do registro npm e **fora do `npm audit`** do CI.
**Zero lint** (sem ESLint/Prettier) e **zero teste**.

### 2.7 Edge Functions

Não existe `_shared/`: cada função recria o cliente `postgres`, o helper `json()`, o limite de corpo
(**três constantes diferentes**: 12 MB, 5 MB e nenhuma) e o `TIMEOUT_MS` (15 s e 10 s). Sem
`deno.json`/`deno.lock`, a dependência é fixada por string em três arquivos.

Limite de corpo existe e vem **antes** da leitura, mas o corpo é bufferizado inteiro e recontado
depois — em requisição *chunked* o limite só vale com a memória já gasta. **Nenhuma das três limita o
tempo da consulta ao banco** (`AbortSignal` só cobre `fetch` externo) — se uma função SQL travar, a
função segura a requisição e a Evolution/Twilio reenviam. `documento-ocr` autentica três vezes
(config da plataforma, `/auth/v1/user` e `fn_papel`) e `voz-escala` vai ao Vault **a cada requisição**,
inclusive nos callbacks da Twilio.

### 2.8 Subcaminho `/trilha`

Nada começou no código: sem `base` no Vite, assets absolutos em `index.html`, `App.tsx` e `Login.tsx`;
`fetch('/version.json')` **absoluto com 404 engolido em silêncio** (a recarga de versão para de
funcionar sem sinal — o certo é `import.meta.env.BASE_URL`); `redirectTo: window.location.origin` no
login, que devolve o link de senha para a raiz do site; e o rewrite da Vercel escrito para a raiz.

---

## 3. Achados consolidados

### 3.1 O que eu verifiquei e corrigi ao consolidar

| Achado do relatório | O que a verificação mostrou |
|---|---|
| **P0**: o `create unique index` da migration 45 pode derrubar a migration | **Corrigido para lição, não risco aberto.** A migration 45 **já foi aplicada em produção em 27/09** (`plano-de-trabalho.md:166`) — o índice foi criado com sucesso. Em banco vazio não há dado para conflitar. Resta a lição: a mesma migration tratou o caso gêmeo com `exception` e o índice não |
| **P1**: `app_substituir_tecnico` falha para escala já iniciada | **Confirmado.** Ela chama `fn_criar_escala` → `fn_validar_inicio`, que exige início ≥5 min à frente. Substituir técnico de uma recusa cujo horário já começou (exatamente quando a substituição é urgente) falha com a mensagem sobre antecedência |
| **P1**: `confirmada_em` é carimbado também para `recusada` e o indicador conta recusa como resposta | **Parcialmente procedente.** O gatilho realmente carimba nos dois status (`02:53-60`) — o nome da coluna é que mente ("confirmada" = "respondida"). Contar **recusa como resposta** está certo para "tempo de resposta"; o que falta é o PO definir o universo do indicador (o `app_indicadores_resposta` não exclui `perfil_teste` nem supervisor, ao contrário do `app_resumo`) |
| **P0**: `NovaEscalaModal` não envia tipo e teste | **Confirmado** — e nenhuma tela do painel envia: `p_tipo`/`p_teste` não aparecem em nenhuma chamada. A migration 31 consertou o **banco**, e o defeito ficou no **painel** |
| **P0**: `formatDate` sem guarda e sem `ErrorBoundary` | **Confirmado.** `types.ts:86-89` faz `d.split('-')` enquanto `formatTime` na linha seguinte é guardado; `main.tsx` não tem handler global |

### 3.2 P0 — consertar antes de qualquer coisa nova

| # | Achado | Onde | Impacto |
|---|---|---|---|
| C1 | **Tipo de atividade e marca de teste coletados e nunca enviados** | `NovaEscalaModal.tsx:73-76,126,176` + `api.ts:36-43` + `migration 31:6-9` | Toda escala criada pelo painel grava tipo nulo e teste falso; a exigência de habilidade **nunca fica registrada** e o checkbox de teste é inerte. É o achado funcional mais caro |
| C2 | **Sem `ErrorBoundary` e sem handler global**, com recarga automática de build | `main.tsx:7-13` + `sessao.ts:56-75` | Um erro de render vira tela branca para todos, e o gatilho concreto já existe (`formatDate`) |
| C3 | **`formatDate` sem guarda** | `types.ts:86-89` (uso em `AgendaPage.tsx:185`) | Um `data_servico` ausente derruba a Agenda inteira, sem mensagem |
| C4 | **`app_substituir_tecnico` inutilizável para escala já iniciada** | `47:402` + `30:21-31` | O recurso falha exatamente no caso urgente |

### 3.3 P1 — banco

| # | Achado | Onde |
|---|---|---|
| B1 | 28 funções com 2–7 definições, sem índice de versão vigente (o caso do fuso em 5 versões) | `45:61`, `47:23` e outros |
| B2 | Fases 1–3 do motor copiadas em 6 arquivos | `11, 17, 19, 40, 41, 44, 45` |
| B3 | `fn_wh_mensagem` com 4 caminhos de resolução e 243 linhas | `47:23` |
| B4 | **`fn_aptidao` não é exigida em nenhum caminho de criação** — liberação para obra não tem portão no banco | `36:101`; `30:33`; `31:6` |
| B5 | Papel global, sem equipe/área, e `app_exigir` sem escopo (53 `app_*` a tocar) | `14:7-15`; `16:11-22` |
| B6 | Sem modelo de projeto/atividade; `depende_de` é texto livre → **Gantt e Curva S partem de zero** | `26:12` |
| B7 | Sem registro real de jornada; `concluida` é marcada por relógio | `17:63-66`; `45:33-50` |
| B8 | Nenhum teste de SQL; o CI é estático | `ci.yml:70-124` |
| B9 | `drop view ... cascade` + 2 `drop column` + `delete` no mesmo bloco | `36:73-76` |
| B10 | Excluir técnico cascadeia `documentos` e deixa arquivo órfão no bucket | `32:8` |
| B11 | `app_excluir_tipo_documento(p_forcar)` apaga validade de todos os técnicos, só com contagem na mensagem | `37:46-61` |

### 3.4 P1 — painel e Edge Functions

| # | Achado | Onde |
|---|---|---|
| F1 | `rpc<T>` sem validação de forma, contrato espelhado à mão (46 funções) | `api.ts:13-17` |
| F2 | Uniões fechadas como índice, sem fallback — **quebra quando surgir papel de área** | `HabilidadesPage:206,212`; `RoadmapPage:147,158`; `UsuariosPage:84` |
| F3 | Erros engolidos (habilidades, jornada, aptidão, motor) | `TecnicosPage:29`; `NovaEscalaModal:40,47`; `OperacaoPage:79-80` |
| F4 | Vazio enganoso durante a carga | `HabilidadesPage:142-143` |
| F5 | **Tabelas com ações cortadas no celular** | `UsuariosPage:67-68`; `DocumentosArquivos:136`; `HabilidadesPage:132,196` |
| F6 | Rótulo não ligado ao campo; modal sem foco/trap; Escape fecha dois overlays | `ui.tsx:41-52,99-150` |
| F7 | Navegação só de ícones, sem nome acessível em tela pequena | `App.tsx:138` |
| F8 | Linha de tabela e Kanban só com mouse | `AgendaPage:184`; `Kanban.tsx:32,48-51` |
| F9 | Esqueleto de carga 7×, `erroMsg` 31×, rodapé 9×, 5 formatos de rótulo | vários |
| F10 | `HabilidadesPage` 515 linhas / 4 componentes; `EscalaDrawer` 323 / 8 estados | — |
| F11 | Abas sem rota: perde filtro e período a cada troca | `App.tsx:152-158` |
| F12 | Edge Functions sem `_shared`; três limites de corpo; sem timeout de banco | `functions/*` |
| F13 | OCR dependente de CDN de terceiro (~15 MB na 1ª leitura) | `ocr.ts:54` |
| F14 | Regra de data de validade em 3 cópias, duas linguagens | `ocr.ts:26-51`; `documento-ocr:45-59` |
| F15 | Refresh de 60 s sem visibilidade e sem cancelamento | `AgendaPage:53`; `OperacaoPage:86` |

### 3.5 P2 — higiene (agrupado)

Documentação desatualizada como fonte de verdade (`banco-de-dados.md` com 19 tabelas/92 funções/5
gatilhos/"01 a 35", função extinta e ordem de remover o que a 45 já removeu) · 12 colunas mortas e o
enum `reagendada` · chaves de `config` sem leitor e validação cobrindo só parte das chaves ·
`app_config` fechado em 9 chaves · funções sem chamador · duplicação de agregação
(`vw_resumo_dia` × `app_resumo`) · cabeçalhos de migration que não descrevem o arquivo (8 arquivos) ·
`drop function if exists <assinatura>` · papéis diferentes para ler e escrever na mesma tela ·
`trg_escalas_teste` só em `insert` · `fn_concluir_escalas` sem revalidar `hora_fim_prevista` ·
indicadores com universos diferentes · bundle único sem `manualChunks` · `xlsx` fora do `npm audit` ·
zero lint e zero teste · `ocr_em` no tipo sem o banco mandar · payload por `Record<string, unknown>` ·
`App.tsx` com 4 responsabilidades · dono do dado inconsistente · estado local denso.

---

## 4. O que fazer primeiro

A ordem junta o que é **defeito** (não dívida) com o que destrava o produto:

| Ordem | O quê | Por quê |
|---|---|---|
| 1 | **C1** — enviar `tipo` e `teste` da tela | É um defeito silencioso que já deveria estar em produção desde a 31; sem ele, "habilidades e requisitos" não tem dado real e o módulo de conformidade nasce oco |
| 2 | **C3 + C2** — guarda no `formatDate` e `ErrorBoundary` | São ~20 linhas que evitam a tela branca em todas as abas |
| 3 | **C4** — substituição de técnico em escala iniciada | É o caso de uso urgente do recurso mais recente |
| 4 | **B4** — decidir se `fn_aptidao` vira portão no banco | Sem isso, "liberação para obra" é aviso de tela, contra a decisão 1 |
| 5 | **B5** — `app_exigir` devolvendo escopo | É a fundação do acesso por área e evita tocar 53 funções duas vezes |
| 6 | **F2 + F1** — fallback nas uniões e validação no gateway | É o que impede uma tela branca quando o banco ganhar papel de área |
| 7 | **F5 + F6 + F7** — celular e acessibilidade | O gestor opera no celular; hoje ele não alcança os botões de ação |
| 8 | **B8** — o primeiro teste de banco (`fn_calcular_jornada` e contrato das `app_*`) | É o único jeito de a expansão em quatro módulos não virar regressão silenciosa |

## 5. Parecer

**CTO.** O código é organizado e as regras estão no lugar certo — o problema não é desenho, é
**acúmulo sem rede**: 28 funções com versões múltiplas, nenhum teste, nenhum lint, contrato de tipos
mantido à mão. Isso é sustentável para um módulo e não é para quatro. Antes de abrir ponto, projetos e
acesso por área, o investimento com maior retorno não é tela: é **teste de banco** e o **escopo em
`app_exigir`**. Sem isso, cada módulo novo repete o padrão que já custou 20 migrations de fuso.

**PO.** Três conclusões de produto: (a) o checkbox de teste e o tipo de atividade **mentem na tela** —
é o tipo de defeito que destrói confiança e precisa entrar como correção, não como melhoria; (b)
"liberação para obra" não é regra, é aviso — então não pode ser vendida como portão de conformidade;
(c) os indicadores usam universos diferentes, e indicador que não fecha é pior que indicador ausente.

**Segurança.** Nesta auditoria de código não há achado novo de segurança — os que existem estão na
análise de infraestrutura e na revisão anterior. Registro dois pontos que voltam aqui por outro
caminho: a **duplicação da regra de validade** em duas linguagens (a Edge Function e o navegador podem
divergir sobre a data que "aprova" um documento). O **motivo de saúde** saiu do sistema na migration
49 (decisão 40); o que continua aberto é o **acesso do papel `leitura` aos documentos** (SEG-14).

## 6. Limites desta análise

Não rodei build (tamanho do bundle é insumo instalado, não artefato), não executei SQL nem `plpgsql_check`,
não consultei homologação nem produção, e não verifiquei versões desatualizadas contra o registro npm.
Ficam como **suspeita**: se o índice da migration 45 teria falhado em produção (já aplicado em 27/09,
portanto não falhou), o custo real das subconsultas correlacionadas de `fn_aptidao` e
`app_documentos_por_tecnico`, a existência de corrida no refresh de 60 s, e o comportamento do rewrite
da Vercel sob o subcaminho.

**Fontes:** as 48 migrations, `web/src` (28 arquivos), `supabase/functions/*/index.ts`,
`web/package.json`, `web/package-lock.json`, `web/vite.config.ts`, `web/vercel.json`,
`.github/workflows/ci.yml`, `docs/banco-de-dados.md`, `docs/plano-de-trabalho.md`,
`supabase/setup/config.sql`.
