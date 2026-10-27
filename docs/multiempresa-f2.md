# Multiempresa — F2: a conta vem da sessão e toda função filtra por ela

**Base:** decisões 108, 112 e 113; `docs/multiempresa-estimativa.md` (F2, 2,5–3,5 semanas); matriz em
`docs/multiempresa-f0.md`. **Regra do período:** nenhuma funcionalidade nova nas `app_*` (decisão 108, item 7); um PR
por família, regressão inteira verde em todos; nenhuma assinatura de função muda (a conta vem do contexto).

## Etapas

| Etapa | Família | O que muda | Situação |
|---|---|---|---|
| F2a | Base | `fn_conta_atual` (sessão do painel; cabeçalho `x-conta` para quem está em mais de uma conta); `app_exigir` exige a conta e confere o papel nela; `app_meu_acesso` lista as contas; T57 | Migration 117 |
| F2b | Cadastros | técnicos, empresas, locais, times, habilidades, tipos, usuários e permissões do RH: leitura e escrita só da conta; registro novo nasce com a conta da sessão; nome de habilidade e tipos único por conta | Migration 118 |
| F2c | Programação | escalas, cargas, envio, ligações, pendências, linha do tempo, painel gerencial e indicadores; gatilho `fn_herdar_conta` nas 10 tabelas da família | Migration 119 |
| F2d | Documentos | documentos, dossiê e Storage por conta (arquivo só de técnico da conta); OCR segue com o papel global até a F2f | Migration 120 |
| F2e | Ponto | as 34 `app_ponto_*` (marcações, ajustes, abonos, pedidos, espelhos, folha, cofre, hora extra, AFD e conferência de documentos) só na conta; AFD e cadeia de NSR só de empresa da conta; herança de conta nas 22 tabelas do ponto. As `ponto_*` já ficam presas ao funcionário da sessão; o ponto não usa Storage (anexos no cofre do banco) | Migration 121 |
| F2f-1 | Motor | avisos a supervisores só da mesma conta (funcionário sem empresa avisa a conta dele); programação de amanhã e documentos a vencer calculados e registrados por conta; `alertas_enviados` com a conta na chave e herdada do funcionário ou da empresa; teto do app do ponto só à operadora; OCR com o papel na conta (`fn_papel_na_conta_de`) | Migration 122 |
| F2f-2 | Contrair | fim do default "conta 1" em `conta_id` e da trava da 117, junto da F3 (usuários por conta no painel) | Feito na F3d (migration 126): default da sessão, decisão 119 |

## Régua (T57)

O admin de uma conta B chama **toda** `app_*` com argumentos da conta A, montados do catálogo pelo nome e tipo de cada
parâmetro, cada chamada numa subtransação desfeita. Conta como vazamento quem devolve identificador ou nome da conta A
(leitura) ou muda dado dela (escrita). Em exigência total desde a F2e: vazamento derruba o CI e função nova entra
coberta sozinha.

