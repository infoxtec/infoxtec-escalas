# Banco de dados

**Situação em 11/10/2026 (produção e homologação na migration 76):** 45 tabelas, 7 views, 204 funções
— 76 da API do painel (`app_*`), 12 do app do funcionário (`ponto_*`) e as internas (`fn_*`) —, 34
gatilhos e 5 tarefas agendadas (`supabase/setup/cron.sql`, conferidas pelo Checklist Sistema). Tudo
versionado em `supabase/migrations`. Quando este documento divergir do banco, o banco manda; a
seção de cada migration, abaixo, diz o que mudou e por quê.

## Mapa por domínio

| Domínio | Tabelas | Para quê |
|---|---|---|
| **Escalas** (núcleo) | `escalas`, `notificacoes`, `respostas`, `ocorrencias`, `escala_eventos`, `ligacoes`, `alertas_enviados`, `motor_estado` | Escala do técnico, envio pelo WhatsApp e pela URA, respostas, alertas aos supervisores e o motor (`fn_dispatcher_whatsapp`, a cada minuto) |
| **Cadastros** | `tecnicos`, `locais`, `empresas`, `habilidades`, `tecnico_habilidades`, `tipos_atividade`, `tipo_atividade_requisitos`, `tipo_atividade_documentos`, `feriados` | Equipe, locais, empresas do ponto, aptidão por atividade e o calendário de feriados (URA e alertas) |
| **Documentos do técnico** | `documentos`, `tipos_documento`, `tecnico_documentos` | ASO, NR, CNH com validade; retenção pela view `vw_documentos_expirados` |
| **Ponto: marcações** | `ponto_marcacoes`, `ponto_nsr`, `ponto_ajustes`, `ponto_geo`, `ponto_conversas` | Marcação imutável com NSR e cadeia de hash (Portaria 671); ajuste nunca altera a original |
| **Ponto: acesso do funcionário** | `ponto_codigos`, `ponto_sessoes`, `ponto_acessos`, `ponto_ciencias` | Login por CPF e código no WhatsApp, sessões e ciência do aviso de privacidade |
| **Ponto: justificativas** | `ponto_motivos`, `ponto_justificativas`, `ponto_abonos` | Pedido do funcionário, decisão do gestor, abono (nunca marcação inventada), afastamento e alta |
| **Ponto: cofre de documentos** | `ponto_justificativa_anexos`, `ponto_anexo_acessos`, `ponto_anexos_descartados` | O arquivo cifrado (AES-256), quem abriu e o que foi descartado (decisão 56) |
| **Ponto: registro e QR** | `ponto_documento_registros`, `ponto_documento_sequencia`, `ponto_documento_verificacoes` | Número sequencial por empresa, código do QR e quem conferiu; sobrevive ao descarte do arquivo (decisão 62). Não duplica o cofre: é outra camada sobre o mesmo documento |
| **Plataforma** | `config`, `painel_usuarios`, `painel_ve_saude_log`, `webhook_eventos`, `saude_testes`, `log_exclusoes`, `backlog_itens` | Parâmetros, usuários do painel e quem vê saúde, log do webhook (30 dias), Checklist Sistema, exclusões e o Kanban |

**Regras que valem para tudo:** RLS ligado e sem políticas; acesso só pelas funções; toda `app_*` é
`security definer` e começa por `app_exigir`; toda `ponto_*` começa por `fn_ponto_sessao`; nenhuma
função é executável pelo `service_role`; a retenção roda em `fn_limpeza_logs` (diária).

## Modelo do núcleo de escalas

```mermaid
erDiagram
    tecnicos ||--o{ escalas : "executa"
    locais   ||--o{ escalas : "sedia"
    escalas  ||--o{ notificacoes : "mensagens enviadas"
    escalas  ||--o{ respostas : "respostas do técnico"
    escalas  ||--o{ ocorrencias : "problemas informados"
    escalas  ||--o{ escala_eventos : "auditoria"
    notificacoes ||--o{ respostas : "correlação por wa_message_id"
```

## Tabelas do núcleo de escalas

| Tabela | Papel | Observações |
|---|---|---|
| `tecnicos` | Equipe de campo | `telefone_e164` único, só dígitos. `opt_in` controla envio; `is_supervisor` recebe alertas |
| `locais` | Obras e clientes | `link_maps` entra na mensagem do WhatsApp |
| `escalas` | Núcleo | Status, jornada calculada, auditoria. Índice único parcial: um técnico não tem duas escalas ativas no mesmo dia e hora — canceladas não contam |
| `notificacoes` | Uma linha por mensagem enviada | `wa_message_id` é a chave de correlação; `http_req_id` liga à resposta do pg_net |
| `respostas` | Cliques e mensagens do técnico | `wa_message_id` único garante idempotência do webhook |
| `ocorrencias` | Problemas informados | Motivo e detalhe enviados depois pelo técnico |
| `escala_eventos` | Trilha de auditoria | Quem mudou o quê e quando |
| `painel_usuarios` | Autorização | E-mail, papel (`admin`/`gestor`/`leitura`), ativo |
| `config` | Parâmetros operacionais | Muda comportamento sem deploy |
| `webhook_eventos` | Log bruto dos eventos da Evolution | A `apikey` é removida antes de gravar |
| `alertas_enviados` | Controle do alerta de prazo | Evita alerta duplicado no mesmo dia |
| `log_exclusoes` | Registro de exclusões definitivas | Não guarda nome nem telefone |
| `ligacoes` | Uma linha por ligação da URA | `call_sid` da Twilio, tecla digitada, duração e custo |
| `habilidades` | Catálogo do que o técnico sabe fazer | Não vence. NRs, CNH e ASO saíram daqui na migration 36 |
| `tipos_documento` | NR, CNH, ASO e outros documentos com validade | `palavras_chave` alimenta a classificação automática no envio em lote |
| `tecnico_documentos` | Validade de cada documento por técnico | Situação calculada em `vw_tecnico_documentos` |
| `tipo_atividade_documentos` | Documentos exigidos por tipo de atividade | Documento vencido reprova na aptidão |
| `tecnico_habilidades` | Quem sabe fazer o quê e em que nível | Sem validade: isso mora em `tecnico_documentos` |
| `tipos_atividade` | Tipos de serviço (CFTV, fibra, link...) | Ligado à escala por `escalas.tipo_atividade_id` |
| `tipo_atividade_requisitos` | Habilidades exigidas por tipo | Define quem é apto |
| `ligacoes` | Uma linha por ligação da URA | `call_sid` da Twilio, tecla digitada, duração e custo |
| `documentos` | Arquivos de NR, CNH e ASO | Sem as colunas `origem` e `url`: a migration 50 (decisão 42) removeu o vínculo por link. Todo documento vive no bucket privado |
| `empresas` | Empregadoras e clientes (CNPJ) | Base do Módulo Registro de Ponto (migration 53) |
| `backlog_itens` | Backlog do produto exibido na aba Roadmap | Grupos backlog, entrega e dívida; coluna do Kanban e posição |

### Status da escala

`rascunho` → `agendada` → `notificada` → `confirmada` | `recusada` → `em_execucao` → `concluida`.
`cancelada` e `reagendada` a qualquer momento. Só `agendada` e `notificada` entram no motor.

### Status do envio

`enfileirada` → `enviada` → `entregue` → `lida`, ou `falha`. O webhook nunca rebaixa o status.

## Views

| View | Para que serve |
|---|---|
| `vw_escalas_painel` | Tabela principal, com semáforo, jornada e `pode_remover` |
| `vw_acoes_pendentes` | O motor: o que fazer agora e com qual diagnóstico. Compara a hora local da escala com a hora local atual (migration 39) |
| `vw_linha_do_tempo` | Auditoria + eventos do WhatsApp em ordem |
| `vw_ligacoes_pendentes` | Quem deve receber ligação agora: já recebeu WhatsApp N vezes, não respondeu, dentro da janela |
| `vw_documentos_expirados` | Documentos que passaram dos 5 anos após o desligamento do técnico |
| `vw_tecnico_habilidades` | Habilidades por técnico, com o nível |
| `vw_tecnico_documentos` | Documentos por técnico com situação: válido, vence em breve, vencido, sem data |

## Funções por família

**API do painel (`app_*`)** — únicas expostas ao navegador. Identificam o usuário por
`auth.jwt()`, conferem o papel e executam: `app_meu_acesso`, `app_escalas`, `app_resumo`,
`app_linha_do_tempo`, `app_tecnicos`, `app_locais`, `app_pendencias`,
`app_simular_jornada`, `app_criar_escalas`, `app_mudar_status`, `app_remover_escala`,
`app_reenviar_escala`, `app_salvar_tecnico`, `app_excluir_tecnico`, `app_salvar_local`,
`app_usuarios`, `app_salvar_usuario`, `app_habilidades`, `app_salvar_habilidade`,
`app_tecnico_habilidades`, `app_remover_tecnico_habilidade`,
`app_tipos_atividade`, `app_salvar_tipo_atividade`, `app_aptidao`, `app_painel_locais`,
`app_definir_habilidades`, `app_excluir_habilidade`, `app_habilidades_por_tecnico`,
`app_ligacoes`, `app_ligar_escala`, `app_documentos`, `app_registrar_documento`,
`app_excluir_documento`, `app_backlog`, `app_salvar_backlog_item`,
`app_mover_backlog_item`, `app_pode_gerir_documentos` (usada pelas políticas do bucket `documentos`).

> **Permissão por laço:** toda migration termina revogando `execute` de tudo no schema e
> concedendo de novo a **todas** as funções com prefixo `app_`. Lista manual já derrubou o painel
> uma vez (migration 26, corrigida na 27).

**Regra de negócio (`fn_*`)** — `fn_criar_escala`, `fn_criar_escalas_lote`, `fn_mudar_status`,
`fn_remover_escala`, `fn_excluir_tecnico`, `fn_salvar_usuario_painel`, `fn_exigir_papel`,
`fn_papel`, `fn_calcular_jornada`, `fn_pendencias_escala`.

**Mensageria** — `fn_dispatcher_whatsapp` (o motor, fases 1 a 6: confere respostas da Evolution, envia, aciona supervisores, alerta de prazo, documentos vencidos e ligações; desde a migration 41 uma falha numa escala fica registrada nela, com `erro_codigo = 'interno'`, sem travar as outras), `fn_payload_escala`, `fn_corpo_escala`,
`fn_titulo_escala`, `fn_msg_escala`, `fn_msg_supervisor`, `fn_evo_post`, `fn_evo_get`,
`fn_wa_texto`, `fn_avisar_supervisores`, `fn_alerta_prazo_escala`.

**Voz (URA)** — `fn_preparar_ligacao`, `fn_registrar_call_sid`, `fn_voz_twiml`, `fn_voz_resposta`,
`fn_voz_status`, `fn_disparar_ligacoes`, `fn_xml_escape`.

**Regras de escala** — `fn_validar_inicio` (nunca no passado), `fn_marcar_escala_teste`,
`fn_calcular_jornada`, `fn_aplicar_jornada`, `fn_aptidao`, `fn_nivel_valor`.

**Webhook** — `fn_webhook_evolution` (porta de entrada, confere o token), `fn_wh_status`
(entrega e leitura), `fn_wh_mensagem` (botões, 1/2, texto livre), `fn_tel_canonico`.

**Vigia do motor** — `fn_vigiar_motor` (agendada a cada 5 minutos em `setup/cron.sql`) lê
`motor_estado.ultima_execucao_ok`, gravada pelo motor ao fim de cada execução concluída, e avisa os
supervisores quando passam `motor_alerta_min` minutos sem execução (uma vez por ocorrência, dentro
da janela de envio) e quando normaliza. `app_estado_motor` alimenta o quadro da aba Operação
(migration 44).

**Infra** — `fn_config`, `fn_config_int`, `fn_segredo` (lê do Vault), `fn_fmt_duracao`,
`fn_http_resposta`, `fn_limpeza_logs` (retenção de logs, agendada em `setup/cron.sql`).

> **Hora da escala:** `data_servico` e `hora_inicio` são hora local, sem fuso. Nunca comparar
> `data_servico + hora_inicio` com `now()`, que é UTC no servidor. Comparar com
> `now() at time zone fn_config('fuso')`.

> **Pendência de limpeza:** `fn_teste_wa_texto`, `fn_teste_wa_botoes` e `fn_teste_wa_resposta`
> são da bancada de teste da migration 07 e podem ser removidas.

> **Backlog do Roadmap:** `backlog_itens.numero` é obrigatório, único e atribuído pelo gatilho
> `trg_backlog_numero` (`fn_numerar_backlog`), em sequência única para todos os grupos, desde a
> migration 43. Depois de atribuído, não muda. O painel exibe com três dígitos (001).

### Migrations 45 e 46 (27/09)

| Peça | O que faz |
|---|---|
| `fn_concluir_escalas()` | Fase 7 do motor: confirmada/em execução vira concluída 5 min depois do término previsto |
| `escalas_horario_ativo_unico` | Índice único parcial agora ignora `cancelada` e `recusada` (decisão 31) |
| `fn_pendencias_escala` | Técnico só com escala recusada conta como "sem escala" |
| `fn_dispatcher_whatsapp` | Trava `pg_try_advisory_xact_lock` (uma execução por vez), `lock_timeout` de 20 s, fase 7 e sinal ao monitor externo |
| `fn_evolution_falhando()` | Verdadeiro com 2+ falhas e nenhum envio com sucesso nos últimos 15 min; o sinal vai como `/fail` |
| `fn_avisar_tecnico(texto)` | WhatsApp para `alerta_tecnico_telefones` (sem repetir quem já é supervisor) |
| `fn_vigiar_motor` | Também avisa os telefones técnicos e, uma vez por dia na janela, o banco acima de `banco_alerta_mb` |
| `fn_limpeza_logs` | Também apaga `payload_envio` com mais de 90 dias |
| `fn_validar_config` / `trg_config_validar` | Validação dos parâmetros |
| Índices | `respostas(notificacao_id)`, `ocorrencias(escala_id)`, `ligacoes(tecnico_id)`, `escalas(local_id)`, `tecnico_documentos(documento_id)`; removido o duplicado `idx_notif_wa` |
| Removidas | `fn_teste_wa_botoes`, `fn_teste_wa_resposta`, `fn_teste_wa_texto` (bancada de teste) |

