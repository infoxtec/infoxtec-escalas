# Análise do backlog — 27/09/2026

Revisão consolidada de **tudo o que o repositório sabe sobre o backlog**, feita pela persona
**Comercial** com apoio do que já está em `docs/backlog.md`, `docs/seguranca-homologacao.md`,
`docs/plano-de-trabalho.md`, `docs/agente-ia.md`, `supabase/setup/backlog_seed.sql` e nas migrations
38, 42 e 43.

## 0. Onde o backlog vive — e o limite desta análise

| Camada | Onde | Estado |
|---|---|---|
| **O quadro** (o que é real) | tabela `backlog_itens`, **na produção**, exibida na aba Roadmap | **não lido** — produção é intocável fora da exceção de registro |
| Análise de viabilidade | `docs/backlog.md` (itens 1 a 16, 064 e 065) | lido |
| Carga inicial | `supabase/setup/backlog_seed.sql` | lido — **é de 26/09 e não é o estado atual** |
| Itens de documento | migration 42 (itens numerados a partir do maior) | lido |
| Grupo segurança e homologação | `docs/seguranca-homologacao.md` (17 itens) | lido |
| Grupo SaaS | criado pela migration 38 — **15 itens**, exportados da produção em 27/09 | **lido** — ver seção 4 |
| Roteiro de IA | `docs/agente-ia.md` (fases 0 a 4) | lido |
| Fila de trabalho | `docs/plano-de-trabalho.md` (25 etapas + pendências) | lido |

**A exportação chegou em 27/09** (itens de `saas` e os primeiros de `seguranca`, por ordem): com ela
esta análise cobre os cinco grupos. O que ainda não tenho são os **números** dos demais itens de
`seguranca` — o conteúdo deles está em `docs/seguranca-homologacao.md`, e só cinco apareceram na
exportação.

**Aviso de processo:** o quadro real está na produção e o repositório **não o espelha**. Duas
consequências práticas: (a) o `supabase/setup/backlog_seed.sql` não deve ser usado como estado
(seção 3.1); (b) uma análise feita só pelo repositório erra por omissão — foi o que aconteceu com a
seção 4 deste documento antes desta exportação.

## 1. Como o quadro funciona hoje

- Grupos: `backlog` (produto), `entrega`, `divida`, `seguranca`, `saas`.
- **Número obrigatório, único e atribuído pelo banco** em sequência única (migration 43). Quem cria
  não escolhe, e o número não muda depois — atualizar um item é editar o item, nunca criar outro.
- Ver `supabase/setup/backlog_grupos.sql`: a reclassificação de grupos só pode rodar **depois** de o
  painel que conhece os grupos estar publicado (decisão 24).

## 2. Inventário — o que está pronto e não está marcado

O seed e a análise envelheceram: vários itens constam como "planejado" e já estão **em produção**.
Esta é a lista do que precisa ser **atualizado no quadro**, não recriado:

| Item | Título | Estado real |
|---|---|---|
| 002 | URA de voz | entregue em 23/09 e testada em produção; falta **ligar a assinatura da Twilio** (etapa 12) |
| 003 | Painel por local e % de conclusão | entregue em versão parcial; o % real depende do item 001 |
| 005 | Habilidades e certificações | entregue (virou habilidades **e** documentos nas migrations 36 e 37) |
| 010 | Upload de documentos com OCR | entregue em 24/09 |
| 011 | Perfil de teste para técnicos | entregue em 24/09 |
| 012 | Indicadores clicáveis na Agenda | entregue em 24/09 |
| 013 | Submenu da Agenda | entregue em 24/09 |
| 064 | Motivo de recusa estruturado | **pronto na homologação** (migration 47 + painel 3.5); falta produção |
| 065 | Editar e reagendar escala | **pronto na homologação**; falta produção |
| dívida | Desligar o painel Retool | **feito em 27/09** (senha trocada, conexão apagada) |
| dívida | Remover funções da bancada de teste | **feito na migration 45** (`fn_teste_wa_*`) |
| dívida | Consolidar o repositório do Vercel | **sem confirmação** no repositório — verificar |

