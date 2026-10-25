# Multiempresa (tenant `contas`): estimativa para a decisão 76

**Situação:** aprovada pelo responsável em 24/10 (decisão 108).
**Data:** 24/10/2026. **Autor:** engenheiro-saas, para o CTO decidir e o responsável aprovar (decisões 76 e 102).
**Base:** ata de 17/10 (`docs/reunioes/2026-10-17-revisao-saas.md`), leitura do repositório e catálogo da homologação
(somente leitura, 24/10). **Prontidão SaaS:** não está pronto para o 2º cliente na mesma instalação; o isolamento hoje
depende de haver um cliente só.

## 1. Situação medida

| Item | Medido | Origem |
|---|---|---|
| Tabelas no `public` | **61** (homologação, 24/10) | catálogo |
| Com `empresa_id` | **19**: 17 não nulas (ponto, `times`, `cargas_horarias`, `carga_*`) e 2 que aceitam nulo (`tecnicos`, `programacao_aceites`) | catálogo; migrations 53 a 107 |
| Sem `empresa_id`, com dado de cliente | ~36: `empresas`, `locais`, `escalas`, `notificacoes`, `respostas`, `ocorrencias`, `escala_eventos`, `ligacoes`, `alertas_enviados`, `webhook_eventos`, `documentos`, `tecnico_documentos`, `tecnico_habilidades`, catálogos (`habilidades`, `tipos_*`), `feriados`, `painel_usuarios`, logs `painel_*`, `log_exclusoes`, `dossie_geracoes` e 10 do ponto (sessões, códigos, ciências, acessos, conversas, anexos, motivos, verificações) | migrations 01 a 92 |
| Da plataforma (sem conta) | 6: `config` (vira o padrão), `backlog_itens`, `motor_estado`, `saude_testes`, `ponto_geo`, `webhook_token_trocas` | — |
| Unicidade global que impede a mesma pessoa em duas contas | `tecnicos.telefone_e164`, `tecnicos.cpf`, `empresas.cnpj`, nomes de `habilidades`/`tipos_*`, `painel_usuarios.email` | migrations 01, 14, 19, 36, 53 |
| Funções | **110** `app_*` (~100 tocam dado de cliente), **18** `ponto_*`, **162** `fn_*` | catálogo |
| Autorização | `app_exigir` confere só e-mail, papel global e MFA global; `app_empresas` devolve todas; `app_ponto_afd(p_empresa, …)` recebe a empresa por parâmetro | migrations 14, 53, 77, 87 |
| Login do ponto | `ponto_pedir_codigo` e `ponto_entrar` por CPF, único no sistema inteiro | migration 55 |
| Configuração | **72** chaves em `config`, globais; muitas são regra do cliente (`fuso`, janelas, prazos, `usar_botoes`, `evolution_instancia`, `twilio_caller_id`, `mfa_obrigatorio`, prazo do espelho) | catálogo |
| Segredos no Vault, todos globais | `EVOLUTION_API_KEY`, `WEBHOOK_TOKEN`(+anterior), `TWILIO_*`, `VOZ_TOKEN`, `COFRE_PONTO`, `ESPELHO_ASSINATURA`, `ESPELHO_PDF_TOKEN`, `GOOGLE_VISION_KEY` | `fn_segredo` |
| Motor e canal | uma instância Evolution (`fn_evo_post`); tarefas do `pg_cron` varrem a plataforma inteira; teto de envio global | migration 100, `supabase/setup/cron.sql` |
| Storage | bucket `documentos` sem prefixo por cliente | migration 39 |
| Edge Functions | 4 de 4 afetadas: `webhook-evolution` (instância → conta), `voz-escala` (Twilio global), `documento-ocr` (chave e cota globais), `espelho-pdf` (já por empresa, impacto baixo) | `supabase/functions/` |
| Painel | 41 `.tsx`, 22 citam empresa, 128 chamadas em `api.ts`; papel global em `App.tsx`; Usuários, Admin e Roadmap misturam plataforma e cliente | `web/src/` |
| Teste de vazamento entre contas | **não existe** (a regressão vai de T1 a T52, nenhum com duas contas) | `supabase/tests/regressao.sql` |

## 2. Modelo proposto

- **`contas`** é quem contrata o Trilha; abaixo, **`empresas`** com `conta_id` e tipo (empregadora ou tomadora), CNPJ
  único dentro da conta; **`locais`** fazem o papel de estabelecimento (tabela própria só se o AFD exigir CNO/CAEPF por
  filial — conferir com o `juridico`).