### Migration 47 (27/09): backlog 064 e 065

| Peça | O que faz |
|---|---|
| `fn_wh_mensagem` | Depois do "2", pede o motivo (1 Saúde, 2 Transporte, 3 Conflito de agenda, 4 Falta de material, 5 Outro) e grava em `ocorrencias.motivo`. Só pergunta se o técnico não tem outra escala aguardando resposta. Texto livre vira detalhe e, sem motivo, "outro" |
| `fn_motivo_rotulo(texto)` | Nome do motivo para mensagens e painel |
| `app_indicadores_resposta(dias)` | Recusas por motivo e mediana do tempo entre o primeiro envio e a resposta (aba Operação) |
| `app_escala_edicao(id)` / `app_editar_escala(p)` | Editar data, hora, local e tarefa. Mudou data, hora ou local de escala enviada: volta a aguardar resposta e reenvia. Só tarefa: avisa o técnico |
| `fn_edicao_permitida` (migration 48) | Intervalo mínimo de 2 minutos entre edições da mesma escala; escala de teste não avisa o técnico. Desde a migration 49 o motivo de saúde não existe (decisão 40) |
| `app_substituir_tecnico(escala, tecnico)` | Escala recusada gera outra igual para o técnico escolhido; eventos `substituida`/`substitui` ligam as duas |

### Migration 20260928235626 (28/09): trava de envio por ambiente (decisão 44)

`config.ambiente` (`producao` | `homologacao`) e `config.telefones_homologacao`. `fn_pode_enviar(telefone)`
libera tudo em produção; em homologação, só técnico com `perfil_teste` ou número liberado.
`fn_evo_post` (toda saída de WhatsApp) e `fn_preparar_ligacao` (URA) consultam a trava; `app_config`
devolve `ambiente`.

### Migration 51 (29/09): Administração do Sistema > Checklist

| Objeto | O que faz |
|---|---|
| `saude_testes` | Registro das consultas ao vivo (`alvo` = `evolution` ou `status_*`, `req_id` do pg_net, erro, quem testou em `criado_por` = e-mail do admin). RLS ligado, sem políticas. Guarda as 100 linhas mais recentes (20 testes). |
| `app_checklist_testar()` | Só admin. Enfileira pelo pg_net o `connectionState` da Evolution e as quatro páginas públicas de status (Supabase, Twilio, GitHub, Vercel). Dentro de 10 s do último teste, não repete (`recente: true`). |
| `app_checklist_saude()` | Só admin. Devolve itens `{grupo, item, estado ok/atencao/falha/info, detalhe}`: banco (tamanho, última migration), motor, cron, pg_net, configuração e conexão da Evolution, webhook, envios, escalas vencidas sem envio, notificações e webhook com erro, credenciais e ligações da Twilio. Só contagens, datas e nomes de segredos (nunca valores); da resposta da Evolution sai só o código HTTP e o `state`. |

Todas as consultas externas saem do banco: o navegador do admin só fala com o Supabase. Das páginas de
status lê-se só `status.indicator` e `status.description`. O painel acrescenta, sem rede, a versão
publicada e o link do GitHub Actions.

### Migration 52 (30/09): índices das chaves estrangeiras

Cinco índices pedidos pelo linter do Supabase (`unindexed_foreign_keys`): `documentos`,
`tecnico_documentos` e `tipo_atividade_documentos` em `tipo_documento_id`; `tecnico_habilidades` e
`tipo_atividade_requisitos` em `habilidade_id`. Só estrutura.

### Migration 53 (06/10): Módulo Registro de Ponto — cadastros-base (backlog 080, decisão 48)

- **`empresas`** (nova, RLS sem políticas): CNPJ único com dígito verificador (`fn_cnpj_valido`),
  razão social, cidade/UF, fuso (`America/Bahia`), `empregadora` (o ponto dos funcionários sai no
  CNPJ dela). Funções `app_empresas` (todos os papéis) e `app_salvar_empresa` (admin, gestor).
- **`tecnicos`**: `cpf` (dígito verificador por `fn_cpf_valido`, único), `matricula` (única por
  empresa), `admissao`, `empresa_id`. **Minimização (revisão do `seguranca`):** a lista de
  `app_tecnicos` nunca traz o CPF inteiro — admin e gestor recebem `***.982.247-**` (padrão gov.br,
  sem os dígitos verificadores), leitura recebe nulo; o CPF inteiro só sai por `app_tecnico_cpf`
  (admin, gestor), chamada ao abrir a ficha. `app_salvar_tecnico` ignora CPF mascarado e só altera um
  campo novo quando ele vem no pedido. Corrige a data de desligamento, que a tela mandava e a função
  ignorava. `app_salvar_local` passa a recusar link do Maps que não comece com `http(s)://`.
- **`locais`**: `latitude`, `longitude` (as duas ou nenhuma), `raio_m` (20 a 5.000, padrão 200) e
  `cliente_empresa_id`. A área é usada no ponto para sinalizar marcação fora do local.
- Índices nas três chaves estrangeiras novas.

### Migration 54 (06/10): Módulo Registro de Ponto — marcações (backlog 081, decisão 48)

- **`ponto_marcacoes`** (RLS sem políticas): **só inclusão** — gatilhos recusam update, delete e
  truncate (`fn_ponto_imutavel`). NSR sequencial por empresa sem lacuna (a linha de `ponto_nsr` fica
  travada na transação), hora do servidor (`momento`), CPF do momento, tipo (entrada, saída e volta
  do almoço, saída, início e fim de hora extra), canal (app, WhatsApp, URA), localização obrigatória
  fora da URA, local de referência (o da escala de hoje; sem escala, o local com área mais perto),
  distância e `dentro_area` (tolerância: precisão do aparelho, até 100 m). Fora da área é sinalizado,
  nunca bloqueado. **Hash encadeado** (`fn_ponto_hash`, SHA-256 de todos os campos + hash anterior).
- **Porta única garantida pelo banco** (revisão do `seguranca`): gatilho `before insert` recusa
  marcação que não continue a cadeia (NSR seguinte, hash anterior, hash conferido, hora de agora);
  `ponto_nsr` só avança de um em um; `anon`, `authenticated` e **`service_role`** sem nenhum acesso
  direto às três tabelas. `origem` guarda só `msg_id`, `call_sid` e `app_versao` (até 2 KB) — nunca
  o conteúdo da mensagem, porque a tabela não admite descarte antes do prazo.
- **`ponto_ajustes`**: incluir ou desconsiderar, com motivo (mínimo 10 caracteres) e autor; também só
  inclusão. A marcação original nunca muda.
- **`fn_ponto_registrar`** (interna, sem acesso pelo painel): a porta única dos canais; devolve o
  comprovante (NSR, empresa, CNPJ, nome, CPF, data, hora no fuso da empresa, tipo, local, código de
  autenticação).
- **`app_ponto_marcacoes`** (todos os papéis; leitura sem coordenadas, até 62 dias) e
  **`app_ponto_verificar`** (admin: recalcula a cadeia e aponta lacuna ou hash adulterado).
- Gatilho em `tecnicos`: técnico com marcação **não pode ser excluído** (guarda de 5 anos).
- Nenhuma rotina de limpeza toca nestas tabelas. Descarte depois de 5 anos só por migration própria,
  que desliga o gatilho de forma registrada.

### Migration 55 (07/10): Módulo Registro de Ponto — login do funcionário (backlog 082, decisão 49)

- **`ponto_codigos`** (código de 6 dígitos só como hash; origem WhatsApp ou gestor; tentativas),
  **`ponto_sessoes`** (hash do token, 12 h, sessão única, `login_origem`), **`ponto_ciencias`**
  (ciência do aviso de privacidade por versão) e **`ponto_acessos`** (pedidos e tentativas, com IP — `cf-connecting-ip` ou o último
  endereço do `x-forwarded-for`, nunca o primeiro, que quem chama controla: base dos limites). RLS sem políticas; nenhum papel com acesso direto. Guarda (LGPD, em
  `fn_limpeza_logs`): códigos 24 h, sessões 90 dias, acessos 30 dias.
- Limites contra força bruta e disparo em massa: ver decisão 49. Com teto total estourado, só o
  código do gestor entra, e os supervisores recebem aviso pelo WhatsApp (uma vez por hora,
  `fn_ponto_alerta_teto`). O gestor que gerou o código fica na sessão e na marcação (`origem.gestor`, e-mail do gestor:
  dado pessoal guardado 5 anos dentro do hash, com base legal na apuração de fraude no ponto). Erro de
  login gasta só as tentativas do código de WhatsApp; o código do gestor passa por cima do bloqueio
  por funcionário e continua sob os limites por IP e total. Parâmetros novos em `config`:
  `ponto_max_codigos_hora` (60) e `ponto_max_erros_hora` (300).
- API do funcionário (`anon`): `ponto_pedir_codigo`, `ponto_entrar`, `ponto_sair`, `ponto_eu`,
  `ponto_registrar_ciencia`, `ponto_bater` (chama `fn_ponto_registrar` com o funcionário da sessão) e
  `ponto_minhas_marcacoes`. Contingência no painel: `app_ponto_gerar_codigo` (admin, gestor; 15 min).

### Migration 138 (30/10, versão 20261110120000): entrada pela instância e telefone por conta, multiempresa F5b

`tecnicos`: o telefone passa a ser único dentro da conta (`tecnicos_conta_telefone_uk`; sai `tecnicos_telefone_e164_key`):
a mesma pessoa pode estar em dois clientes. Contexto do canal: a configuração da transação `trilha.conta`
(`fn_conta_contexto`), que o webhook, o motor (por escala, fases 2 e 3) e o pedido de código do ponto (por cadastro)
preenchem antes de procurar ou enviar. `fn_conta_do_numero` usa o contexto ou a conta da sessão do painel; sem eles,
o telefone (em duas contas: null, envio recusado). `fn_webhook_conta(token, instância)`: instância da instalação com o
token da instalação dá a operadora; instância de um canal ativo com o token próprio dela (`conta_canais.webhook_segredo`,
`WEBHOOK_TOKEN_<conta>` no Vault) dá a conta; o resto é "token invalido". `fn_webhook_evolution` grava o evento na conta
e as procuras do funcionário (`fn_wh_mensagem`, `fn_ponto_wh`, `fn_ponto_he_resposta`) ficam na conta do contexto.
`app_plataforma_salvar_canal` cria o token do webhook da instância e aponta o webhook dela para o sistema; o pedido
fica em `conta_canais.webhook_req` e o vigia (`fn_vigiar_evolution`) apaga a resposta, que repete o token, assim que
ela chega. `fn_wh_status` só muda o status de entrega das notificações da conta do contexto.
`fn_evo_canal_tecnico` dá à Edge Function `webhook-evolution` o canal da conta do funcionário para baixar mídia.
Regressão: T78 (T77 ajustado: a sessão do painel decide a conta).

### Migration 137 (30/10, versão 20261109120000): canal de WhatsApp por conta, multiempresa F5a

`conta_canais` (uma linha por conta cliente: instância, URL da Evolution, nome do segredo no Vault
`EVOLUTION_API_KEY_<conta>`, ativo; RLS ligado, sem políticas). A operadora (conta 1) fica fora da tabela e segue no
canal da instalação (`evolution_url`, `evolution_instancia`, `EVOLUTION_API_KEY`). `fn_conta_do_numero` acha a conta
de quem recebe pelo telefone do funcionário (único no sistema até a F5b; sem funcionário, a operadora).
`fn_evo_destino(caminho, número)` devolve URL, caminho com a instância da conta e o segredo, ou null se a conta não tem
canal ativo; `fn_evo_post` passa a usá-la e, sem canal, recusa com aviso no log (nunca sai pelo número da operadora,
decisão 108). `fn_segredo_gravar` aceita `EVOLUTION_API_KEY_<32 hex>`. `app_plataforma_canais` (sem a chave) e
`app_plataforma_salvar_canal(conta, instância, chave, ativo)` (chave em branco mantém a do Vault; a instância da
operadora e a `trilha-homologacao` na produção são recusadas; troca no `plataforma_log`, ação `canal_whatsapp`).
O motor (`fn_dispatcher_whatsapp`) confere o destino antes de enviar: escala de conta sem canal vira `falha`
("conta sem canal"), com o ciclo normal de nova tentativa e supervisor. Número que, na forma canônica, bate em duas
contas não é adivinhado (recusado); índice `tecnicos_tel_canonico_idx`. Na homologação, envio de conta cliente vira só
aviso. Telefone e conta explícitos no envio e entrada pela instância (webhook por conta): F5b; fila justa: F5c.
Regressão: T77.

### Migration 136 (30/10, versão 20261108120000): monitor externo pelo painel

`app_plataforma_monitor` (ligado ou não, e os 4 últimos caracteres do endereço) e `app_plataforma_salvar_monitor(url)`
gravam `monitor_ping_url` pelo Checklist Sistema (quadro "Alertas da plataforma", painel 3.58.0), sem SQL na produção (só `https://hc-ping.com/<uuid>` ou vazio; o gatilho da
`config` confere de novo). A troca vai para o `plataforma_log` (ação `monitor_externo`, sem o endereço inteiro).
Regressão: T76.

### Migration 135 (30/10, versão 20261107120000): alerta por e-mail quando o WhatsApp cai