**Linha de base (F2a, 26/10, banco vazio com o seed):** o T57 escolhe a linha da conta A pelo menor id (aleatório),
então o resultado varia um pouco a cada rodada. **Escrita (3 a 4 por rodada):** `app_definir_rh_folhas`,
`app_remover_escala`, `app_salvar_time`, `app_salvar_usuario`, `app_time_definir_membros`. **Leitura (13 ou 14):**
`app_aptidao`, `app_carga_excedida`, `app_documentos_por_tecnico`, `app_dossie_local`, `app_empresas`,
`app_escala_edicao`, `app_escalas`, `app_linha_do_tempo`, `app_locais`, `app_painel_locais`, `app_pendencias`,
`app_tecnico_habilidades`, `app_tecnicos` e, conforme o teto de códigos por hora, `app_ponto_gerar_codigo`. Cerca de 64
recusam e 26 não devolvem dado da A. **Depois da F2b (27/10):** a família de cadastros saiu da lista e virou **exigência no CI** (o T57 falha se uma função dela
vazar). Restam 1 por escrita (`app_remover_escala`) e 8 por leitura (`app_carga_excedida`, `app_documentos_por_tecnico`,
`app_dossie_local`, `app_escala_edicao`, `app_escalas`, `app_linha_do_tempo`, `app_painel_locais`, `app_pendencias`),
todas de programação e documentos. O T58 prova o caminho positivo: a conta B cadastra e vê só o que é dela, a conta 1 não
vê nem altera a B. **Depois da F2c (28/10):** nenhuma função vaza por escrita; restam por leitura `app_documentos_por_tecnico` e
`app_dossie_local` (F2d) e, conforme o teto de códigos, `app_ponto_gerar_codigo` (F2e). A exigência do T57 virou a
lista inversa: **qualquer** vazamento fora das famílias de documentos e ponto derruba o CI, inclusive em função nova.
O T59 prova a programação da conta B isolada e herdando a conta. **Depois da F2d (28/10):** só `app_ponto_gerar_codigo` aparece (F2e). O T57 aceita vazamento apenas em `app_ponto_*`;
o T60 prova documentos e Storage da conta B isolados. **Depois da F2e (29/10):** o T57 não acha vazamento em nenhuma `app_*` e
virou exigência total (qualquer vazamento derruba o CI). Para o ponto ele passou a montar argumentos que passam das
validações genéricas: período dentro do teto, motivo com texto suficiente, o funcionário da A com mais marcações, a
competência do último espelho da A, mais CPF, CNPJ e ids do ponto nas marcas e as tabelas do ponto no retrato de escrita.
**Prova de mutação (revisão do `seguranca`):** com as 34 definições antigas, sem filtro, o T57 pega 6 a 7, conforme o espelho
sorteado (`abonar`, `estornar_abono`, `afd`, `he_autorizacoes`, `previa_folha`, `validar_folha` e às vezes `espelho_ver`), e
o T61 também falha. A cada etapa, repetir a prova: reaplicar os corpos antigos na transação e exigir falha. O T57
**não cobre sozinho** as 34: o T61 prova os casos de leitura, ajuste, AFD, NSR, pedido e código, e a marcação da conta B
(local, NSR e cadeia na B). **Recusa não prova isolamento:** parte recusa pelo argumento genérico; cada família melhora os
argumentos das suas funções até a recusa ser pela conta.

## Pontos em aberto

- **Revisão de 25/10 (`docs/revisao-infra-dados-2026-10-25.md`):** a chave composta `(conta_id, id)` da
  decisão 108 não tinha entrado na F1. Entrou na **migration 123 (F2f-2a)**: 70 chaves compostas e o T63. **Pendente antes da F2f-2 (revisão do `seguranca`):**
  14 colunas de referência sem chave nenhuma (ex.: `ponto_marcacoes.escala_id`, `programacao_aceites`, anexos do cofre):
  chave composta ou exceção registrada, e o T63 cobrindo colunas `*_id` sem chave. Índices só de `conta_id` redundantes
  (16) ficam para a F8. **Regra até 31/10:**
  versão de migration à mão, maior que `20261030120000`.

- **Trava (revisão do `seguranca`, P1):** gatilho `tg_trava_conta_unica` recusa membro fora da conta 1 enquanto as
  famílias não filtram pela conta. **Condição para criar a primeira conta de cliente:** a trava e o default "conta 1"
  saem juntos, na F2f-2, com a F3 (decisão 114). Até lá, nenhuma conta além da 1 ganha membro.
- **Papel por conta (P1, na mesma trava):** as seis funções do ponto que mascaram pelo papel (`abonos`,
  `acompanhamento`, `ajustes`, `he_autorizacoes`, `justificativas`, `validar_folha`) usam `fn_papel_na_conta` desde a
  121, com máscara fechada quando o papel não é achado; o Storage desde a 120; o OCR desde a 122.
- **Usuários do painel (F3a, 124):** papel, ativo, nome e permissões do RH são da conta, em `conta_membros`;
  `painel_usuarios` saiu. `app_salvar_usuario` grava na conta da sessão (a trava da 117 ainda segura as outras contas).
- **Busca por nome de catálogo (P2, exigência da F2d e da F2f-2):** com nome único por conta, "ASO" ou "NR-10" pode existir em
  duas contas; toda busca por nome ou `palavras_chave` (OCR, motor) precisa filtrar a conta.
- **Herança de conta (119):** escalas (do técnico), eventos, notificações, ligações, respostas, ocorrências e aceites (da
  escala), cargas e atribuições (da empresa) e aceites de carga (da carga) recebem a conta do registro de origem num
  gatilho, venha a linha de onde vier. Pendências e alertas do motor são por conta desde a 122.
- **Herança confere uma origem por tabela (P3, F2f-2):** `escalas.local_id` e `tipo_atividade_id` e `carga_*.carga_id` contra
  `empresa_id` dependem das `app_*` (que conferem); a trava no dado (chave composta ou gatilho de coerência) entra na F2f-2.