## 3. Achados da revisão

### 3.1 O seed não é o estado, e ninguém deve planejar por ele

`backlog_seed.sql` é carga inicial: marca como `planejado` o que já foi entregue e traz dívidas já
pagas. **A fonte da verdade é a tabela na produção.** Recomendação: substituir o seed por um
`backlog_estado.sql` gerado a partir da produção (a própria consulta de exportação serve), ou marcar
o arquivo como histórico no cabeçalho.

### 3.2 Duplicidades reais entre os documentos

| Duplicidade | Onde | Ação |
|---|---|---|
| "Trilha de leitura de documento" (§13.3 do plano comercial) = **item 015** (pré-visualização e download com aviso de LGPD) | `docs/plano-comercial.md` §13 × `docs/backlog.md` item 15 | manter **um** item: o registro de acesso nasce dentro do item 015, não como item novo |
| Integração com ponto **VRmais** (item 004) e o módulo **Ponto (M3)** (§15.2) | `docs/backlog.md` item 4 × `docs/plano-comercial.md` §15 | são o mesmo território: o item 004 vira o ramo "conciliar" do M3; a decisão regulatória (G6) vem antes |
| Itens 014 e 015 se sobrepõem ao 010 (já entregue) | `docs/analise-global.md` já apontou | confirmar no quadro e ajustar a descrição |

### 3.3 Colisão de nome com o produto

O termo **"trilha de leitura de documento"** passa a competir com o nome do produto **Trilha**.
Renomear para **"registro de acesso a documento"** em todo material — e o mesmo cuidado vale para
"trilha de auditoria", que deve ser escrita como "histórico de auditoria" quando estiver ao lado da
marca.

A exportação de 27/09 confirmou o problema: o grupo `seguranca` já tem um item chamado
**"Trilha de auditoria exportável" (nº 018)**. Renomear para **"Histórico de auditoria exportável"**
antes de a marca Trilha aparecer no painel, senão o produto e o item passam a se chamar igual.

### 3.4 Itens bloqueados por **decisão**, não por técnica

Estes não andam com esforço de desenvolvimento; andam com uma resposta sua:

| Item | O que falta decidir |
|---|---|
| 004 (VRmais) e M3 (ponto) | REP-P próprio, integração com homologado, ou fora do escopo (G6) |
| 014 (identificação automática do documento) | o CPF entra no cadastro? Depende do aviso de privacidade (decisão 32) |
| 016 (classificação obrigatória) | quem vê suspensão e advertência; CNH continua como categoria |
| 006 e 007 (IA) | nada a decidir agora: dependem de volume de dados (a fase 0 já foi feita) |
| 008 e 009 (integrações) | levantamento da API, que é terceiro — não é dev nosso |

### 3.5 O grupo `seguranca` tem um item que contradiz a decisão 33

O **item 1 do bloco 1** ("migrar o WhatsApp para a API oficial da Meta") está como primeira tarefa,
mas a **decisão 33** (27/09) decidiu manter a Evolution e tirou a migração do plano. O item precisa
ser reescrito para o que de fato ficou: **mitigar** (monitor externo, avisos técnicos, contingência
manual) — ou fechado como "decidido: não migrar". Do jeito que está, o quadro contradiz a decisão
registrada.

### 3.6 Itens sem critério de aceite

006, 007, 008, 009, 014 — apontado em `docs/analise-global.md`. Sem critério testável, não entram em
sprint: viram conversa.

### 3.7 O que já foi feito e não aparece no quadro

- **Fase 0 do agente de IA** (`docs/agente-ia.md`): motivo de recusa estruturado e tempo de resposta
  — entregue na migration 47, pendente de produção. É o pré-requisito de tudo que vem depois.