`evolution_vigia` (uma linha: pedido em andamento, último estado, falhas seguidas, desde quando está fora, se já
avisou) e `alertas_email` (fila dos e-mails, 90 dias), tabelas da plataforma (RLS ligado, sem políticas).
`fn_vigiar_evolution`, chamada pelo `fn_vigiar_motor` a cada 5 min (falha nela não para o vigia do motor), lê a resposta
do `connectionState` pedido na volta anterior e faz o pedido novo; fora de `open` por `evolution_alerta_falhas` voltas
(2 = 10 min), põe um e-mail na fila; quando volta a `open`, outro. `fn_alerta_email` grava na fila e chama a Edge
Function `alerta-email` (token `ALERTA_EMAIL_TOKEN` no Vault, criado no primeiro uso); `fn_alerta_email_dados` e
`fn_alerta_email_resultado` só respondem com o token. Destinatários: a plataforma e `alerta_emails`. SMTP em `config`
(`alerta_smtp_host`, `alerta_smtp_porta` 465, `alerta_smtp_usuario`); a senha só no segredo `ALERTA_SMTP_SENHA` da
função. `app_plataforma_testar_alerta` e `app_plataforma_alertas` (Checklist Sistema, quadro "Alertas da plataforma", só a plataforma). Regressão: T75; T56 classifica as duas
tabelas como da plataforma.

### Migration 134 (30/10, versão 20261106120000): exclusão definitiva de usuário

Tabela `usuarios_excluidos` (conta, e-mail, papel, autor, quando e a `situacao` do login: `mantido`, `pendente` com o
`login_id` para repetir se a função cair, `apagado` ou `falhou`; RLS ligado, sem políticas):
o registro que fica de quem saiu. `fn_usuario_excluir(autor, aal, conta, e-mail)`, chamada só pela Edge Function
`excluir-usuario` com o autor conferido no Auth: mesmas regras de quem pode do convite (admin ativo da conta ou
plataforma com duas etapas), ninguém exclui a si mesmo, o último admin ativo não sai; apaga o vínculo em `conta_membros` (o
histórico de convites fica: a chave estrangeira de `convites` para `conta_membros` sai e a conferência de membro segue
na `fn_convite_autorizar`) e devolve o id do login no Auth só se a pessoa não for de outra conta nem da plataforma (a função apaga
o login, com os fatores de duas etapas). `fn_usuario_login_livre` é conferida de novo logo antes de apagar o login (um convite de outra conta pode ter chegado no meio); `fn_usuario_excluir_resultado` grava se o login saiu. O registro da exclusão vale 5 anos (LGPD, legítimo interesse: prova de quem tirou o acesso), apagado na exclusão seguinte. `app_usuarios_excluidos`
lista as 50 últimas exclusões da conta (só admin). O admin de um cliente recebe a mesma resposta com ou sem outra conta.
Regressão: T74.

### Migration 133 (30/10, versão 20261105120000): CNPJ alfanumérico e CEP, pacote de cadastro

`fn_cnpj_valido` aceita o CNPJ com letras (12 posições `[0-9A-Z]` e 2 dígitos; caractere = ASCII − 48, o mesmo cálculo
para os só com números). `app_salvar_empresa` guarda o CNPJ só com letras e dígitos, em maiúsculas. `empresas` e `locais`
ganham `cep` (8 dígitos); `app_salvar_empresa` e `app_salvar_local` aceitam `cep` (sem a chave no pedido, fica o que
estava). `fn_afd_cnpj` leva o CNPJ com letras ao AFD (`app_ponto_afd`; `fn_afd_n` segue tirando as letras do número do
INPI). A consulta de CNPJ e CEP é a Edge Function `consulta-cadastro` (decisão 121), que não grava nada. LGPD: a razão social
de um MEI traz o nome (às vezes o CPF) do titular; é dado público da Receita, gravado só se o gestor salvar, com a
mesma finalidade e visibilidade do cadastro de empresas; sócios e contatos não chegam ao painel. Regressão: T73.

### Migration 132 (29/10, versão 20261104120000): lugar no painel, multiempresa F4b

`app_salvar_local` aceita `uf` (duas letras); local novo sem cidade fica com a cidade da sede (antes, "Salvador" fixo) e,
sem UF, herda a UF da sede só se a cidade for a da sede (outra cidade sem UF cai no funcionário); na alteração, a UF só
muda se vier no pedido. Os locais sem UF cuja cidade é a da sede recebem a UF dela.
`app_plataforma_contas` devolve `uf` e `municipio`; `app_plataforma_criar_conta` e `app_plataforma_salvar_conta` ganham
`p_uf` e `p_municipio` (nulo mantém a sede, para o painel antigo; vazio limpa; município exige UF; a troca vai para o log). Novas, só para a plataforma
(`fn_exigir_plataforma`): `app_plataforma_feriados(ano)`, `app_plataforma_salvar_feriado(p)` (estadual, municipal ou
facultativo; o nacional não se altera) e `app_plataforma_remover_feriado(id)` (o nacional não se remove). Painel 3.52.0:
sede na aba Contas, UF no cadastro do local e a aba Feriados da plataforma. Regressão: T72.

### Migration 131 (29/10, versão 20261103180000): feriado por estado e município, multiempresa F4a

`feriados` ganha `id`, `uf` e `municipio`: o nacional vale para todos; o estadual, só na UF; o municipal, só no município
(comparação sem acento e caixa, `fn_norm_lugar`); local sem UF usa o lugar do funcionário; o ponto facultativo pode ser nacional ou local. Os estaduais da carga
atual ficam na BA e os municipais em Salvador. `contas` ganha a sede (`uf`, `municipio`; conta 1 = Salvador/BA) e
`locais` ganha `uf`. `fn_feriado(data, uf, município, facultativo)` e os atalhos `fn_feriado_da_conta`,
`fn_feriado_da_empresa`, `fn_feriado_do_tecnico` e `fn_feriado_da_escala` escolhem o lugar: na programação e na ligação,
o local com cidade (UF do local ou da sede); senão, a empresa do funcionário; senão, a sede da conta. Passam a usá-los:
pendências e cobrança de escala (sede da conta), indicadores, espelho e pendências da folha, folga compensatória,
pedidos parados (empresa) e a ligação da URA (`fn_ligacao_permitida(momento, programação)`; sem programação, só os
nacionais). `fn_dias_uteis`, sem lugar, conta só os nacionais. Regressão: T71; T10 ajustado.

### Migration 130 (29/10, versão 20261103120000): falas da URA mais curtas

`fn_voz_twiml` e `fn_voz_resposta`: só o texto falado muda (aprovado pelo responsável em 29/10). Abertura: "Oi, Ana! Aqui é
da Infoxtec. Sua programação é amanhã, quinta, às 8 horas, em Obra Torre A. Para confirmar, digite 1. Se não puder ir,
digite 2." (cerca de 10 s, antes 22 s). Respostas sem o "bom trabalho amanhã" fixo. Regras, WhatsApp e avisos ao
supervisor iguais. Regressão: T70. O T59 passa a usar uma quarta-feira (falhava quando "hoje + 3" caía no domingo).

### Migration 129 (27/10, versão 20261102180000): CPF e CNPJ únicos por conta, multiempresa F6

`tecnicos`: o CPF passa a ser único por conta (`tecnicos_conta_cpf_uk`), com índice simples em `cpf` para o login.
`empresas`: o CNPJ passa a ser único por conta (`empresas_conta_cnpj_key`). A mesma pessoa pode ser funcionária de dois
clientes, e o aviso de duplicidade não revela dado de outra conta. O telefone continua único no sistema até a F5 (o
webhook acha o funcionário por ele); a mensagem não diz em qual conta. Login do app do ponto: `ponto_pedir_codigo` manda
um código para cada cadastro ativo com o CPF e WhatsApp autorizado, com o nome da empresa na mensagem; `ponto_entrar`
deixa o código digitado escolher o cadastro, conta o erro em cada cadastro do CPF e mantém os mesmos freios. Aceito até a
F5: o telefone repetido revela que o número existe no sistema (sem a conta), e um palpite errado gasta as tentativas dos
códigos de WhatsApp de todos os cadastros do mesmo CPF (o código do gestor segue livre). Regressão: T69.

### Migration 128 (27/10, versão 20261102120000): desempenho do espelho do ponto

As CTEs que chamam `fn_ponto_jornada_dia` em `app_ponto_espelho`, `fn_ponto_espelho_conteudo` e `app_carga_excedida`
passam a `materialized`: o PostgreSQL desdobrava a CTE e recalculava a jornada a cada coluna lida (até 21 vezes por
dia). `fn_ponto_marcacoes_efetivas` perde o `set search_path` (tabelas com o esquema escrito) para ser incorporada na
consulta; é a única exceção do T55, que exige ser `sql` e sem `security definer`. Medido com 50 funcionários × 1 mês:
espelho 14,3 s → 0,22 s; conteúdo do espelho 738 → 32 ms por funcionário; prévia da folha 642 → 63 ms; carga excedida
5,0 → 0,26 s; indicadores 1,3 → 0,34 s. Regressão: T68 (estrutura) e a regressão inteira (mesmos resultados).

### Migration 127 (27/10, versão 20261101180000): convite por e-mail

`convites` (por conta): quem convidou, quem, quando e o resultado (`pendente`, `enviado`, `ja_tinha_login`, `falhou`).
`fn_convite_autorizar(autor, aal, conta, e-mail)`: o convidado precisa ser membro ativo da conta ativa; convida a
plataforma (duas etapas) ou o administrador da conta (duas etapas se `mfa_obrigatorio`); no máximo 20 convites por hora
por autor e um por e-mail a cada 10 minutos, com trava por autor e por e-mail contra pedidos simultâneos. Chave
`(conta_id, email)` para `conta_membros`. Retenção de 90 dias (LGPD): cada convite novo apaga os mais antigos. `fn_convite_resultado` fecha o registro uma vez. `app_convites` lista o
último convite de cada e-mail da conta. Quem chama é a Edge Function `convidar-usuario`, que usa a chave de serviço
só para o convite do Supabase Auth. Regressão: T67.

### Migration 126 (27/10, versão 20261101120000): fim da conta padrão e da trava, multiempresa F3d

O default de `conta_id` deixa de ser a conta 1 e passa a ser `fn_conta_padrao()`, a conta da sessão sem lançar erro
(decisão 119). `fn_herdar_conta` recusa, com sessão, origem de outra conta. Sem
sessão (cron, webhook, app do ponto), o default é nulo e o banco recusa a linha, a não ser que a conta venha da origem
(gatilhos de herança da 119) ou do caminho:
- `webhook_eventos`: gatilho `fn_conta_operadora` (canal da operadora até a F5);
- `ponto_acessos` sem funcionário (CPF desconhecido): operadora; com funcionário, a conta dele;
- `alertas_enviados`: o teto do app do ponto vai para a operadora; alerta sem funcionário nem empresa é recusado;
- `painel_mfa_log`: um registro por conta de que o usuário é membro.

`feriados` e `ponto_motivos` perdem `conta_id` e viram catálogo da plataforma (feriado por local: F4). A trava
`tg_trava_conta_unica` sai: conta de cliente aceita membro. Regressão: T66; T56 exige o default da sessão em toda
tabela de cliente e a ausência da trava.

### Migration 125 (27/10, versão 20261031180000): contas da plataforma, multiempresa F3c

`fn_exigir_plataforma()`: sessão, e-mail em `plataforma_admins` e verificação em duas etapas (`aal2`) sempre, mesmo
sem `mfa_obrigatorio`. `app_plataforma_contas` lista as contas com administradores, usuários ativos e módulos;
`app_plataforma_criar_conta(nome, e-mail do admin, nome do admin, módulos)` cria a conta, os módulos e o primeiro
administrador (o login dele é o convite do Supabase Auth); `app_plataforma_salvar_conta` muda nome, módulos e ativa (a
conta da operadora não desliga). Nome de conta único sem diferenciar maiúsculas. Tudo fica em `plataforma_log` (tabela
da plataforma, coluna `conta_alvo`; guarda o e-mail do administrador criado: finalidade auditoria das contas, base
legítimo interesse e segurança, art. 7º, IX e art. 46 da LGPD; retenção a definir com a exclusão de conta na F8, que
hoje é barrada pela chave do log). Índice único `contas_nome_uq` em `lower(btrim(nome))`. A guarda é
`interno.fn_exigir_plataforma()`, fora da API. `app_meu_acesso` ganha `plataforma`. Enquanto a trava da 117 existir, criar conta
é recusado no administrador. Regressão: T65.

### Migration 124 (26/10, versão 20261031120000): usuário do painel por conta, multiempresa F3a

Papel, ativo, nome e as permissões do RH (`ve_saude`, `rh_folhas`) passam a ser da conta, em `conta_membros`, com
`criado_por` e `atualizado_em`; uma restrição só deixa admin ou gestor com permissão do RH. `painel_usuarios` e o gatilho
que a espelhava na conta 1 (116) saem. `fn_papel`, `fn_ve_saude` e `fn_rh_folhas` leem a conta da sessão.
`app_usuarios`, `app_salvar_usuario` (sem a restrição à conta 1; último admin conferido por conta; e-mail validado),
`app_definir_ve_saude` e `app_definir_rh_folhas` gravam e listam só a conta da sessão. Mudar alguém para leitura tira as
permissões do RH. `app_meu_acesso` devolve `conta` e o papel e as permissões daquela conta; quem está em duas contas e
não escolheu recebe a lista de contas sem papel. Os termos de aceite (programação e carga) tiram nome e papel de quem
assina da conta da sessão. A trava da 117 continua até a F3d. Regressão: T64.

### Migration 123 (25/10, versão 20261030180000): chave composta por conta, multiempresa F2f-2a

Chave única `(conta_id, id)` nas 16 tabelas de origem. As 70 chaves estrangeiras entre tabelas de conta passam a ser
compostas, `(conta_id, coluna) → (conta_id, id)`, com a mesma regra de exclusão (`set null` só da coluna). São criadas
sem conferir e conferidas em seguida. Fica de fora `ponto_justificativas.motivo`, porque `ponto_motivos` é catálogo da
plataforma. `app_ponto_acompanhamento` ganha a faixa em `momento`, que usa o índice. Regressão: T63, em que o banco
recusa uma escala da conta B com local da conta A, mais a varredura do catálogo.