- **Storage dos documentos (120):** a política lê a primeira pasta do caminho (`<técnico>/<arquivo>`) e exige técnico da
  conta da sessão e papel admin ou gestor nela. **Antes da produção:** conferir que todo arquivo do bucket segue o padrão
  (consulta no roteiro da produção); arquivo fora dele fica invisível no painel, não é apagado.
- **OCR (`documento-ocr`, 122):** papel na conta por `fn_papel_na_conta_de` (e-mail do token conferido e `x-conta`), sem
  mexer na sessão; conta recusada responde 403. Cota da chave do Google Vision por conta entra na F7.
- **Cabeçalho `x-conta` (F3b, painel 3.49.0):** o painel guarda a conta escolhida e manda `x-conta` em toda chamada à
  API, ao Storage e às Edge Functions (não no login). Quem tem uma conta só também manda, para o caminho ser o mesmo.
  Quem está em duas contas escolhe numa tela ao entrar e troca no topo; a troca recarrega o painel. Conta guardada que
  deixou de valer é esquecida. A prova com duas contas de verdade espera a F3d (a trava ainda impede membro fora da conta 1).
- **Login do ponto (F6):** o CPF é único no sistema inteiro, então `ponto_entrar` acha um só funcionário e a conta vem
  dele. O identificador da conta no login só é preciso quando o CPF passar a ser único por conta (mesma pessoa em dois
  clientes), junto com a unicidade da F6.
- **Motor (122):** avisos a supervisores só da mesma conta, inclusive no motor de envio (funcionário sem empresa avisa
  os supervisores da conta dele); programação de amanhã e documentos a vencer por conta, com erro de uma conta sem
  derrubar as outras; teto do app do ponto só à operadora. Lembretes, pedidos parados e PDF do espelho já avisavam só o
  próprio funcionário ou supervisores da empresa. O webhook acha o funcionário pelo telefone (único no sistema); a
  instância por conta é da F5. **Falta testar** a programação de amanhã e os documentos a vencer com duas contas e o motor
  de envio com funcionário sem empresa (P3 da revisão; F2f-2).
- **Catálogo de motivos do ponto (F3):** `ponto_motivos` segue global (mesmos motivos para todas as contas).
- **Local da marcação (121):** a referência da marcação (local da escala ou o mais perto) é só da conta da empresa; o
  local entra no hash, então nunca pode ser de outra conta. Comprovante, histórico do funcionário e acompanhamento só
  mostram local da mesma conta.
- **Pendências do ponto para a F2f-2 (revisão do `seguranca`, P3):** feriados são um calendário único (a data é a chave),
  então feriado municipal de um cliente vale para todos; `ponto_acessos` grava tentativa com CPF desconhecido sem
  funcionário (cai na conta 1, e falha quando o default sair); `alertas_enviados` já herda a conta do funcionário ou da
  empresa (122), mas o teto do ponto fica na conta 1 pelo default; instância da Evolution e `app_url` globais no envio do espelho e no aviso de código (F5).
- **Numeração única no sistema (P3, F6):** número de pedido e código de documento do ponto são sequências globais; quem vê
  o número deduz o volume das outras contas.
- **Token da URA na URL (P3, pré-existente):** `app_ligar_escala` manda `VOZ_TOKEN` na query string, que fica na fila do
  `pg_net`; passar para cabeçalho junto com a F5 (canais por conta).
- **Gatilhos que inserem em tabela de cliente (F2f-2):** o `default` da conta 1 em `conta_id` só sai na F2f-2; até lá, cada
  gatilho que cria linha precisa gravar a conta (o de time da equipe foi corrigido na 118).
- **Unicidade que avisa existência (P3, até a F6):** CPF, telefone e CNPJ continuam únicos no sistema inteiro; a mensagem
  "Já existe…" numa conta revela que o dado existe em outra.
- **`app_meu_acesso` (F3a, 124):** papel e permissões da conta da sessão, com a conta escolhida em `conta`.

- **Várias contas por usuário no Supabase Auth (P1 da estimativa):** resolvido pelo cabeçalho `x-conta`, conferido no
  banco. Falta provar no painel (F3) que o gateway da API deixa o cabeçalho passar (CORS).
- `fn_papel` (usado por `fn_exigir_papel`) lê o papel na conta da sessão desde a 124.