- Correções de segurança das Edge Functions, CI, backup diário, xlsx, Retool — etapas 11 a 14, 16 e
  18 do plano de trabalho, concluídas.

## 4. O Plano Diretor Comercial

**Pedido do responsável em 27/09: incluir o Plano Diretor Comercial no backlog.**

Definição do item (guarda-chuva, grupo `saas`):

| Campo | Conteúdo |
|---|---|
| **Título** | Plano Diretor Comercial do Trilha |
| **Descrição** | Guarda-chuva comercial do produto: posicionamento e marca, pacotes e preço, materiais de venda, funil e metas (3 empresas de RH em 2026 e 1 construtora até 30/12/2026), contrato com anexo de LGPD e publicação em `infoxtec.com.br/trilha`. Base em `docs/plano-comercial.md` e `docs/marca.md`. |
| **Tipo** | `saas` |
| **Status** | `planejado` |
| **Esforço** | `M` |
| **Depende de** | Portões G1, G2 e G3 |
| **Observação** | Item-pai dos módulos comerciais: dossiê de conformidade, registro de acesso a documento, RBAC com escopo, cobrança e administração de contas |

**Filhos propostos** — **reconciliados** com o grupo SaaS depois da exportação (ver 4.1 e 4.2):

| # | Item proposto | Situação real | Ação |
|---|---|---|---|
| a | Dossiê de conformidade exportável (por obra, posto ou cliente tomador) | parcial: **018** (histórico de auditoria exportável) e **047** (exportação e exclusão de dados do cliente); o recorte por obra/posto **não existe** | manter, como filho do 018 |
| b | RBAC com escopo por equipe e entitlement por módulo | **não existe** — o **029** isola empresas, não áreas dentro da mesma empresa | manter, P0 |
| c | Registro de acesso a documento | dentro do item **015** | não criar item novo |
| d | Administração de contas | **já é o item 034** (painel do operador do SaaS) | retirar |
| e | Cobrança e assinatura | **já é o item 036** (planos, limites e cobrança), com **019** (medição de uso) | retirar |
| f | Página do produto e materiais de venda em `infoxtec.com.br/trilha` | **não existe** | manter, dentro do Plano Diretor |
| g | Retenção por tipo de documento e expurgo automático | **não existe** (o 047 exclui dado a pedido, não expurga por prazo) | manter, P1 |

### 4.1 O grupo SaaS, agora conhecido

Os 15 itens, com os números reais da produção:

| Nº | Item | O que significa para o plano comercial |
|---|---|---|
| 017 | Cadastro e onboarding da empresa cliente | o autoatendimento **está planejado** — a seção 3 do plano comercial diz "não existe hoje", o que continua verdade, mas já tem item |
| 019 | Medição de uso por cliente | é o que torna possível cobrar por técnico ativo e por assento |
| 023 | WhatsApp por cliente na API oficial | **é o portão G1**, já com item — falta a decisão |
| 029 | Multi-tenant: isolar dados por empresa | é a opção B da seção 5 do plano comercial |
| 030 | Validar preço e modelo com 3 clientes piloto | **é a metade de preço do Plano Diretor Comercial** |
| 032 | Observabilidade: erros, métricas e traços | cobre parte do bloco 2 de segurança (monitoramento) |
| 034 | Painel do operador do SaaS | administração de contas do fornecedor |
| 036 | Planos, limites e cobrança | cobrança e assinatura |
| 040 | Marca do cliente no painel (white-label) | responde à pergunta 8 da seção 14 do plano comercial: se os RH forem revenda, o item já existe |
| 042 | Fila de envio com limites por número | mitigação direta do risco de banimento |
| 044 | Central de ajuda e página de status | suporte de primeiro nível |
| 047 | Exportação e exclusão de dados do cliente | **é o canal do titular do G3** — o lado do cliente, não o do técnico |
| 048 | API pública e webhooks para clientes | integrações de terceiros |
| 055 | CI/CD com testes e migrations versionadas | sobrepõe as etapas 14 e 15 do plano de trabalho |
| 058 | Suporte estruturado com SLA | o SLA que a seção 13 do plano comercial propunha como item novo |