### Migration 122 (30/10): motor por conta, multiempresa F2f-1

`fn_avisar_supervisores(texto, exceto, empresa, conta)`: da empresa informada ou da do funcionário; sem empresa, só
supervisores da mesma conta (do funcionário, da empresa ou a informada); sem nada, todos (alerta de sistema, decisão
107). `fn_alerta_prazo_escala` e `fn_alerta_certificacoes` calculam, registram e avisam por conta ativa (pendências com
`fn_pendencias_escala(data, conta)`; agrupam por empresa quando a conta tem mais de uma). `alertas_enviados`: chave
`(conta_id, tipo, data_ref)`; gatilho `fn_alerta_conta` põe a conta do funcionário ou da empresa citada no tipo ou no
detalhe (aviso quando o identificador não é funcionário nem empresa); chave com índice também em `(tipo, data_ref)`.
O motor de envio (`fn_dispatcher_whatsapp`, fase 3) só avisa supervisores da conta da escala. Os avisos do dia rodam
conta a conta, com erro de uma sem derrubar as outras. `fn_ponto_alerta_teto` avisa só supervisores da conta 1
(operadora). `fn_conta_de(email, conta pedida)`: a regra de `fn_conta_atual` numa função pura, que `fn_conta_atual`
passa a chamar. `fn_papel_na_conta_de(email, x-conta)`: papel na conta para Edge Functions, sem mexer na sessão; a
`documento-ocr` usa, aceita o cabeçalho `x-conta` e responde 403 quando a conta é recusada. Regressão: T62.

### Migration 121 (29/10): ponto por conta, multiempresa F2e

As 34 funções do ponto no painel (`app_ponto_*`) leem e alteram só na conta da sessão e conferem na conta o funcionário,
a empresa, o pedido, o abono, o espelho, o anexo e a hora extra recebidos; AFD e verificação da cadeia de NSR só de
empresa da conta. Herança de conta (`tg_00_conta`) nas 22 tabelas do ponto: da empresa (marcações, NSR, ajustes, abonos,
pedidos, espelhos e PDFs, fechamentos, hora extra, registros e sequências de documentos, AFD), do funcionário (sessões,
códigos, acessos, ciências, conversas), do pedido (anexos, acessos e descartes de anexo) e do espelho (acessos);
`ponto_documento_verificacoes` grava a conta da sessão. As seis funções que mascaram pelo papel usam
`fn_papel_na_conta` (sem papel, máscara fechada). `fn_ponto_registrar` só toma como referência local da conta da empresa
(o local entra no hash); `ponto_meus_comprovantes`, `ponto_minhas_marcacoes` e o acompanhamento só mostram local da mesma
conta. Regressão: T57 sem nenhum vazamento, com argumentos válidos para o ponto; T61 (inclui a marcação da conta B).

### Migration 120 (28/10): documentos por conta, multiempresa F2d

Documentos dos técnicos, validade por tipo, quadro por técnico e dossiê por local leem e alteram só na conta; técnico,
tipo, documento e local conferidos na conta; o caminho registrado precisa começar pela pasta do técnico. Herança de
conta também em `documentos`, `tecnico_documentos` (do técnico) e `dossie_geracoes` (do local). Storage do bucket
`documentos`: as políticas usam `app_pode_gerir_documento(name)` (papel admin ou gestor na conta, MFA quando
obrigatório e primeira pasta = técnico da conta); `app_pode_gerir_documentos()` passa a usar o papel na conta.
Regressão: T57 só aceita vazamento em `app_ponto_*`; T60.

### Migration 119 (28/10): programação por conta, multiempresa F2c

Gatilho `tg_00_conta` (`fn_herdar_conta`, argumentos: tabela de origem e coluna) em `escalas` (do técnico, também na
troca de técnico), `escala_eventos`, `notificacoes`, `ligacoes`, `respostas`, `ocorrencias`, `programacao_aceites` (da
escala), `cargas_horarias`, `carga_atribuicoes` (da empresa) e `carga_aceites` (da carga): a linha nova recebe a conta
da origem. `fn_pendencias_escala(data, conta)` e `fn_painel_locais(data, conta)`: com a conta, só ela; sem, todas (motor,
até a F2f). As 27 funções de cargas, programação, envio, ligação, linha do tempo, pendências, painel e indicadores leem
e alteram só na conta da sessão, conferem técnico, local, tipo, empresa, carga e escala na conta e mascaram pelo papel na
conta. Regressão: T57 exige que só documentos e ponto ainda vazem; T59 prova a programação da conta B.

### Migration 118 (27/10): cadastros por conta, multiempresa F2b

Técnicos, empresas, locais, times, habilidades, tipos de atividade e de documento, usuários do painel, MFA e permissões do
RH leem e gravam só na conta da sessão: leitura filtrada por `conta_id`, registro novo com `conta_id` explícito, alteração
só de registro da conta, todo id recebido conferido na conta ("não encontrado" para id de outra). `fn_papel_na_conta()`
decide a máscara do CPF e a exigência do intervalo. `fn_aptidao` só olha técnicos da conta do tipo; `fn_excluir_tecnico`
conta o único supervisor na conta. Nome de habilidade, tipo de atividade e tipo de documento passa a ser único **por
conta** (índices `*_conta_nome_uq`). `app_salvar_usuario` só grava na conta 1 até a F3. Regressão: T57 exige a família
de cadastros sem vazamento; T58 prova a conta B isolada.

### Migration 117 (27/10): conta da sessão, multiempresa F2a (`docs/multiempresa-f2.md`)

`interno.fn_conta_atual()` devolve a conta do usuário do painel: membro ativo de conta ativa em `conta_membros`; quem está
em mais de uma conta escolhe pelo cabeçalho `x-conta` (uuid conferido contra os membros: "Sem acesso a esta conta.");
sem escolha, "Escolha a conta para continuar."; sem sessão, nulo. `app_exigir` passa a exigir a conta e a conferir o
papel **naquela conta** (falta de escopo nega); na conta 1 o resultado é o de antes (espelho da 116). `app_meu_acesso`
devolve também `contas` (id, nome, papel). `fn_papel` continua global até a F2f. **Trava:** `tg_trava_conta_unica` recusa membro fora da conta 1 até a F2f. Regressão T57: asserções da conta da
sessão e relatório de vazamento A × B gerado do catálogo.

### Migration 116 (26/10): contas, multiempresa F1 (decisões 108 e 113)

Tabelas novas em `interno` (RLS ligado, sem política, sem privilégio para a API): `contas` (conta 1 "Infoxtec", id
`00000000-0000-0000-0000-000000000001`), `conta_membros` (conta, e-mail, papel admin/gestor/leitura, ativo; preenchida
com `painel_usuarios` e mantida igual a ela pelo gatilho `tg_espelhar_conta_membro` até a F2), `conta_modulos` (conta, módulo escala/ponto, ativo) e `plataforma_admins` (e-mail). Toda tabela
de cliente ganha `conta_id uuid not null default` conta 1 `references contas`, com índice; ficam sem as da plataforma
(`config`, `backlog_itens`, `motor_estado`, `saude_testes`, `ponto_geo`, `webhook_token_trocas`). Default constante: a
coluna entra sem reescrever a tabela nem disparar gatilho. `fn_ponto_registrar` grava a conta da empresa na marcação
(o hash da cadeia não inclui a conta e não muda). Nenhuma função lê `conta_id` ainda: o filtro por conta é a F2.
Regressão T56 passa a exigir: nenhuma tabela de cliente sem `conta_id` com chave, nenhuma da plataforma com, conta 1,
admins, módulos, espelho de `conta_membros` e as tabelas novas fechadas. A migration usa `lock_timeout` de 5 s.

### Migration 115 (26/10): esquema privado `interno` (backlog 074, decisões 76 e 108)

Tabelas, views, sequências e funções `fn_*` saem do `public` para `interno`; no `public` ficam só `app_*`, `ponto_*` e
os tipos enum das assinaturas. `anon`, `authenticated` e `service_role` não têm USAGE em `interno`, e os objetos novos
nascem fechados (default privileges). Caminho de busca: `interno, public, extensions, pg_temp` em todas as funções e no papel
`postgres` (pg_cron, Edge Functions, scripts de backup e de setup) — `interno` primeiro, para um `create or replace`
sem esquema nunca criar cópia no `public`. Migration nova escreve o esquema de tudo (CLAUDE.md). Scripts da âncora do
ponto acham o esquema sozinhos (antes e depois da 115). Regressão T55: nada além de `app_*`/`ponto_*` no `public`,
nenhum papel da API no `interno` nem com CREATE no `public`, caminho de busca em todas as funções. Os jobs do
pg_cron passam a chamar `interno.fn_*`, e as Edge Functions fixam o caminho na conexão (valem antes e depois da 115).

### Migration 114 (25/10): o mesmo aviso no "Recebi o código do meu gestor" (decisão 111)

`ponto_entrar` avisa "CPF inválido" (sempre) e "CPF não encontrado" (com o freio) quando não acha funcionário ativo
com o CPF. O freio sai de `ponto_pedir_codigo` para `fn_ponto_cpf_aviso_liberado(ip)`, usada pelas duas: 3 avisos por
rede por hora e no máximo `ponto_max_avisos_hora` no total. Regressão T54.

### Migration 113 (25/10): pedido de código avisa CPF não encontrado (decisão 111)

`ponto_pedir_codigo` devolve `ok` e a `mensagem`. CPF inválido: "CPF inválido…" (sempre). CPF sem funcionário ativo:
"CPF não encontrado…"; funcionário sem opt-in: "Seu WhatsApp ainda não foi autorizado…". Esses dois avisos valem só
para as 3 primeiras respostas desse tipo por IP na última hora (IPv6 pelo /64), no máximo 30 por hora no total
(`ponto_max_avisos_hora`, com alerta aos supervisores), (registradas em `ponto_acessos` com o tipo novo
`cpf_aviso`); depois, ou sem IP, volta a resposta única — o freio contra quem testa CPFs. O app do ponto fica na tela do
CPF quando `ok` é falso. Regressão T53.

### Migration 112 (17/10): aviso só ao supervisor da mesma empresa (decisão 107)

- `fn_avisar_supervisores`, `fn_dispatcher_whatsapp` (fase 3), `fn_ponto_avisar`, `fn_ponto_avisar_supervisores` e
  `fn_ponto_he_inicio`: supervisor sem empresa deixa de receber aviso de funcionário de empresa; funcionário sem empresa
  continua avisando todos (alerta operacional não se perde).

### Migration 111 (17/10): o mês fecha sem a assinatura (decisão 106)

- `fn_ponto_espelho_prazo_dias()` (`config.ponto_espelho_prazo_dias`, padrão 10) e `fn_ponto_mes_espelho`: espelho
  emitido há mais do prazo sem assinatura fecha o mês (abono, estorno, desconsiderar e decisão de HE recusados, com a
  data da emissão); a assinatura continua possível. `app_ponto_enviar_espelhos` avisa o prazo no WhatsApp.

### Migration 110 (17/10): comprovante do art. 79 e pedido com o tipo trocado (decisão 105)

- `ponto_meus_comprovantes(token)`: marcações do próprio funcionário nas últimas 48 horas com os campos do art. 79
  (título, NSR, empregador com CNPJ e CEI/CAEPF/CNO, local, nome e CPF, data e hora com segundos, nº do INPI em
  `config.rep_p_inpi`, SHA-256 da marcação); o app monta o PDF.
- `fn_ponto_justificativa_criar`: pedido de saída ou volta do almoço que já existe no dia (marcada, incluída ou pedida)
  é recusado com a dica do tipo certo.

### Migration 109 (17/10): HE programada com Programação que passa da meia-noite

- `fn_ponto_he_inicio`: a Programação do dia cobre a HE quando já começou e o fim é posterior à hora da HE ou passa da
  meia-noite (fim menor que o início). Antes, escala das 16:00 até a 01:00 não cobria a HE das 17:00.

### Migration 108 (17/10): até 8 pedidos do funcionário em 24 horas

- `fn_ponto_justificativa_criar`: o limite de pedidos de ajuste ou justificativa em 24 horas passa de 5 para 8 (pedido
  do responsável); o teto de 10 pedidos em análise ao mesmo tempo continua.

### Migration 107 (17/10): espelho com o art. 84 completo e PDF assinado (decisão 104)

- `empresas.cei_caepf_cno` (12 a 14 dígitos, opcional; `app_salvar_empresa` aceita e guarda só os dígitos).
- `fn_ponto_espelho_conteudo`: `documento` (título do art. 84), empregador com CEI/CAEPF/CNO e endereço, escalas com
  entrada, intervalo, jornada semanal e minutos por dia (horário contratual), `jornada.pre_assinalado` (empresa que não
  exige o registro do intervalo), `duracao_min` por dia (hora noturna reduzida) e o aviso das marcações tratadas. Vale
  para os espelhos emitidos a partir desta versão (os emitidos ficam como estão).
- `ponto_espelho_pdfs`: o PDF do espelho assinado (`bytea` de 1 KB a 5 MB, começando com `%PDF-`), SHA-256, quando foi
  gerado, pedidos e envio ao WhatsApp. RLS ligado sem políticas; gatilho `fn_ponto_espelho_pdf_imutavel`: gravado, não
  muda nem se apaga.
- `fn_ponto_espelho_pdf_pedir(id, enviar)` (chamada por `ponto_assinar_espelho` com `enviar` e quando alguém pede o PDF
  que ainda não existe): no máximo um pedido por minuto por espelho; `fn_ponto_espelho_pdf_varrer` (tarefa `espelho-pdf`
  do agendador, a cada 5 min) refaz até 5 vezes o pedido que não voltou; chama a Edge Function `espelho-pdf` (`config.espelho_pdf_url`, vazio
  desliga) com o token `ESPELHO_PDF_TOKEN` do Vault, criado sozinho no primeiro pedido (`fn_segredo_gravar` aceita o
  nome).