- **Usuário ligado à conta:** `conta_membros(auth_uid, conta_id, papel, ativo)` substitui `painel_usuarios`; papel por
  conta (um BPO de RH entra em várias). **`plataforma_admins`** separada (Infoxtec); entrar na conta de um cliente exige
  consentimento registrado.
- **Uma fonte de contexto, no banco:** `fn_conta_atual()` — painel: conta escolhida validada em `conta_membros` e fixada
  por sessão do Auth; ponto: sessão → funcionário → conta; WhatsApp: instância → `conta_canais` → conta; URA: ligação →
  escala → conta; cron: um laço por conta. As `app_*` não recebem conta por parâmetro.
- **`conta_id` não nulo em toda tabela de cliente**, com chave estrangeira composta `(conta_id, id)`: o banco recusa uma
  escala de uma conta apontando para técnico de outra, mesmo com bug na função.
- **Filtro nas funções, não RLS com políticas** (recomendação): todo acesso já passa por `security definer`, cujo dono
  ignora RLS sem `FORCE` e papel sem `BYPASSRLS` (a provar no Supabase), e políticas com `current_setting` em ~55
  tabelas custam desempenho e depuração. Camadas: (1) `app_exigir` fixa a conta e o módulo, falta de escopo nega;
  (2) chave composta; (3) RLS ligado sem política, como hoje; (4) esquema privado (074); (5) teste de vazamento no CI.
  RLS com política fica como 6ª camada opcional (P2).

## 3. Fases e esforço

Unidade: **semana-pessoa no ritmo atual do par** (Claude implementa; o responsável testa e aprova a produção). O
gargalo é teste e revisão, não escrita.

| # | Fase | Entregáveis | Semanas |
|---|---|---|---|
| F0 | Desenho e régua | Matriz módulo × papel × escopo aprovada pelo `seguranca`; teste de vazamento A × B **gerado do catálogo** (toda `app_*` e `ponto_*` chamada pela conta B sobre dado da A recusa ou volta vazio; função nova sem cobertura quebra o CI); checagem "toda tabela de cliente tem `conta_id`". Entra falhando de propósito | 0,5–1 |
| F1 | Expandir dados | `contas`, `conta_membros`, `plataforma_admins`, `conta_modulos`; `conta_id` nulo em ~55 tabelas, preenchido com a **Infoxtec como conta 1**, depois `not null`, chaves compostas e índices; unicidades novas por conta ao lado das antigas | 1–1,5 |
| F2 | Contexto e reescrita | `fn_conta_atual`; `app_exigir` com conta e módulo; ~100 `app_*` filtrando; `app_ponto_afd` sem empresa livre; login do ponto com o identificador da conta; local de referência do ponto só da própria conta; Storage com prefixo | 2,5–3,5 |
| F3 | Painel | Seletor de conta, papel por conta, telas da plataforma separadas, usuários por conta (22 telas citam empresa) | 1–1,5 |
| F4 | Configuração por conta | `config_conta` sobre o padrão global; `fn_config` resolve a conta; fuso único; feriados por UF e município; MFA por conta | 1–1,5 |
| F5 | Canal e motor | `conta_canais` (instância, token e segredo por conta no Vault); webhook por instância; fila justa (rodízio) e teto por conta | 1–2 |
| F6 | Contrair | Fim do "sem empresa vê tudo" e do "funcionário sem empresa avisa todos os supervisores" (decisão 107), das unicidades globais e de `painel_usuarios`, com o painel novo já publicado (decisão 24) | 0,5 |
| F8 | Entrada e saída | `app_plataforma_criar_conta` repetível; exportação completa; exclusão registrada (LGPD art. 16) respeitando a guarda de 5 anos do ponto — obrigação de operador já no 2º cliente | 1–1,5 |
| **Núcleo** | **074, F0–F6 e F8: 2º cliente na mesma instalação** | | **9–13,5** |
| F7 | Cotas, custo e observação | Contadores por conta (mensagens, ligações, OCR, armazenamento, técnicos, assentos), alertas com o nome da conta, SLO do envio | 1 |

