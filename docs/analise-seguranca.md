# Análise de segurança e LGPD — Trilha

27/09/2026 · persona **Segurança**, revisão de leitura do repositório. Complementa
[`analise-infraestrutura.md`](analise-infraestrutura.md) (onde cada coisa roda e como se recupera) e
[`analise-codigo.md`](analise-codigo.md) (como o código é escrito). Aqui a pergunta é outra: **o que
protege os dados e o que ainda não protege**.

Como ler: severidade **P0** = explorável hoje com impacto alto ou dado pessoal exposto sem base;
**P1** = risco real com mitigação parcial; **P2** = higiene. O que depende de painel, conta ou VPS está
em §7 e **não foi verificado**.

---

## 1. As camadas de controle (o que existe)

| Camada | Como funciona | Evidência |
|---|---|---|
| **Autenticação** | Supabase Auth, e-mail e senha. Cadastro público desligado na produção | `docs/seguranca.md`; `docs/deploy-vercel.md` |
| **Autorização** | Tabela `painel_usuarios` com `admin`, `gestor` e `leitura`; quem entra e não está lá vê "Acesso não autorizado" | `migration 14:7-26` |
| **Execução** | O navegador só chama `app_*`. Cada uma lê o e-mail de `auth.jwt()` e confere o papel — **a tela nunca informa quem é o usuário** | `migration 16:5-22` |
| **Banco fechado** | **23 tabelas, 23 com RLS ligado e zero políticas** (verificado por varredura); `revoke` de tabelas e views para `anon`/`authenticated` | `migration 39:105-107` |
| **Funções** | `EXECUTE` revogado de tudo e concedido só às `app_*`, por laço | `migration 12`, `39`, `48` |
| **Documentos** | Bucket privado, sem URL pública, link assinado de **2 minutos**, política por papel | `migration 39:99-104`; `web/src/lib/api.ts:140` |
| **Segredos** | Supabase Vault, lidos por `fn_segredo`; nenhum no repositório | `migration 07:7-11` |
| **Webhook** | Token de 64 caracteres conferido no banco contra o Vault; token errado recebe 401 e não chega ao banco | `migration 12:287` |

**Ponto forte que merece ser dito em questionário de cliente:** a decisão de manter RLS com **zero
políticas** é deliberada — nada é legível pela API, e todo acesso passa por função que confere papel.
Foi o que permitiu vender o desenho como "banco fechado" com evidência.

---

## 2. Riscos abertos

### P0

| # | Achado | Onde | Correção mínima |
|---|---|---|---|
| S1 | ~~**Dado de saúde entregue ao papel `leitura`**~~ — **fechado por desenho** pela decisão 40: o motivo `saude` saiu do enum e do menu do WhatsApp (migration 49) | `migration 49` | — |
| S2 | **Documentos pessoais acessíveis ao papel `leitura`:** `app_documentos` devolve `caminho` **e `url`**. A decisão 41 (Drive descontinuado) tirou o caminho do link direto; resta a exposição do nome e da existência dos arquivos. É o tema **SEG-14** | `api.ts:98`; `migration 37:140-152`; `DocumentosArquivos.tsx` | Ver as três opções abaixo |

#### Situação do S1 e do S2 depois das decisões 39, 40 e 41 (27/09)

**S1 — fechado por desenho.** O motivo de saúde **saiu do sistema** (decisão 40): o enum
`ocorrencia_motivo` não tem mais `saude`, o menu do WhatsApp passou a ter quatro opções (1 Transporte,
2 Conflito de agenda, 3 Falta de material, 4 Outro) e o rótulo "Motivo pessoal" deixou de existir.
Não há mais dado de saúde na recusa de escala, então não há o que proteger ali. As ocorrências antigas
com `saude` viraram `outro` (migration 49, com a contagem registrada no log).

**S2 — continua aberto, com escopo menor.** O que resta é o papel `leitura` enxergando `caminho` e
`url` dos documentos (NR, CNH e **ASO**) em `app_documentos`. A decisão 41 descontinuou o vínculo por
link do Drive, o que removeu o pior caminho — o link que abria direto, sob a permissão do Drive. Para
arquivo no bucket, o `leitura` vê o caminho, mas o link assinado exige admin/gestor: **falha fechado**.
O que ainda expõe é o **nome e a existência** dos arquivos, e portanto a informação de que aquele
técnico tem ASO. Virou o tema **SEG-14** no painel.