- `fn_ponto_espelho_pdf_dados` e `fn_ponto_espelho_pdf_gravar`: só para a Edge Function (token conferido no banco);
  gravar confere o PDF (até 1 MB), guarda uma vez e, se o pedido veio da assinatura, envia ao funcionário pelo WhatsApp
  como documento (ativo, opt-in, trava da homologação) — só se o último login foi pelo código do WhatsApp; senão, só o
  aviso. A tabela também recusa `truncate`.
- `ponto_meu_espelho_pdf(token, id)` (funcionário, só o dele) e `app_ponto_espelho_pdf(id)` (RH com `rh_folhas`,
  acesso registrado como `pdf` em `ponto_espelho_acessos`); sem PDF ainda, devolvem `pronto = false` e pedem de novo.
- `ponto_verificar_espelho`: mostra também o SHA-256 do PDF entregue.

### Migration 106 (16/10): hora extra com aprovação do gestor (decisão 100, parte 2)

- `ponto_he_autorizacoes`: uma linha por início de HE (`marcacao_id` único), `origem` `programada` ou `pedido`,
  `status` `pendente`/`aprovada`/`reprovada`, quem decidiu, quando e por onde. RLS ligado sem políticas; gatilho
  `fn_ponto_he_guarda`: decisão uma vez só, nada se apaga.
- `fn_ponto_he_inicio` (chamada por `fn_ponto_avisar` no início de HE, app e WhatsApp): Programação do dia cobrindo o
  horário autoriza; senão cria o pedido e manda aos supervisores da empresa os botões `he:ok:<id>` e `he:nao:<id>`
  (ou texto, sem `usar_botoes`).
- `fn_ponto_he_resposta` (chamada por `fn_webhook_evolution` antes do ponto e das escalas): só supervisor ativo da
  mesma empresa decide; `fn_ponto_he_decidir` grava e avisa o funcionário ("HE aprovada" ou "não autorizada").
- `app_ponto_he_autorizacoes(de, ate)` (leitura sem quem decidiu) e `app_ponto_he_decidir(id, aprovar)` (admin e gestor).
- `fn_ponto_folha_pendencias`: `he_pendente` bloqueia; `he_reprovada` para confirmar.

### Migration 105 (16/10): abono até a assinatura do espelho (decisão 100, item 6)

- `fn_ponto_mes_espelho(tecnico, data)`: `assinado`, `emitido` ou `sem_espelho`; trava a versão vigente (`for update`),
  como a assinatura, para abono e assinatura não se cruzarem.
- `app_ponto_abonar`: sem o limite de 62 dias; recusa só mês assinado. `app_ponto_estornar_abono` e `app_ponto_ajustar`
  (desconsiderar): 62 dias, ou mês com espelho emitido e não assinado; mês assinado nunca.
- As três devolvem `espelho_desatualizado` quando o mês tem espelho emitido e não assinado: o painel pede para fechar de
  novo (painel 3.43.0). Competência no fuso do sistema, o mesmo da emissão.

### Migration 104 (16/10): inconsistências do ponto, parte 1 (decisão 100)

- `empresas.exige_registro_intervalo` (padrão desligado; ligado na Infoxtec pela migration). Só o administrador muda
  (`app_salvar_empresa` recusa o gestor; painel antigo que não manda o campo mantém o valor).
- `fn_ponto_folha_pendencias`: com a opção ligada, o dia acima de 4 h sem o par de intervalo vira
  `intervalo_nao_registrado` (**bloqueia**); com abono no dia (o período ou o intervalo, lançado pelo gestor) volta a
  `sem_intervalo` (confirmar). Até 4 h, dois registros bastam. A marcação nunca é travada.
- `app_ponto_ajustar(p_tecnico, p_acao, p_motivo, p_marcacao, p_ajuste)`: sem os parâmetros da inclusão; o gestor só
  desconsidera (decisão 100). Inclusão em `ponto_ajustes` só vem de pedido do funcionário aprovado.
- `fn_ponto_avisar`: na saída para o intervalo, o comprovante (app e WhatsApp) diz "retorno a partir de HH:MM"
  (15 min de 4 a 6 h, 1 h acima de 6 h na jornada do dia). `fn_ponto_aviso_previo`: texto só informativo; o app
  registra a volta direto, sem o diálogo "Registrar mesmo assim".
- `fn_ponto_aviso_intervalo_pendente` (chamada por `fn_ponto_lembrete_almoco`, das 08:00 às 09:00): no dia seguinte,
  convite ao funcionário para pedir o ajuste se fez o intervalo e não marcou; sem abono e sem pedido aberto, uma vez.

### Migration 103 (15/10): token do webhook trocado pelo sistema (decisão 98)

Tabela `webhook_token_trocas` (RLS sem políticas; motivo, pedido ao `pg_net`, janela do anterior, confirmação ou falha;
nunca o valor). `fn_segredo_gravar` (cria ou troca um segredo no Vault), `fn_webhook_token_ok` (aceita o atual ou o
anterior na janela; fecha em falso), `fn_webhook_apontar` (`/webhook/set` com o token no cabeçalho),
`fn_webhook_token_trocar` e `fn_webhook_token_manutencao` (confere, desfaz se falhou, limpa, troca na primeira vez e a cada
`webhook_token_dias`). `fn_webhook_evolution` passa a usar `fn_webhook_token_ok`; `fn_vigiar_motor` chama a manutenção
(falha dela não derruba a vigia). Nenhuma é executável pela API. Regressão: T47.

### Migration 102 (14/10): checagens mínimas do fechamento (decisão 97)

`fn_ponto_folha_pendencias` ganha `nivel` (`bloqueia` ou `confirmar`): bloqueia pedido pendente, marcação incompleta e
marcação duplicada (mesmo tipo em seguida ou duas a menos de 3 min, sem contar as desconsideradas); confirmar falta
injustificada (`sem_registro`, fora dos dias cobertos por pedido em aberto), `intervalo_curto`, `sem_intervalo`,
`he_acima_limite`, `interjornada_curta` e `abono_em_dia_trabalhado`. `fn_ponto_abono_rotulo` (de onde vem o abono, sem
motivo de saúde) e `fn_ponto_folha_conteudo` (o espelho como é emitido: cálculo, logotipo e `abono_motivo` por dia).
`app_ponto_previa_folha(competencia, tecnico)` (admin, gestor): a prévia do espelho e as pendências. A emissão e o
fechamento pedem confirmação de todas as ocorrências `confirmar` (resposta `a_confirmar`, situação `confirmar`).
`app_ponto_fechar_folha` ganha `p_ocorrencias_vistas` (a quantidade que o painel mostrou; diferente da atual, devolve
`confirmar`). O pedido pendente não leva o motivo (código de saúde). `ponto_folha_fechamentos.faltas_confirmadas` passa a
`ocorrencias_confirmadas`. Regressão: T46.

### Migration 101 (14/10): validação e fechamento da folha, logotipo no espelho (decisão 96)

`empresas.logo` (nome de um logotipo publicado com o painel; a Infoxtec já sai com `infoxtec`). Tabela
`ponto_folha_fechamentos` (RLS sem políticas, imutável): funcionário, competência, espelho, faltas confirmadas, quem e
quando fechou. `fn_ponto_folha_pendencias(tecnico, mes)`: pedido pendente e marcação incompleta (`bloqueia = true`) e
dia devido sem registro (`sem_registro`, precisa de confirmação). `app_ponto_validar_folha(competencia)` (admin, gestor,
leitura): todos os funcionários do mês com pendências, espelho vigente e último fechamento.
`app_ponto_fechar_folha(competencia, tecnico, confirmar_faltas)` (admin, gestor): sem bloqueio e com as faltas
confirmadas, emite e registra o fechamento. `app_ponto_emitir_espelhos` recusa quem tem bloqueio (`com_pendencia`) e
grava `empregador.logo` no conteúdo; ganhou `p_confirmar_faltas` (a de dois parâmetros saiu): sem ele, quem tem falta sem
justificativa não é emitido (`faltas_a_confirmar`), e toda emissão grava o fechamento. `app_salvar_empresa` aceita `logo`
(sem a chave, mantém). O papel leitura vê a validação sem o e-mail de quem fechou. Regressão: T45.
**LGPD de `ponto_folha_fechamentos`:** finalidade, prova do fechamento e das faltas aceitas para desconto; base legal,
obrigação legal (art. 7º, II; Portaria MTP 671/2021); retenção igual à do ponto (5 anos), descarte só por migration
própria que desligue o gatilho; quem vê, admin e gestor (o papel leitura só a contagem de faltas).

### Migration 100 (14/10): WhatsApp sem prévia de link (decisão 95)

`fn_evo_post` acrescenta `linkPreview = false` a todo `/message/sendText/*` que não traga a chave: com a prévia, a
mensagem com link ficava só no aceite do servidor do WhatsApp e não chegava ao celular (o espelho para assinatura).

### Migration 99 (14/10): trava de envio da homologação (decisão 94)

`fn_pode_enviar`: na homologação só os números de `telefones_homologacao` liberam envio (a marca `perfil_teste` do
técnico deixou de liberar — ela se edita no painel). `fn_evo_post` falha fechada: o caminho precisa terminar na
instância de `evolution_instancia`; a homologação só usa `trilha-homologacao`, a produção nunca a usa; na homologação,
`/message/*` sem `number` é recusado. Na produção o envio não muda. Regressão: T44.

### Migration 98 (14/10): Indicadores pela escala (decisão 93)

`app_painel_gerencial` (aba Indicadores) passa a contar a hora extra, o saldo e as semanas pela jornada do dia na
escala vigente de cada funcionário (`fn_carga_dia`), como o espelho e o Alerta Crítico. Feriado não é devido (na
12x36, o plantão no feriado é dia normal); folga e DSR trabalhados contam inteiros como hora extra; na 12x36, só o que
passa do plantão. "Semanas acima de 44 h" não conta semanas de 12x36 (a de 48 h alterna com a de 36 h). Sem escala, a
regra de antes. O retorno ganha `jornada.pela_escala` e `jornada.escalas` (quantas escalas no período). Os minutos
são de relógio; o espelho converte a hora noturna reduzida (diferença de poucos minutos em plantão que passa das 22h).
Regressão: T43.

### Migration 97 (14/10): espelho de ponto pela escala (decisão 91)

- `cargas_horarias.dsr_dia` (1 = segunda … 7 = domingo): qual folga é o descanso semanal remunerado; preenchida nas
  escalas já salvas (domingo quando é folga). `app_salvar_carga` aceita `p.dsr_dia` (padrão: domingo, se folga) e
  recusa DSR em dia de trabalho; `app_cargas` devolve `dsr_dia` (a versão antiga sai, o retorno mudou).
- `fn_carga_dia(tecnico, data)`: `{minutos, repouso (é o DSR), tipo, escala}`; sem escala, a regra de antes.
- `fn_ponto_espelho_conteudo`: débito e HE 50% sobre a jornada do dia; DSR e feriado a 100% (12x36 não); outra
  folga a 50%; por dia, `jornada_dia_min`, `escala` e `repouso` (`dsr`, `folga`, `feriado`); `jornada.escalas`.

### Migration 96 (14/10): limite de 2 h extras pela escala e Alerta Crítico (decisão 90)

- Tabela `programacao_aceites` (Programação, técnico, data, previsto, jornada do dia, excedente, motivo do art. 61,
  justificativa, texto do termo, SHA-256, nome, e-mail e papel de quem assina; só inclusão, RLS sem políticas; sem
  chave estrangeira, para a Programação e o técnico continuarem removíveis). Programação de teste não gera termo.
- `fn_programacao_limite(tecnico, data, hora, ignorar)`: dia previsto pelas Programações (primeira entrada à última
  saída, menos o maior intervalo), jornada do dia pela escala, limite (+ `ponto_he_limite_min`) e excedente.
  `fn_programacao_termo`, `fn_programacao_conferir_aceite` (motivo, justificativa de 40/80 caracteres, excessos
  vistos) e `fn_programacao_registrar_aceite`.
- `app_criar_escalas` ganha `p_aceite jsonb` (a versão de 10 parâmetros sai); `app_editar_escala` aceita `p.aceite`
  ao mudar data ou hora; `app_substituir_tecnico` recusa acima do limite. `app_programacao_limite` (admin e gestor)
  mostra o previsto e o termo; `app_programacao_aceites` lista os termos (admin e gestor).
- `fn_ponto_jornada_dia`: `contratual_min`, `he_escala_min` e `limite_min`; `he_acima_limite` pela escala.
  `fn_ponto_avisar`: Alerta Crítico ao supervisor. `app_carga_excedida(p_mes)` (admin, gestor e leitura; o leitura
  sem os aceites): quem passou do limite hoje e no mês.

### Migration 95 (13/10): o gestor não inclui marcação (decisão 89)

- `app_ponto_ajustar` recriada sem o ramo `incluir`: recusa com a orientação de usar o pedido do funcionário ou o
  abono. Só `desconsiderar` (marcação original ou inclusão vinda de pedido aprovado). A assinatura da função não
  muda (`p_data`, `p_hora` e `p_tipo` ficam sem uso), para não criar outra versão dela.

### Migration 94 (13/10): Escala / Carga Horária e Times, etapa 1 (decisão 88)

- Tabelas: `times` (empresa, nome único na empresa, ativo); `tecnicos.time_id`, resolvido pelo gatilho
  `trg_tecnico_time` a partir de `equipe` e `empresa_id` (acha ou cria o time); `cargas_horarias` (empresa
  empregadora, tipo `semanal`/`revezamento`/`12x36`, minutos de segunda a domingo ou plantão, intervalo, entrada
  opcional, média semanal, riscos aceitos; não muda, só `ativo`, gatilho `fn_carga_imutavel`); `carga_aceites`
  (texto exato do termo, instrumento coletivo, nome, e-mail, papel, hora e SHA-256; só inclusão);
  `carga_atribuicoes` (alvo empresa, time ou funcionário, início e fim, cancelamento só antes de começar).