Os cinco itens de `seguranca` que vieram na exportação completam o bloco 3 de
`docs/seguranca-homologacao.md`: **018** (histórico de auditoria exportável), **031** (rotação e
inventário de segredos), **049** (contrato, termo de uso e SLA), **052** (validação jurídica da
jornada CLT) e **056** (revisão formal de RLS e permissões).

### 4.2 O que isso muda no Plano Diretor Comercial

O item guarda-chuva **não duplica o 030**: ele **consolida**, com o 030 como a parte de preço.
Depende, na prática, de **023** (canal), **029** (isolamento), **047** (LGPD do cliente) e **058**
(SLA) — quatro itens que já existem no quadro e que não podem ser tratados como trabalho novo.

## 5. Fila recomendada

Consolida o plano de trabalho, o plano comercial e este backlog em uma ordem só:

| Ordem | O quê | Por quê nesta posição |
|---|---|---|
| 1 | **Produção das migrations 47 e 48 + painel 3.5** (etapas 24 e 25) | está pronto na homologação e é o que destrava indicadores e edição de escala |
| 2 | **G1, G2 e G3** (canal, painel fora do plano gratuito, contrato de tratamento) | sem eles não há venda a terceiros |
| 3 | **RBAC com escopo** e módulos | é o pedido central: RH, Operações e gestor na mesma base |
| 4 | **Retenção por tipo de documento** e expurgo | prometido e não executado; é débito legal do módulo de documentos |
| 5 | **Dossiê de conformidade** e **registro de acesso a documento** (item 015) | o que mais vende e o que todo questionário de segurança pergunta |
| 6 | **M3 (ponto)** — decidir com o jurídico antes | maior risco regulatório do roadmap |
| 7 | **Plano Diretor Comercial** e seus filhos | organiza a operação comercial das metas |
| 8 | **M4**: Kanban → Gantt → Curva S | nesta ordem, e Gantt/Curva S só com cliente pagante |
| 9 | **Fase 1 do agente de IA** (assistente de consulta) | funciona com os dados de hoje; fases 3 e 4 dependem de volume |
| 10 | **Integrações 008, 009 e 004** | dependem de levantamento de API de terceiros |

## 6. O que falta para fechar a análise

1. ~~Exportar o grupo SaaS~~ — **feito em 27/09** (seção 4.1). Faltam apenas os **números** dos 12
   itens de `seguranca` que não vieram na exportação, para citá-los por número no quadro.
2. **Confirmar se o Plano Diretor Comercial entrou no quadro.** O `INSERT` foi entregue, mas não
   tenho acesso à produção para verificar: conferir na aba Roadmap ou com
   `select numero, tipo, titulo from backlog_itens where titulo ilike '%Plano Diretor%'`. Se entrou
   com `ordem = 500`, ele aparece **no meio do grupo `seguranca`** (que ocupa de ~400 a 560) e não
   junto dos itens de SaaS (600 a 740) — ajustar `ordem` para 750 se quiser agrupado.
3. **Atualizar no quadro** os itens da seção 2 (status, `entregue_em`, observação) — e lembrar que
   **número não muda**: é edição do item, nunca criação de outro.
4. **Renomear dois itens** por causa da marca Trilha: **018** ("Trilha de auditoria exportável" →
   "Histórico de auditoria exportável") e o termo "trilha de leitura de documento" no material.
5. **Reescrever o item 1 do grupo `seguranca`** conforme a decisão 33.
6. **Decidir** os quatro pontos da seção 3.4.
7. **Registrar sem duplicar**: o `INSERT` avulso não tem trava. Usar sempre a forma guardada
   (`insert ... select ... where not exists (select 1 from backlog_itens where titulo = ...)`), como
   faz a migration 42.