#### Como fechar o SEG-14 — três opções

| Opção | O que é | Custo | Quando |
|---|---|---|---|
| **A · imediata** | `app_documentos` deixa de devolver `caminho`/`url` para o papel `leitura`, com a tela escondendo o botão de abrir; ele continua vendo tipo, validade e situação | 1 migration + 1 ajuste de tela | esta semana |
| **B · destino** | criar o papel **`rh`** para o dado de saúde; `leitura` vira leitura operacional (escala, local, indicadores agregados) | dentro do RBAC com escopo | junto com o acesso por área |
| **C · transitória, sem código** | não convidar ninguém para `leitura` enquanto A ou B não entram — são 3 usuários hoje | zero | hoje, como regra |

**Recomendação:** A agora, B como destino, C como regra transitória. O mesmo papel `rh` é o que o
módulo de ponto vai precisar para o atestado — um trabalho serve aos dois.

### P1

| # | Achado | Onde |
|---|---|---|
| S3 | **Token do webhook viaja na query string** e é o único fator da função publicada sem JWT; vaza em log da Evolution, do proxy e do `pg_net`. Quem o obtém altera status de escalas | `webhook-evolution/index.ts:26`; `setup/segredos.md:17` |
| S4 | **`VOZ_TOKEN` na query string entregue à Twilio** (fica no CDR): com ele, `?acao=iniciar` dispara **ligação paga sem login** | `voz-escala/index.ts:127` |
| S5 | **Assinatura da Twilio desligada por padrão** (`TWILIO_ASSINATURA=obrigatoria` não configurada) — callback com token válido é aceito sem conferir assinatura | `voz-escala/index.ts:22,96` |
| S6 | **Sem MFA** nas contas administrativas (o Supabase tem TOTP gratuito) | `seguranca-homologacao.md:22` |
| S7 | **Sem CSP** no painel e **sessão persistida em `localStorage`**: um XSS exfiltra o refresh token de uma conta sem MFA | `web/vercel.json:3-11`; `supabase.ts:14` |
| S8 | **Nenhuma Edge Function limita taxa**; o webhook usa pool `max: 1` | `functions/*/index.ts` |
| S9 | **`app_ligar_escala` sem limite de frequência:** os tetos valem só na via automática — cliques repetidos geram ligações pagas | `migration 23:179-189` |
| S10 | **Corpo sem `content-length` é lido inteiro antes da checagem** (o 413 vem depois do `await req.text()`) | `webhook-evolution:29-36`; `documento-ocr:65-80` |
| S11 | **`monitor_ping_url` em `config`, texto puro** (é credencial de escrita no monitor); validação só exige `https://`, e `voz_url`/`twilio_caller_id` não são validados | `migration 45:25,347` |
| S12 | **26 funções sem `set search_path`** (22 na definição vigente) contra o que afirma a documentação. Hoje não explorável, mas frágil | `docs/seguranca.md:25` |
| S13 | **Hardening incompleto:** o `revoke` da 39 cobre tabelas, **não sequences nem default privileges**; duas migrations criam `app_*` sem o laço de permissões | `migration 39:105-107`; `19`; `32` |
| S14 | **Dados pessoais versionados:** e-mail e nome do admin inicial e **telefone celular real** como default de `alerta_tecnico_telefones` | `migration 14:19`; `migration 45:24` |
| S15 | **Erro interno devolvido ao chamador** em `voz-escala` (`erro: msg`) — o mesmo já foi corrigido no OCR | `voz-escala:187` |

### P2

| # | Achado | Onde |
|---|---|---|
| S16 | Link do Drive não é revalidado e `app_registrar_documento` aceita qualquer `caminho`, sem conferir se o objeto existe ou se é do técnico informado | `migration 37:117-122` |
| S17 | Token do webhook comparado dentro do SQL (`is distinct from`), não em tempo constante | `migration 12:287` |
| S18 | Sem secret scanning no CI (já registrado na análise de infraestrutura) | `.github/workflows` |

---

## 3. Histórico já corrigido — e uma ação de resgate