- `fn_carga_validar(p)`: `{semanal_min, bloqueios, riscos, avisos}` pela CLT (parecer do `juridico`).
  `fn_carga_atribuicao(tecnico, data)`: a atribuição que vale (funcionário > time > empresa).
  `fn_carga_minutos_dia(tecnico, data)`: minutos contratuais do dia; sem escala, `jornada_min` de segunda a sexta,
  `ponto_jornada_sabado_min` no sábado e 0 no domingo; 12x36 com plantão no primeiro dia da vigência e dia sim, dia não.
- API: `app_cargas_modelos`, `app_carga_validar`, `app_salvar_carga(p, p_aceite)` (bloqueio não salva; risco só com
  `{aceito: true}`), `app_carga_ativar`, `app_cargas`, `app_atribuir_carga`, `app_cancelar_atribuicao`,
  `app_carga_atribuicoes`, `app_cargas_funcionarios`, `app_times`, `app_salvar_time`, `app_time_definir_membros`.
  Escrita: admin e gestor; leitura também para o papel leitura.
- `fn_carga_termo`: o texto do termo de aceite da empregadora (fala a empresa, por meio de quem assina; documento
  interno, nunca mostrado ao funcionário); `app_carga_validar(p, p_instrumento)` devolve-o em `termo` e
  `app_salvar_carga` grava esse mesmo texto mais a hora. O aceite traz os códigos dos riscos que o painel mostrou
  (`p_aceite.riscos`); se não coincidem com os atuais, recusa. Papel leitura: `criado_por`, `aceite_nome`,
  `aceite_texto` e `aceite_sha256` vêm nulos.
- Gatilho `fn_carga_imutavel` nas três tabelas: escala só muda `ativo`; aceite não muda; atribuição só muda o fim
  (de hoje em diante) e o cancelamento; nada é apagado.
- Carga inicial: escala "Jornada padrão" (`jornada_min` de segunda a sexta e `ponto_jornada_sabado_min` no sábado;
  44h 6x1 por padrão) para cada empregadora ativa, atribuída à empresa a partir da data da aplicação.
  `fn_payload_escala` recriada com o rodapé "Trilha".

### Migration 93 (13/10): "Escala" vira "Programação" nos textos (decisão 87)

- Só textos entre aspas, em 21 funções (mensagens do WhatsApp e da URA, avisos ao supervisor, mensagens de
  erro): `fn_titulo_escala` ("PROGRAMAÇÃO — dd/mm"), `fn_payload_escala`, `fn_msg_supervisor`,
  `fn_wh_mensagem`, `fn_voz_twiml`, `fn_voz_resposta`, `fn_alerta_prazo_escala`, `fn_vigiar_motor`,
  `fn_remover_escala`, `app_editar_escala`, `app_reenviar_escala`, `app_substituir_tecnico`, entre outras.
  Nomes de tabelas, colunas e funções não mudam.

### Migration 92 (13/10): cofre das folhas assinadas (decisão 86)

- `painel_usuarios.rh_folhas` e `fn_rh_folhas(email)`: permissão "cofre de folhas assinadas" (admin ou gestor,
  ativo). `app_definir_rh_folhas` e `app_rh_folhas_historico` (admin), histórico em `painel_rh_folhas_log` (só
  inclusão). `app_meu_acesso` devolve `rh_folhas`.
- `app_ponto_espelho_ver` (recriada): folha assinada só com `rh_folhas`, e a abertura fica em
  `ponto_espelho_acessos` (só inclusão, RLS sem políticas).
- `app_ponto_cofre_folhas(p_competencia, p_tecnico)` e `app_ponto_espelho_prova(p_id)` (só `rh_folhas`): lista
  das folhas assinadas e a prova para perícia (conteúdo exato, hashes, assinatura, HMAC conferido). Teste T39.

### Migration 91 (13/10): HMAC na assinatura e folga compensatória (decisão 84)

- `fn_ponto_assinatura_hash` passa a HMAC-SHA256 com a chave `ESPELHO_ASSINATURA` do Vault (criada pela
  migration, no próprio banco). `ponto_espelhos.assinatura_chave` guarda a impressão da chave que assinou
  (`fn_ponto_assinatura_chave`, 8 hexadecimais); `ponto_assinar_espelho` grava, o gatilho de imutabilidade
  protege, e `ponto_verificar_espelho` devolve `assinatura_chave_indisponivel` em vez de "não confere" quando
  a chave do banco é outra.
- `ponto_abonos.folga_de`: o domingo ou feriado trabalhado que o dia de folga compensa.
  `app_ponto_folga_compensatoria(p_tecnico, p_folga, p_trabalhado)` (admin, gestor) lança a folga: dia
  inteiro abonado, até 6 dias do trabalho, uma por domingo ou feriado, só com trabalho no ponto naquele dia;
  recusa sábado sem expediente, dia fora do vínculo, dia com trabalho, folga passada há mais de 7 dias e mês
  com espelho emitido; avisa o funcionário pelo WhatsApp. Motivo `folga_compensatoria` no catálogo, inativo.
- `fn_ponto_espelho_conteudo`: domingo ou feriado compensado (folga já acontecida, sem trabalho) sai como trabalho comum (HE 50% acima de 8 h, sem
  100%); por dia, `folga_de` e `compensado_em`; no informativo, `folgas_compensatorias` e
  `domingos_feriados_compensados`. Teste T38.

### Migration 90 (13/10): resumo de pagamento no espelho, em horas (decisão 83)

- `fn_ponto_noturno_dia(tecnico, data, fuso)`: minutos de relógio trabalhados entre 22 h e 5 h no dia, pelos
  pares de marcações efetivas.
- `fn_ponto_espelho_conteudo` recriada: todos os dias do vínculo no mês (a partir da primeira marcação), com
  `previsto_min`, `he50_min`, `he100_min`, `noturno_min`, `debito_min` e `feriado` por dia (o motivo de saúde
  não entra: o atestado só muda o cálculo); bloco
  `resumo` com `a_pagar` (HE 50%, HE 100%, noturnas reduzidas, intervalo não concedido), `a_descontar`
  (débito, dias sem registro, semanas com falta) e `informativo` (previstas, trabalhadas, abonadas com
  justificativa e pela empresa, dias abonados com justificativa, feriados e alertas); `avisos` ao funcionário. Mês sem
  nenhum registro continua sem espelho. Teste T37.

### Migration 89 (13/10): espelho mensal, parte B — envio e assinatura (decisão 82)

- `app_ponto_enviar_espelhos(p_competencia, p_espelho)` (admin, gestor): manda pelo WhatsApp o link
  `app_url/ponto?espelho=id` dos espelhos vigentes não assinados e não enviados, ou reenvia um (`p_espelho`);
  pula desligado, sem `opt_in` e barrado por `fn_pode_enviar`; `enviado_em` guarda o primeiro envio. Config
  nova `app_url`.
- `app_ponto_espelho_ver(p_id)` (admin, gestor): conteúdo e assinatura para ver e imprimir.
- `ponto_meus_espelhos(p_token)`, `ponto_meu_espelho(p_token, p_id)` e
  `ponto_assinar_espelho(p_token, p_id, p_sha256, p_assinatura, p_ciente)`: só o próprio funcionário; assina
  só a versão vigente cujo hash ele viu; PNG em data URL até 300 KB; grava IP e aparelho.
- `fn_ponto_assinatura_hash`: SHA-256 de hash do espelho, imagem, hora (UTC), IP e aparelho (como texto);
  `ponto_verificar_espelho` passa a conferir a assinatura por ele. Teste T36.

### Migration 88 (13/10): espelho de ponto mensal com registro e QR (decisão 82, parte A)

- Tabela `ponto_espelhos`: cópia congelada do espelho de um funcionário num mês (`conteudo` jsonb, Portaria
  671 Art. 84), `sha256`, `registro` por empresa sem lacuna (`ponto_espelho_sequencia`), `codigo` de
  verificação (80 bits, `fn_ponto_codigo_verificacao`), versão e substituição; colunas de envio e assinatura
  para a parte B. Conteúdo imutável; envio, substituição e assinatura gravados uma vez só
  (`fn_ponto_espelho_imutavel`); sem delete nem truncate. RLS sem políticas.
- `fn_ponto_espelho_conteudo(tecnico, mes)`: empregador, trabalhador (nome, CPF, admissão, função), jornada
  contratual, dias (`fn_ponto_jornada_dia`), marcações tratadas (ajustes com motivo, sem o e-mail de quem
  tratou) e totais.
- `app_ponto_emitir_espelhos(p_competencia, p_tecnico)` (admin, gestor): só mês encerrado; não reemite
  assinado; reemissão igual não cria versão. `app_ponto_espelhos(p_competencia)` (admin, gestor, leitura).
- `ponto_verificar_espelho(p_codigo)`: conferência pública do QR (anon, sem sessão — exceção no CI), devolve
  só registro, empresa, CNPJ, mês, emissão, integridade e assinatura; nenhum nome, CPF ou horário. Teste T35.

### Migration 87 (13/10): AFD do REP-P, versão de conferência (backlog 085, decisão 81)

- `app_ponto_afd(p_empresa, p_de, p_ate)` (só admin): texto do AFD no leiaute do Anexo V da Portaria 671 —
  cabeçalho (tipo 1) com CRC-16/KERMIT, marcações do REP-P (tipo 7) com SHA-256 dos campos 1 a 7 mais o hash
  do registro anterior (encadeado desde a primeira marcação da empresa, mesmo fora do período), trailer (tipo
  9); ISO 8859-1, CR LF. Devolve nome, conteúdo, quantidade, sha256 e o aviso de versão de conferência.
- Auxiliares `fn_afd_crc16`, `fn_afd_a` (alfanumérico com espaço, só ISO 8859-1), `fn_afd_n` (numérico com
  zeros), `fn_afd_dh` (data e hora com fuso, segundos 00).
- Tabela `ponto_afd_geracoes` (quem, empresa, período, quantidade, sha256; sem CPF): só inclusão. Config
  `rep_p_inpi` e `rep_p_desenvolvedor_cnpj` (vazias) e `afd_leiaute_conferido` (`false`: nome com
  `_CONFERENCIA`). Teste T34.

### Migration 86 (13/10): dossiê de conformidade por local (backlog 100, decisão 79)

- Tabela `dossie_geracoes` (email, local, data, técnicos, quando): RLS ligado sem políticas, só inclusão
  (`fn_ponto_imutavel` em update, delete e truncate).
- `app_dossie_local(p_local, p_data)` (admin, gestor, leitura): técnicos escalados no local e na data (fora
  teste, cancelada, recusada e rascunho), cada um com os documentos que a atividade exige e a situação na
  data do serviço (`valido`, `vencendo` até `certificacao_aviso_dias`, `vencido`, `sem_data`,
  `nao_cadastrado`) e `apto` (escala sem tipo de atividade sai `sem_atividade` e nunca apta). Só a situação, sem arquivo, CPF ou telefone. Registra a geração. Teste T32.

### Migration 85 (13/10): painel gerencial de aderência (backlog 099, decisão 78)

- `app_painel_gerencial(p_de, p_ate)` (admin, gestor, leitura; até 62 dias): escala (enviadas, resolvidas
  pelo WhatsApp — resposta com `wa_message_id` —, pela URA, sem resposta, ligações e atendidas, mediana) e
  ponto (funcionários com CPF e empresa, fora os de teste, entre a admissão e o desligamento; dia a dia até
  ontem por `fn_ponto_jornada_dia`: marcações, ajustes, abonos, hora extra acima da jornada de cada dia,
  saldo de horas, alertas por tipo, semanas acima de 44 h e abaixo do esperado). Só agregados, sem nome.
- Config nova: `ponto_jornada_sabado_min` (240) e `ponto_sabado_sem_expediente_abona` (`true`). Teste T31.

### Migration 84 (13/10): ponto não captura a explicação de uma recusa

- `fn_wh_mensagem`: ao registrar a recusa (problema), fecha a conversa do ponto aberta do técnico.
- `fn_ponto_wh`: com recusa aberta esperando o motivo (até 2 h) e sem conversa do ponto aberta depois dela,
  número ou palavra solta segue para as escalas ("1" é o motivo; "almoço" é a resposta). Dado o motivo, o
  detalhe é opcional e os atalhos do ponto ("entrada", "saída") voltam a valer. "ponto" escrito de
  propósito e o botão do ponto valem sempre. Pendente de antes: `fn_wh_mensagem` acha o técnico sem filtrar
  ativo nem número ambíguo (cadastro duplicado no mesmo número). Teste T30.

### Migration 83 (13/10): intervalo de 15 minutos acima de 4 h (CLT art. 71, §1º)

- `fn_ponto_jornada_dia`: `sem_intervalo` vale para jornada efetiva (com hora extra) acima de 4 h; antes,
  só trabalho normal acima de 6 h. O cálculo é refeito a cada consulta: dias antigos de 4 a 6 h sem
  intervalo passam a aparecer com o alerta no espelho. Empresa com pré-assinalação do intervalo (CLT art.
  74, §2º) teria alerta falso: decidir com o responsável quando houver.
- `fn_ponto_avisar`: os avisos de intervalo ausente e curto dizem o mínimo certo — 15 minutos (mais de 4 h)
  ou 1 hora (mais de 6 h).
  Teste T29.

### Migration 82 (13/10): registro das duas etapas (backlog 097, decisão 68)

- `painel_mfa_log` (só inclusão): e-mail, `ativou` ou `desativou`, hora. Gravado por `fn_mfa_registrar`,
  gatilho em `auth.mfa_factors` (fator confirmado = ativou; fator confirmado removido = desativou; cadastro
  abandonado não conta). Não depende do painel. Falha no registro nunca impede o login. Usuário removido
  do Auth: a remoção em cascata pode registrar `(usuário removido)` no lugar do e-mail.
- `app_usuarios_mfa()` (admin): quem tem a verificação ativa e desde quando, e os últimos 100 registros.
  Painel 3.24.0, tela Usuários: coluna "Duas etapas" e histórico. Teste T28.