**Ordem:** 074 (esquema privado, mecânico: `set schema` e `search_path`, 0,5–1 semana, ordem da decisão 76) → F0 → F1 → F2 → F3, com F4 em paralelo a partir da F2; depois F5 → F6 → F8. F7 antes do 3º cliente. **Pré-requisito da 1ª venda:** painel fora do plano gratuito da Vercel (etapa 17, decisão 75).
**Sem parada:** cada fase é um PR que a produção recebe com a Infoxtec operando — expandir (coluna nula), preencher,
trocar a leitura, só depois contrair. As assinaturas das `app_*` não mudam (a conta vem do contexto) e a regressão
T1–T52 verde em toda fase garante que a conta 1 se comporta como hoje.
**Calendário:** começando em 09/11, o núcleo fica pronto entre meados de janeiro e o início de março de 2027. A ata
falava em 6–10 semanas; a faixa subiu para 9–13,5 pela reescrita de ~100 funções, pelo 074 e pela F8 dentro do núcleo
(revisão do CTO, 24/10).
**Custo por conta (mesma instalação):** fixo marginal ~zero até os limites do plano; variável R$ 1,50–2,00 por técnico
ativo por mês (`plano-comercial.md` §7), mais o número de WhatsApp e a URA (R$ 0,24 por ligação); banco ~1 MB por
técnico por ano, sem o cofre. **Instalação separada por cliente (opção A):** um projeto pago (~US$ 25/mês), um painel e
operação repetida por cliente.

## 4. Riscos e o que não entra

- **P0 — vazamento numa `app_*` esquecida.** Teste gerado do catálogo e chave composta.
- **P0 — regressão na conta 1 durante a F2.** Um PR por família de funções, regressão completa em todos e pausa de
  funcionalidade nova no período.
- **P0 — parecer V1 sobre "uso exclusivo" do REP-P (decisão 103)** pode exigir separar o Ponto por cliente: o Ponto só
  liga para cliente externo depois do parecer, por `conta_modulos`.
- **P1 — WhatsApp compartilhado entre contas** mantém o telefone único global e o vizinho barulhento: instância por conta.
- **P1 — Supabase Auth com várias contas por usuário**, ainda não provado: primeiro teste da F2.
- **P1 — `COFRE_PONTO` com chave única:** aceitável no núcleo; chave por conta é P2.
- **Incerteza:** regras implícitas de "uma operação só" nas 162 `fn_*` do motor só aparecem na F2; a estimativa erra
  para mais.
- **Fora:** restaurar um cliente sem voltar os outros, API pública e webhooks para o cliente, liberação gradual por
  chave, API oficial da Meta (decisão 74, sob demanda), cofre fora do banco, PAdES ICP-Brasil, painel no Cloudflare (etapa 17, já em andamento).

## 5. Decisões do responsável (com recomendação)

1. **Tenant:** a conta é quem contrata e pode ter várias empregadoras; a mesma pessoa pode estar em duas contas. **Sim.**
2. **Canal:** número próprio ou API oficial da Meta, à escolha do cliente (decisão 74), sem compartilhar o da Infoxtec; Twilio também por cliente. **Sim.**
3. **Ordem do 074.** Engenheiro-saas: junto com a F2, para não mexer nas funções duas vezes. **CTO: antes, como manda a
   decisão 76** — o 074 é mecânico (`set schema`, `search_path`, sem reescrever corpo) e juntá-lo aumenta o raio de erro do
   PR mais arriscado. **Recomendação final do time: o do CTO (074 antes).**
4. **Cliente externo antes do núcleo:** só em instalação separada (opção A), com o projeto Supabase Pro repassado no
   preço — exceção à decisão 29, com texto próprio. **Sim.**
5. **Supabase Pro** antes do 2º cliente na mesma instalação — outra exceção à decisão 29. **Sim.**
6. **Ponto fora do pacote externo** até o parecer V1 e o G6. **Sim.**
7. **Pausa de funcionalidade nova nas `app_*`** durante a F2 (~3 semanas). **Sim.**
8. **Estabelecimento = `locais`**, sem tabela nova, salvo exigência do AFD (parecer do `juridico` sobre CNO/CAEPF). **Sim.**

**Texto proposto para a decisão:** "O cliente da plataforma é `contas`, acima de `empresas`. Todo dado de cliente leva
`conta_id` não nulo, com chave estrangeira composta. A conta vem de `fn_conta_atual()` (sessão do painel, sessão do
ponto ou instância do WhatsApp) e é imposta em `app_exigir` (filtro nas funções, sem política de RLS); falta de escopo nega. O isolamento é provado por um teste
de vazamento gerado do catálogo, critério de merge. Núcleo: 9 a 13,5 semanas-pessoa; até lá, cliente externo só em
instalação separada."
