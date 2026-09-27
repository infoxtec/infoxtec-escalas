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
| Grupo SaaS | criado pela migration 38, ~15 itens | **não lido** — só existe na produção |
| Roteiro de IA | `docs/agente-ia.md` (fases 0 a 4) | lido |
| Fila de trabalho | `docs/plano-de-trabalho.md` (25 etapas + pendências) | lido |

**Para esta análise ficar 100%**, falta exportar o grupo SaaS. A consulta está pronta em
`supabase/setup/backlog_seguranca_saas.sql`; basta rodá-la no SQL Editor da produção e me passar o
resultado. Enquanto isso, a seção 4 deste documento cobre o que é legível.

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

**Filhos propostos** (só entram no quadro com a sua autorização — cada um vira item próprio):

| # | Item proposto | Grupo | Prioridade |
|---|---|---|---|
| a | Dossiê de conformidade exportável (por obra, posto ou cliente tomador) | `saas` | P0 |
| b | RBAC com escopo por equipe e entitlement por módulo | `saas` | P0 |
| c | Registro de acesso a documento (quem abriu, quando, qual) — dentro do item 015 | `backlog` | P1 |
| d | Administração de contas (painel do fornecedor: clientes, limites, status) | `saas` | P1 |
| e | Cobrança e assinatura (fatura, histórico, bloqueio por inadimplência) | `saas` | P2 |
| f | Página do produto e materiais de venda em `infoxtec.com.br/trilha` | `saas` | P1 |
| g | Retenção por tipo de documento e expurgo automático | `seguranca` | P1 |

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

1. **Exportar o grupo SaaS** da produção (`supabase/setup/backlog_seguranca_saas.sql`) — sem ele, a
   seção 4 pode duplicar itens que já existem, e parte deste documento fica incompleta.
2. **Atualizar no quadro** os itens da seção 2 (status, `entregue_em`, observação).
3. **Reescrever o item 1 do grupo `seguranca`** conforme a decisão 33.
4. **Decidir** os quatro pontos da seção 3.4.