### Migration 81 (13/10): endurecimento (pendências do PR #3)

- `fn_validar_config`: `monitor_ping_url` só `https://hc-ping.com/<uuid>` ou vazio. Teste T27.
- Fora do banco, no mesmo pacote: `webhook-evolution` lê o corpo em fluxo com teto de 5 MB (com ou sem
  `content-length`); `documento-ocr` responde CORS só aos domínios do painel.

### Migration 80 (13/10): pendências das migrations 78 e 79

- Checklist Sistema, "Erros em tabelas" › "Supervisores e técnicos sem empresa": falha com mais de uma
  empresa ativa (supervisor sem empresa recebe avisos de todas, decisão 69); com uma, só informa.
- `fn_validar_config`: `alerta_certificacoes_dow` aceita 0 a 7 (0 desliga; 7 = domingo). Antes ia só até 6,
  e o domingo era impossível. Teste T26.

### Migration 79 (12/10): avisos aos supervisores por empresa (decisão 69)

- `fn_avisar_supervisores(p_texto, p_exceto, p_empresa)`: só supervisores da empresa (`p_empresa` ou a do
  técnico `p_exceto`) e os sem empresa; sem nenhuma das duas, todos (alerta de sistema).
- Fase 3 de `fn_dispatcher_whatsapp`: mesma regra, pela empresa do técnico da escala.
- `fn_alerta_prazo_escala` e `fn_alerta_certificacoes`: com mais de uma empresa, uma mensagem por empresa.
  Teste T25.

### Migration 78 (12/10): teto nos avisos aos supervisores (decisão 68)

- `config.supervisor_avisos_por_execucao` (5): a fase 3 de `fn_dispatcher_whatsapp` avisa no máximo
  esse número de escalas por execução, das mais antigas para as mais novas; as demais ficam para a
  execução seguinte (só a escala avisada ganha `supervisor_avisado_em`; escala que falha não ocupa o
  teto). Conta escalas: o pico é 5 × supervisores ativos por minuto. Teste T24.

### Migration 77 (11/10): feriado e afastado fora da cobrança; MFA (decisões 65 e 67)

- `fn_pendencias_escala`: feriado não exige escala; técnico afastado no dia não conta como sem escala;
  devolve `feriado` e `afastados`.
- `config.mfa_obrigatorio` (nasce `false`). `app_exigir`: com ela ligada, só sessão aal2 (código do
  aplicativo autenticador). `app_meu_acesso` devolve `mfa_obrigatorio`. Teste T23.

### Migration 76 (11/10): limpeza da estrutura (decisão 66)

- Checklist Sistema: o item "Tarefas agendadas" aponta, como falha, qualquer uma das 5 tarefas
  obrigatórias faltando (`dispatcher-whatsapp`, `vigia-motor`, `limpeza-logs`, `ponto-lembrete-almoco`,
  `ponto-geo`). Na homologação, sem cron, só informa.
- Removidos, sem chamador no painel, nas Edge Functions, em gatilhos, funções ou views:
  `app_config`, `app_documentos_expirados`, `app_salvar_tecnico_habilidade` (substituída por
  `app_definir_habilidades`), `app_ponto_marcacoes` (substituída por `app_ponto_acompanhamento`),
  `vw_resumo_dia` e `fn_set_ator` (época do Retool). Fica `vw_documentos_expirados`. Teste T22.

### Migration 75 (11/10): alerta da escala de amanhã sem véspera de feriado (decisão 65)

- `fn_alerta_prazo_escala`: não avisa (16h) nem cobra o prazo (18h) quando amanhã está em `feriados`.
  Teste T21.

### Migration 74 (12/10): alta antecipada registrada pelo gestor (decisão 64)

- `ponto_justificativas.canal` aceita `painel`. `app_ponto_afastados()` (admin, gestor): quem está afastado
  hoje e até quando, nunca o motivo. `app_ponto_registrar_alta(técnico, dia, anexo, tipo, observação)`:
  exige "vê atestados", funcionário afastado no dia e a liberação médica; o documento vai para o cofre e a
  alta sai aprovada. `fn_ponto_midia_receber`: a confirmação do atestado no WhatsApp orienta a falar com o
  gestor. Teste T20.

### Migration 73 (12/10): texto da marcação recusada no afastamento

- `fn_ponto_bloquear_afastado`: "Você está afastado até DD/MM. Para voltar antes, tenha a liberação médica
  em mãos e entre em contato com seu gestor." (pedido do responsável). A regra não muda.

### Migration 72 (12/10): justificativa E3 — reincidência, pedido parado e métrica

- `fn_dias_uteis(de, até)`: dias de segunda a sexta, fora de `feriados`, depois de `de` até `até` (a regra
  da URA). `app_ponto_justificativas` ganhou `ponto_30d` (reincidência, só o fato e só de pedidos de
  Ponto — atestado e falta legal nunca contam; nulo para o papel leitura) e `dias_uteis_espera`.
- `fn_ponto_alerta_pedidos_parados`: pedido pendente há mais de 2 dias úteis avisa os supervisores, um
  aviso por empresa por dia útil, das 08:00 às 18:00 (sem nome nem motivo). Chamado por
  `fn_ponto_lembrete_almoco`, que já roda no cron do ponto a cada 15 minutos: nada muda no cron.
- `app_ponto_justificativas_metricas(de, até)`: recebidos, decididos, decididos em até 2 dias úteis,
  pendentes, parados e inclusões manuais do gestor (`incluir` sem pedido). Teste T19.

### Migration 71 (12/10): registro do documento e QR de verificação (decisão 62)

- `ponto_documento_registros` (só inclusão, sem FK para o anexo, sobrevive ao descarte): registro sequencial
  por empresa, `codigo` de verificação (16 caracteres base32), SHA-256, recebimento e canal. Numerado pelo
  gatilho `trg_ponto_documento_registrar` com `ponto_documento_sequencia`, na mesma transação do documento
  (sem lacuna). Documentos que já existiam foram numerados pela ordem de chegada.
- `app_ponto_anexo_ver` devolve também registro, código, empresa, pedido, recebimento, canal, SHA-256 e
  `integro` (recalculado a cada abertura). `app_ponto_verificar_documento(código)` (admin, gestor;
  até 20 por minuto por usuário): conferência do QR, sem o documento; motivo de saúde mascarado sem `ve_saude`; registra em
  `ponto_documento_verificacoes`. Teste T18.

### Migration 70 (11/10): documento da justificativa pelo WhatsApp (084 entrega 3, E2b; decisão 61)

- O "ajuste" no WhatsApp aceita Saúde, Família e Convocação: menu do grupo (`fn_ponto_menu_falta`,
  `fn_ponto_motivos_grupo`, pela ordem de `ponto_motivos`) → dia → último dia ou validade (`mesmo` = um
  dia) ou horário (motivo por horário) → documento (`fn_ponto_pedir_documento`, conversa aberta 30 min).
  Etapas novas em `ponto_conversas_etapa_ck`: `aj_falta_motivo`, `aj_falta_dia`, `aj_falta_fim`,
  `aj_falta_periodo`, `aj_documento`.
- `fn_ponto_wh`: foto ou arquivo só é aceito na etapa `aj_documento`; fora dela, continua recusado.
  `fn_ponto_documento_recebido` confere formato (nada de visualização única, vídeo ou figurinha), tipo
  declarado (JPG, PNG, PDF) e tamanho (até 5 MB), grava só o id da mensagem na conversa e devolve
  `ponto_baixar_midia`.
- A Edge Function `webhook-evolution` baixa o arquivo pela Evolution (`getBase64FromMediaMessage`), tira
  EXIF/XMP/IPTC e textos do PNG e chama `fn_ponto_midia_receber` (cria o pedido com
  `fn_ponto_falta_criar(..., 'whatsapp')`, que confere o tipo pelos bytes e cifra no cofre) ou
  `fn_ponto_midia_falhou`. `fn_ponto_falta_criar` ganhou `p_canal` (padrão `app`). Atestado avisa os
  supervisores das escalas no período (`fn_ponto_avisar_afastamento`). O texto ao funcionário diz só
  "Saúde", nunca o motivo. Teste T17.

### Migration 69 (11/10): validade do atestado bloqueia ponto e escala (decisão 60)

- Motivo `alta_medica` (atestado de aptidão). `fn_ponto_afastado_ate(técnico, dia)`: data final do
  atestado em vigor (pendente ou aprovado), salvo alta posterior.
- Gatilhos `trg_ponto_marcacoes_afastado` (recusa marcação) e `trg_escalas_afastado` (recusa criar ou
  mover escala). `vw_acoes_pendentes` e `vw_ligacoes_pendentes` ignoram escala de técnico afastado.
- `ponto_justificar_atestado` (app): atestado exige `p_valido_ate`; alta é de um dia; avisa supervisores
  das escalas no período. `ponto_eu` devolve `afastado_ate`. `app_ponto_decidir`: aprovar alta só
  registra a liberação (sem abono). Teste T16.

### Migration 68 (11/10): atestado e faltas com documento no cofre (084 entrega 3, E2; decisão 56)

- **Cofre:** `ponto_justificativa_anexos` guarda o documento **cifrado** (pgcrypto, AES-256) com a chave
  `COFRE_PONTO` do Vault, gerada no próprio banco (nunca no repositório). Tipo conferido pelos primeiros
  bytes (JPG, PNG, PDF), até 5 MB, sha256 registrado. `ponto_anexo_acessos` registra cada abertura.
  **A chave precisa de cópia fora do Supabase** (ver `docs/operacao.md`): sem ela, um backup restaurado
  não abre os documentos.
- **Permissão:** `painel_usuarios.ve_saude` ("vê atestados"), dada pelo admin (`app_definir_ve_saude`);
  `fn_ve_saude`. Só quem tem vê motivo de saúde, decide pedido de saúde e abre documentos
  (`app_ponto_anexos`, `app_ponto_anexo_ver`). Leitura nunca. `app_meu_acesso` devolve `ve_saude`.
- **Pedido:** `ponto_justificar_falta` (app; documento obrigatório quando o motivo exige) com período de
  dias (`data_fim`, até 31) ou de horas (consulta, pré-natal); `fn_ponto_limite_alerta` grava
  `alerta_limite` quando passa do limite de `ponto_motivos` (alerta, nunca bloqueia). Saúde, Família e
  Convocação ativos. `app_ponto_justificativas` ganha `data_fim`, `restrito`, `pode_decidir`, `anexos`,
  `alerta_limite`, `fora_prazo` (mais de 48 h). Aprovado: abono de cada dia ou do horário; a mensagem ao
  funcionário não cita motivo de saúde. No WhatsApp, as opções 1 a 3 orientam a usar o app (mídia pelo
  WhatsApp fica para a E2b). Teste T15.

### Migration 66 (11/10): justificativa de ponto pelo funcionário (084 entrega 3, E1; decisões 55 a 58)

- **`ponto_motivos`**: motivos e limites legais em dado (base legal, quantidade, unidade, janela, exige
  anexo, é saúde, ativo). Nesta entrega só os três da categoria Ponto ficam ativos; Saúde, Família e
  Convocação estão cadastrados e inativos até a E2 (anexo no cofre, decisão 56).
- **`ponto_justificativas`**: pedido do funcionário (número sequencial, motivo, dia, marcação e hora
  ou período, observação até 500 letras, canal app/WhatsApp, situação pendente → aprovada/negada,
  quem decidiu, resposta). Não se apaga. No máximo 10 pendentes por funcionário; pedido igual em
  análise é recusado; só os últimos 62 dias, nunca o futuro.
- **`ponto_abonos`**: falta ou atraso abonado (dia inteiro ou período), sem marcação. Imutável; estorno
  é uma linha nova (`estorno_de`, único). `ponto_ajustes` ganha `justificativa_id`.
- **Funções:** `ponto_justificar` e `ponto_minhas_justificativas` (app, funcionário da sessão);
  `fn_ponto_wh_ajuste` (WhatsApp: palavra **ajuste**, menu de 4 opções, conversa de 15 min em
  `ponto_conversas.dados`); `app_ponto_justificativas` (pendentes sempre + período; leitura sem
  observação nem resposta), `app_ponto_decidir` (esqueci/app falhou → `ponto_ajustes incluir` ligado
  ao pedido; atraso → abono; negar exige 10 letras e vai ao funcionário), `app_ponto_abonar`,
  `app_ponto_estornar_abono`, `app_ponto_abonos`. Supervisores da empresa são avisados do pedido só com
  o primeiro nome e o número.
- **Espelho:** `fn_ponto_jornada_dia` devolve `falta` (dia com escala, já passado, sem marcação),
  `falta_abonada`, `atraso_abonado`, `abono` e `abonado_min`; `app_ponto_espelho` lista também dias
  com escala e com abono e ganha a coluna `abono`. Teste T14 em `supabase/tests/regressao.sql`.

### Migration 65 (10/10): ajustes de ponto com justificativa (backlog 084, entrega 2; decisão 52)

- **`app_ponto_ajustar(técnico, ação, motivo, marcação, ajuste, data, hora, tipo)`** (admin e gestor):
  grava em `ponto_ajustes` — `incluir` (tipo + data e hora **locais**, convertidas pelo fuso da empresa;
  inclusão idêntica é recusada) ou `desconsiderar` (uma marcação **ou** uma inclusão anterior do mesmo
  funcionário — é assim que se desfaz inclusão com hora errada). Nunca no futuro nem antes de 62 dias.
  Motivo de 10 a 500 letras, autor = e-mail do painel; o ajuste fica com a empresa da marcação. A
  marcação original não muda. O funcionário recebe pelo WhatsApp o que mudou (data, marcação e hora),
  **sem o motivo**, no máximo um aviso a cada 5 minutos (`alertas_enviados`); a função devolve `avisado`.