| O que era | Situação |
|---|---|
| **`fn_segredo` executável por `anon`** e sem checagem de papel até a migration 12 | Corrigido. Mas **não há registro de rotação** dos segredos que existiam antes disso |
| Funções com `EXECUTE` padrão de `PUBLIC` (`fn_criar_escala`, `fn_mudar_status`, `fn_evo_post`, `fn_excluir_tecnico`, `fn_disparar_ligacoes`) | Corrigido nos primeiros laços |
| `vw_ligacoes_pendentes` e `vw_documentos_expirados` nasceram **sem `revoke`** (nome e telefone de técnicos legíveis por `anon`) | Corrigido na 34 e na 39 |
| `TRUNCATE` sobre tabelas novas ignorava RLS até a 39 | Corrigido |
| Segredos da bancada antiga (`WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`) seguem no Vault, sem uso | **A apagar** |

> **Ação de resgate, recomendada:** se `EVOLUTION_API_KEY`, `WEBHOOK_TOKEN` ou `WHATSAPP_*` já existiam
> antes de 21/09, **rotacionar**. Não há registro de que isso tenha sido feito, e a janela em que
> `fn_segredo` era público é conhecida.

---

## 4. LGPD

### 4.1 Inventário de dados pessoais

| Dado | Onde | Prazo hoje | Observação |
|---|---|---|---|
| Nome, função, equipe, telefone | `tecnicos` | **indefinido** | o telefone é a chave de identificação do técnico no WhatsApp |
| Onde e quando cada pessoa trabalha | `escalas`, `escala_eventos` | **indefinido** | histórico de local e jornada |
| Conteúdo das mensagens recebidas | `webhook_eventos` | 30 dias | inclui telefone, nome de perfil e texto |
| Texto livre do técnico (pode conter saúde) | `respostas.texto_livre`, `ocorrencias.detalhe` | **indefinido** | — |
| Motivo da recusa | `ocorrencias.motivo` | **indefinido** | `saude` é dado sensível (art. 11) |
| Documentos: NR, CNH e **ASO (saúde)** | bucket `documentos` + `documentos` | **5 anos após o desligamento** (declarado, sem executor) | a NR-7 pode exigir 20 anos — a confirmar com o RH/jurídico |
| Ligações: telefone, dígito, duração, preço | `ligacoes` | **indefinido** | — |
| Conteúdo enviado nas mensagens | `notificacoes.payload_envio` | 90 dias | o resto da linha fica |

**Só quatro prazos existem**: log de webhook 30 dias, conteúdo enviado 90, alertas 90, histórico do
cron 7. Todo o resto cresce para sempre.

### 4.2 Pendências

| # | Pendência | Gravidade |
|---|---|---|
| L1 | **Sem inventário formal, base legal, aviso de privacidade e canal do titular** (bloco 2 de segurança, itens 5 a 8, todos abertos). A decisão 32 já reconheceu que o aviso é pré-requisito das etapas 20 e 21 | Alta |
| L2 | **Saúde acessível ao papel `leitura`** (S1) e **ASO exposto ao `leitura`** em `app_documentos_por_tecnico` | Alta |
| L3 | **Retenção só para logs** (4.1) | Alta |
| L4 | **O expurgo de 5 anos não tem executor:** `app_documentos_expirados()` existe e **não é chamado por nenhuma tela**; `desligado_em` é campo opcional. O prazo é declaração, não processo | Alta |
| L5 | **Excluir técnico deixa os arquivos no bucket** — o metadado cai em cascata, o objeto não. O direito de eliminação não se cumpre para ASO/NR | Alta |
| L6 | **Exclusão definitiva apaga demais e registra de menos:** remove escalas, mensagens e auditoria (pode conflitar com guarda de registro trabalhista), sem *legal hold*; `log_exclusoes` guarda só contagem e UUID | Média |
| L7 | **Após excluir o técnico, telefone e conteúdo continuam no `webhook_eventos` por até 30 dias** | Média |
| L8 | **Transferências a terceiros sem registro de base legal:** Google Vision (imagem de ASO ao exterior), Twilio, **VPS da Evolution em `evo.vluma.com.br` — domínio de terceiro que não aparece em nenhum documento**, GitHub Actions (cópia cifrada da produção) e Vercel | Média |
| L9 | **O Storage fica fora do backup** — a guarda de 5 anos depende de bucket sem cópia | Média |
| L10 | **Consentimento frágil:** `opt_in` é booleano + data, sem texto, versão ou canal; revogar não registra a revogação; **`fn_remover_escala` envia mensagem sem checar `opt_in`** (a coluna é lida e ignorada); os avisos técnicos vão para telefones que não têm cadastro de consentimento; não existe caminho de "parar" para o técnico | Média |
| L11 | **Sem trilha de leitura/download de documento** (prevista no item 015) | Média |
| L12 | **Modo Drive tira acesso e retenção do sistema** — link "qualquer pessoa" não é expurgado | Média |
| L13 | **Transparência imprecisa na tela:** o texto afirma "o documento não é enviado a nenhum servidor" ao lado do botão que o envia ao Google | Média |
| L14 | **Minimização:** o OCR devolve 400 caracteres do documento e o painel não usa | Baixa |
| L15 | **CPF previsto na decisão 32** aumenta a coleta e exige base legal registrada antes | Baixa |