- `ponto_ajustes` ganha **`ajuste_id`** (alvo do desconsiderar quando é uma inclusão), o check
  `ponto_ajustes_alvo_ck` (desconsiderar tem exatamente um alvo; incluir não tem alvo), o limite de 500
  letras no motivo e **índices únicos** parciais em `marcacao_id` e `ajuste_id` para `desconsiderar`
  (o mesmo alvo nunca duas vezes, nem com dois cliques simultâneos).
- **`app_ponto_ajustes(de, até, técnico)`**: lista do período (até 62 dias), com `desfaz_inclusao` e
  `desconsiderado`; o papel **leitura** recebe motivo e autor nulos (decisão 52 A).
- **`fn_ponto_marcacoes_efetivas`**: marcações não desconsideradas + inclusões não desfeitas. É a base de
  **`fn_ponto_jornada_dia`** (cálculo do dia e interjornada), que passa a devolver `ajustes` (quantos
  ajustes tocam o dia); **`app_ponto_espelho`** ganha a coluna `ajustes` e mostra também o dia que só
  tem marcação incluída.
- **`fn_ponto_avisar`**: o aviso de jornada ao gestor leva só o **primeiro nome** (decisão 52 B).
- `fn_ponto_rotulo(tipo)`: rótulo da marcação nas mensagens. Teste T11 em `supabase/tests/regressao.sql`.

### Migration 64 (10/10): URA só em dia útil e fora de feriado (decisão 54)

- **`feriados`** (data, nome, abrangência): nacionais, 2 de Julho, 24/06 e 08/12 de Salvador, Sexta-feira
  Santa, e Carnaval e Corpus Christi (ponto facultativo), de 2026 a 2030. RLS sem políticas. Incluir
  feriado novo é um `insert`. **`fn_pascoa(ano)`** calcula a Páscoa.
- **`fn_ligacao_permitida(momento)`**: segunda a sexta, fora de feriado, entre `ligacao_janela_inicio` e
  `ligacao_janela_fim`, no fuso da config. Usada por `vw_ligacoes_pendentes` (disparo automático) e por
  `fn_preparar_ligacao` ("Ligar agora" e disparo).

### Migration 63 (10/10): nenhum papel da API alcança tabela, view ou sequência (decisão 51)

- `revoke all` em todas as tabelas, views e sequências do `public` para `anon`, `authenticated` e
  `service_role`. Antes, o `service_role` (que ignora o RLS) alcançava 33 das 42 tabelas e views, e as
  três sequências estavam abertas também para `anon` e `authenticated` (padrão antigo do Supabase).
- Default privileges do `postgres`: tabela e sequência novas já nascem fechadas.
- O acesso aos dados segue só pelas funções `security definer` (rodam como `postgres`). A suíte de
  regressão (T1) confere zero privilégios e que tabela nova nasce fechada.

### Migration 62 (09/10): permissões sem `service_role` e função nova fechada (decisão 51)

- O bloco de permissões revoga também do **`service_role`**: nenhuma função do schema `public` é
  executável por ele. `app_*` → `authenticated`; `ponto_*` → `anon` e `authenticated`; o resto só
  `postgres` (Edge Functions, pg_cron e backup entram como `postgres`).
- **Default privileges** do `postgres`: função nova nasce sem execute para `public`, `anon`,
  `authenticated` e `service_role`. O padrão global vale para qualquer função criada pelo `postgres`:
  extensão ativada depois da migration 62 pode precisar de `grant` explícito.
- **`supabase/tests/regressao.sql`**: suíte de regressão e carga (T1 a T9; T10 a T13 em 10/10: URA em dia útil, ajustes de ponto, fuso do motor e habilidades) numa transação desfeita;
  roda no CI e na homologação. Medido na homologação em 09/10: 2.000 marcações em 2,5 s (NSR e cadeia
  íntegros) e 300 mensagens do WhatsApp em 0,4 s.

### Migration 61 (09/10): jornada e avisos da CLT no ponto (backlog 084, entrega 1)

- **`fn_ponto_jornada_dia(técnico, data)`**: entrada, almoço, saída, trabalhado, intervalo, hora
  extra, interjornada, escala e atraso do dia, com os alertas: `intervalo_curto` (abaixo de 1 h em
  jornada acima de 6 h; abaixo de 15 min de 4 a 6 h — CLT art. 71), `intervalo_longo` (acima de 2 h),
  `sem_intervalo`, `he_acima_limite` (acima de 2 h — art. 59), `interjornada_curta` (abaixo de 11 h
  — art. 66), `atraso` (entrada mais de 5 min depois da escala — art. 58) e `incompleta`. O dia é a data local da
  marcação (jornada que cruza a meia-noite fica dividida: tratar com a convenção, L2).
- **`fn_ponto_aviso_previo`** / **`ponto_aviso_previo`** (app): aviso **antes** de registrar a volta
  do almoço com intervalo abaixo de 1 h. **`fn_ponto_avisar`**: depois da marcação, devolve os avisos
  ao funcionário (comprovante do WhatsApp e do app, via `ponto_bater`) e avisa os supervisores **da mesma
  empresa** (com `opt_in`, fora de `perfil_teste`) uma vez por dia por tipo (`alertas_enviados`).
  Nenhum aviso bloqueia a marcação, e erro no cálculo do aviso nunca desfaz a marcação (só warning).
- **`app_ponto_espelho(de, até, técnico)`**: espelho previsto × realizado por funcionário e dia.
- Parâmetros novos em `config`: `ponto_intervalo_max_min` (120), `ponto_intervalo_curto_min` (15),
  `ponto_he_limite_min` (120), `ponto_interjornada_min` (660), `ponto_tolerancia_min` (5); usa também
  `jornada_min` e `intervalo_min`.

### Migration 60 (08/10): localização encaminhada ou reenviada não bate ponto

- `fn_ponto_wh` procura o aviso de encaminhada também em `data.contextInfo` (Evolution 2.x) e em
  `message.messageContextInfo`. Localização **fixa** com coordenada igual (6 casas) à de uma marcação
  do mesmo funcionário nos últimos 60 dias pede a **localização em tempo real** (não pode ser
  encaminhada); não bloqueia o funcionário honesto cujo GPS repete a coordenada.

### Migration 59 (08/10): menu do ponto com botões e volta ao menu

- **`fn_ponto_menu`** abre a conversa e manda o menu: até **3 botões** (limite do WhatsApp; as
  marcações mais prováveis por **`fn_ponto_opcoes`**, a sugerida primeiro) e, no mesmo texto, o menu
  numerado de 1 a 6 e *0* Cancelar — que vale sempre, mesmo se os botões não aparecerem
  (`usar_botoes` = false manda só o texto).
- **`fn_ponto_wh`** aceita a resposta de botão `ponto:<tipo>`; dentro da conversa, resposta inválida
  volta para o menu (sem estender os 10 minutos) e *0*/cancelar encerra. Mensagem que cita outra,
  botão de outro fluxo, resposta típica de escala (sim, ok, 1, 2, problema) e detalhe de ocorrência
  aberta seguem para as escalas.

### Migration 58 (08/10): bairro e cidade das marcações (decisão 50)

- **`ponto_geo`**: bairro, cidade e UF por coordenada arredondada em 3 casas (~110 m), vindos do
  Nominatim/OpenStreetMap. RLS sem políticas. A marcação não muda.
- **`fn_ponto_geo_processar`** (pg_cron a cada minuto, só na produção): lê as respostas, enfileira as
  coordenadas novas e envia uma consulta por execução. Parâmetro `geocodificacao_url` (vazio desliga).
- **`app_ponto_geo(de, até, técnico)`**: bairro e cidade de cada marcação do período, para o painel.

### Migration 57 (08/10): escala exige local

- Gatilho **`trg_escalas_exige_local`** (`fn_escala_exige_local`): inserir escala sem local, ou
  apagar o local de uma escala, é recusado — em qualquer caminho (painel, importação, lote, edição).
- **`fn_payload_escala`** recusa montar a mensagem de escala sem local: escala antiga sem local não é
  enviada; o motor registra a falha e, esgotadas as tentativas, avisa o supervisor.
- URA: **`fn_preparar_ligacao`** (motor e botão de ligar) recusa escala sem local, e
  **`vw_ligacoes_pendentes`** não a lista. **`fn_evolution_falhando`** ignora falha interna
  (`erro_codigo = 'interno'`), para escala sem local não virar alarme falso de Evolution caída.
- Como `escalas.local_id` é `on delete set null`, apagar um local com escalas agora é recusado pelo
  gatilho (o painel só desativa local, não apaga).

### Migration 56 (07/10): Módulo Registro de Ponto — WhatsApp e acompanhamento do gestor (backlog 083 e 090)

- **WhatsApp:** `fn_webhook_evolution` passa cada mensagem primeiro por **`fn_ponto_wh`**, que devolve
  null quando não é do ponto (aí segue para `fn_wh_mensagem`, sem mudança). Só conversa com o ponto
  quem tem CPF e empresa. Palavras: ponto (menu de 1 a 6 com sugestão), entrada, almoço (saída ou
  volta, conforme a última), volta, saída, HE (início ou fim). Depois pede a **localização atual**; a
  hora é a do recebimento. Lugar escolhido no mapa (com nome ou endereço) é recusado. Comprovante com
  CPF mascarado. **`ponto_conversas`** guarda só a etapa (10 minutos), sem conteúdo de mensagem.
  Índice único em `origem->>'msg_id'`: entrega repetida da Evolution não duplica marcação.
  Recusa também localização encaminhada; ignora grupo, status, canal, mensagem sem id e telefone
  canônico que case com mais de um funcionário; número citando outra mensagem (a escala) não vale
  como escolha do menu; ao funcionário só volta mensagem de regra (`P0001`). Falha no ponto nunca
  derruba o fluxo de escalas. **LGPD:** `webhook_eventos` não guarda a localização (fica só
  `{"localizacao": true}`); a coordenada mora na marcação.
- **`fn_ponto_wa`**: envio do ponto pelo WhatsApp que nunca desfaz a marcação se o envio falhar.
- **`fn_ponto_lembrete_almoco`**: lembrete amigável da saída para o almoço, uma vez por dia, a quem só
  marcou entrada, entre `ponto_lembrete_almoco` (config, 12:00) e 15h; deduplicado em
  `alertas_enviados`. Agendado só na produção (`supabase/setup/cron.sql`). Retorno do almoço sem lembrete.
- **Painel:** `app_ponto_hoje` (por funcionário com ponto: escala do dia, última marcação, fora da
  área, situação `sem_entrada`/`com_marcacao`/`sem_marcacao`) e `app_ponto_acompanhamento(de, até,
  técnico)` (até 62 dias; para `leitura` some o e-mail do gestor e as coordenadas).

## Gatilhos em `escalas`

| Gatilho | O que faz |
|---|---|
| `trg_escalas_jornada` | Calcula turno, término, intervalo e minutos noturnos |
| `trg_escalas_confirmacao` | Carimba `confirmada_em` |
| `trg_escalas_updated` | Atualiza `updated_at` |
| `trg_escalas_evento` | Grava a auditoria em `escala_eventos` |
| `trg_escalas_teste` | Marca como teste a escala de técnico com perfil de homologação |

## Parâmetros (`config`)

Envio: `intervalo_reenvio_min` (30), `max_tentativas` (3), `timeout_entrega_min` (10),
`avisar_supervisor_na` (2), `envios_por_execucao` (3), `janela_envio_inicio` (06:00),
`janela_envio_fim` (21:00), `usar_botoes` (true), `webhook_ativo` (true).

Jornada: `jornada_min` (480), `intervalo_min` (60), `intervalo_apos_min` (240),
`noturno_inicio` (22:00), `noturno_fim` (05:00), `hora_noturna_min` (52.5).

Habilidades: `certificacao_aviso_dias` (30), `alerta_certificacoes_hora` (08:00),
`alerta_certificacoes_dow` (1 = segunda a 7 = domingo; 0 desliga o alerta).

Prazo: `alerta_escala_aviso` (16:00), `alerta_escala_prazo` (18:00),
`alerta_dias_semana` (1,2,3,4,5), `sem_escala_incluir_supervisores` (false).

Voz (URA): `ligacao_ativa` (false), `ligacao_apos_tentativas` (2), `ligacao_janela_inicio`/`_fim`
(08:00/20:00), `ligacao_max_por_escala` (2), `ligacao_intervalo_min` (45), `ligacao_por_execucao` (2),
`twilio_caller_id`, `voz_url`, `voz_voice`, `voz_timeout_dtmf`. Ver `supabase/setup/twilio.md`.

Voz (URA): ver `supabase/setup/twilio.md`. Documentos: ver `supabase/setup/documentos.md`.

Escala: `antecedencia_minima_min` (5) — minutos mínimos entre agora e o início da escala;
`conclusao_automatica_min` (5) — minutos depois do término previsto para a escala confirmada ou em
execução virar concluída (fase 7 do motor, decisão 30).

Retenção: `retencao_webhook_dias` (30), `retencao_cron_dias` (7), `retencao_payload_dias` (90,
apaga só o conteúdo enviado de `notificacoes.payload_envio`; a notificação fica).

Vigia: `motor_alerta_min` (5) — minutos sem execução concluída do motor para avisar os supervisores;
`alerta_tecnico_telefones` — telefones que também recebem os avisos técnicos (motor parado,
normalizado, banco cheio); `banco_alerta_mb` (350) — tamanho do banco que gera um aviso por dia;
`monitor_ping_url` — URL do healthchecks.io que recebe o sinal do motor (vazio desliga; decisão 34).

**Validação (migration 45):** o gatilho `trg_config_validar` recusa valor fora do formato das chaves
conhecidas (inteiro, hora `HH:MM`, `true`/`false`, fuso existente, lista de dias 1–7, telefones
E.164). Chave nova sem regra é aceita como texto.

Ambiente: `evolution_url`, `evolution_instancia`, `evolution_versao`, `webhook_url`, `fuso`.

Mudar qualquer um é um `update` — sem deploy:

```sql
update config set valor = '20' where chave = 'intervalo_reenvio_min';
```