### 4.3 O que dá para afirmar com honestidade

- **Pode:** "controle de acesso por papel, criptografia em repouso e em trânsito, trilha de auditoria,
  backup diário cifrado com restauração testada, e hospedagem em infraestrutura com ISO/IEC 27001 e
  SOC 2".
- **Não pode:** "somos certificados ISO 27001" (a certificação é da organização, não do software),
  "100% conforme à LGPD", nem "garantimos disponibilidade" sem SLA contratado.
- O que o projeto entrega é o **desenho**; a conformidade da Infoxtec depende de política interna,
  contrato com os titulares e processo de resposta a incidentes.

---

## 5. O que a Segurança veta

1. **Merge com S1, S2, S5 ou S13 abertos** sem correção **ou** aceite explícito do responsável — são
   dado pessoal exposto, proteção desligada e hardening incompleto.
2. **Restaurar sem revogar os *default privileges*** (ver `analise-infraestrutura.md` §4.2): restaurar
   sem esse passo pode devolver `anon` e `authenticated` com privilégio no projeto novo — a mesma
   classe de falha da migration 39.
3. **Seguir o `db push` cru** documentado em dois lugares: contorna a confirmação escrita e deixa o
   link apontado para a produção.
4. **Dado pessoal novo** (CPF, foto, biometria, geolocalização) sem finalidade, base legal e prazo.

**Decisões que só o responsável toma:** aceitar o risco do canal não oficial; definir o que o papel
`leitura` pode ver; e registrar as transferências internacionais de dados.

---

## 6. Fila recomendada

| Ordem | Ação | Por quê |
|---|---|---|
| 1 | **Rotacionar os segredos** que existiam antes da migration 12 e apagar os da bancada antiga | não há registro de rotação; é barato e fecha uma janela conhecida |
| 2 | **Decidir o que `leitura` vê** (S1 e S2) e aplicar | é dado de saúde exposto |
| 3 | **Ligar o bloqueio da assinatura da Twilio** (S5) e tirar os tokens da query string (S3, S4) | prazo de 30 dias já registrado |
| 4 | **MFA + CSP** | fecha o caminho mais provável de comprometimento de conta |
| 5 | **Fechar o hardening** (S13): sequences e *default privileges* | uma migration pequena |
| 6 | **Retenção e expurgo** (L3, L4) e **arquivo órfão na exclusão** (L5) | é o débito legal do módulo de documentos |
| 7 | **Inventário, aviso e canal do titular** (L1) | pré-requisito das etapas 20 e 21 |

---

## 7. O que só se confirma fora do repositório

MFA e cadastro público ligados nos dois projetos · expiração de sessão e política de senha · se a
assinatura da Twilio já foi ligada · papel do banco usado por `SUPABASE_DB_URL` nas Edge Functions ·
ACLs de `net.*` e permissões reais de `anon`/`authenticated` (nada foi medido no banco) · conteúdo do
bucket (arquivos órfãos) · validade da constraint `documentos_origem_coerente` · titularidade de
`evo.vluma.com.br` · se algum segredo herdado já foi rotacionado.

## 8. Fontes

As 48 migrations, `supabase/functions/*/index.ts`, `supabase/setup/*`, `web/src/lib/*`,
`web/vercel.json`, `docs/seguranca.md`, `docs/seguranca-homologacao.md`, `docs/decisoes.md`,
`docs/operacao.md`, `docs/analise-infraestrutura.md` e `docs/analise-codigo.md`.
