# Plano comercial — v1

Escrito em 27/09/2026 pela persona **Comercial** (Diretor Comercial e Branding), com os dados que o
CTO e o PO já produziram no repositório. Substitui qualquer material de venda anterior.

**Como ler este documento**

- A **matriz de capacidade** (seção 2) é a fonte da verdade. Nenhuma frase de proposta, site ou
  conversa cita capacidade que não esteja lá, com estado.
- **Preço é hipótese** até a terceira conversa de venda. O que já é firme é o **piso de custo**
  (seção 7) e a estrutura de cobrança (seção 6).
- Três coisas **ainda faltam** para este plano fechar, e estão marcadas ao longo do texto:
  1. os itens do grupo **SaaS** do Roadmap, que vivem em `backlog_itens` na **produção** e não
     puderam ser lidos (a consulta de exportação está em `supabase/setup/backlog_seguranca_saas.sql`);
  2. o **parecer do CTO** sobre multi-empresa (seção 5);
  3. o **preço final e a política de desconto**, que são do responsável (seção 14).

---

## 1. A regra que governa este plano

**Capacidade → promessa.** Nesta ordem, nunca na inversa.

Toda afirmação comercial tem um lastro rastreável: um módulo da matriz, um item de backlog com
critério de aceite, uma decisão registrada ou uma medição. Se não tem, não entra — nem na conversa,
nem no site, nem no e-mail de follow-up.

Isso não é escrúpulo de compliance: é estratégia. O diferencial deste produto é ser **confiável
justamente onde os outros prometem demais** — e o primeiro cliente que descobre uma promessa vazia
custa mais do que os três que ele indica.

Quem veta o quê: **CTO** veta afirmação técnica que a arquitetura não sustenta; **Segurança** veta
afirmação de privacidade ou conformidade sem base; **PO** veta prazo sem item com critério de aceite;
**responsável** decide preço, SLA e risco assumido.

---

## 2. Matriz de capacidade — o que existe hoje

Estado: **entregue** (em produção) · **homologação** (pronto, faltando produção) · **não existe**.

| Módulo | O que o cliente vê | Estado | Ressalva que precisa aparecer na conversa |
|---|---|---|---|
| **Escalas e agenda** | Criar para um ou vários técnicos, editar, reagendar, substituir técnico, cancelar, status com semáforo, importar planilha | Entregue | — |
| **Confirmação por WhatsApp** | Mensagem com botões "Ciente, confirmado" / "Tenho um problema" e alternativa 1/2; reenvio a cada 30 min até 3×; escalonamento ao supervisor; janela de envio 06:00–21:00 | Entregue | **Canal não oficial** (seção 4, G1) |
| **Motivo da recusa** | Depois do "2", o técnico escolhe o motivo por número (saúde, transporte, conflito de agenda, falta de material, outro) e o detalhe por texto | Homologação (migration 47; PR #12) | Falta aplicar em produção |
| **Alerta de prazo** | Às 16h o supervisor recebe a escala do dia seguinte; às 18h, o que ficou sem resposta; lista de técnicos sem escala | Entregue | — |
| **Jornada CLT** | Término previsto calculado (8h + 1h de intervalo, adicional noturno, Súmula 60), conclusão automática 5 min após o término | Entregue | **Não é parecer jurídico**; a regra deve ser validada pelo RH (decisão 7) |
| **Habilidades e aptidão** | Catálogo, nível por técnico, requisitos por tipo de atividade; aviso de quem não atende | Entregue | O aviso **não bloqueia** a escala: quem monta decide |
| **Documentos e vencimentos** | NR, CNH e ASO com validade; arquivo em armazenamento privado com link de 2 minutos; classificação automática no envio em lote; alerta semanal de vencimento; retenção de 5 anos após o desligamento | Entregue | O expurgo dos 5 anos **não roda sozinho**; sem trilha de quem abriu; no modo Drive o controle e a retenção saem do sistema |
| **URA de voz** | Ligação automática para quem não respondeu duas mensagens, entre 08h e 20h, no máximo 2 por escala; 1 aprova, 2 nega; botão "Ligar agora" | Entregue | Assinatura da Twilio em observação; custo por ligação atendida |
| **Operação e indicadores** | Dia agrupado por local, percentual de aceite e de conclusão, recusas por motivo, mediana do tempo de resposta | Entregue | "% concluído" depende de alguém marcar a escala como concluída |
| **Usuários e papéis** | `admin`, `gestor` e `leitura`, com login por e-mail e senha e sessão que expira em 30 min de inatividade | Entregue | Sem segundo fator (MFA) |
| **Aviso de motor parado** | Aviso ao supervisor se o motor de envio parar; quadro na aba Operação | Entregue | Monitor externo (healthchecks.io) ainda não criado |

O produto **não usa** o Roadmap/backlog interno como funcionalidade de cliente — é ferramenta de
gestão do fornecedor e não entra em pacote.

---

## 3. O que não existe hoje

Esta é a lista que vira a seção **"não está incluso"** de toda proposta. Dizer isso na primeira
conversa é o que separa uma venda saudável de um problema em 90 dias.

| Não existe | Por que importa para a venda |
|---|---|
| **Multi-empresa** (um só banco, vários clientes isolados) | Hoje é uma instalação por cliente — ver seção 5 |
| **Autoatendimento** (o cliente cria a própria conta e cadastra técnicos, locais e tipos de atividade) | Implantação é feita por nós, na mão. Vira serviço cobrado, não promessa |
| **Cobrança e licenciamento** (assinatura, fatura, bloqueio por inadimplência) | Faturamento é manual |
| **Portal ou app do técnico** ("minhas escalas") | O técnico só recebe WhatsApp; não consulta histórico sozinho |
| **Checklist e laudo pelo técnico** (backlog 1) | Sem registro de execução com foto e assinatura |
| **Relatório/dossiê de conformidade exportável** | Hoje os dados estão no painel; não há PDF assinado para auditoria do cliente tomador |
| **Integrações** com chamados, almoxarifado e ponto (backlog 8, 9 e 4) | Dependem de levantamento de API que ninguém fez |
| **MFA** nas contas administrativas | Item do bloco 1 de `docs/seguranca-homologacao.md` |
| **SLA e monitoramento por cliente** | Existe alerta operacional, não contrato de disponibilidade |
| **Trilha de leitura de documento** | Não há como responder "quem abriu o ASO" |
| **IA que sugere escala / predição** (backlog 6 e 7) | Protótipo no melhor caso; não citar |

---

## 4. Os portões antes da primeira venda

Sem os quatro primeiros, **não há venda**: há risco transferido para o cliente, e a responsabilidade
volta para quem vendeu.

| Portão | O que é | Fonte | Dono |
|---|---|---|---|
| **G1 · Canal oficial do WhatsApp** | A Evolution API usa o WhatsApp de forma não oficial e viola os termos da Meta. Para uso interno é risco aceito (decisão 33); **vendendo a terceiros, o número que pode ser bloqueado é o do cliente** | `docs/seguranca-homologacao.md` (bloqueio principal) | Responsável |
| **G2 · Painel fora do plano gratuito** | O plano Hobby da Vercel proíbe uso comercial. Cloudflare Pages é gratuito e permite (decisão 6, decisão 29, etapa 17) | `docs/decisoes.md` | Responsável |
| **G3 · Contrato e tratamento de dados** | Ao vender, a Infoxtec passa a **operar** dados pessoais de terceiros — inclusive dado de saúde (ASO). Faltam contrato com anexo de tratamento, inventário, prazos, canal do titular e plano de incidente | `docs/seguranca-homologacao.md` (bloco 2) | Responsável + Segurança |
| **G4 · Multi-empresa** | Decide se cada cliente é um projeto separado ou um cliente dentro do mesmo sistema (seção 5) | este documento, §5, + CTO | CTO |
| **G5 · Preço** | Publicar tabela depois da terceira conversa; antes disso, proposta sob medida | seção 7 | Responsável |

**G1 é o caminho crítico.** A migração para a API oficial está estimada em **R$ 8 a R$ 11 por mês no
volume atual** (decisão 3) e resolve o risco de banimento. Enquanto ela não acontece, a única forma
honesta de vender é com o risco **escrito no contrato** e assumido pelo cliente — o que é possível,
mas encarece a conversa e estreita o mercado.

---

## 5. Multi-empresa: a decisão que o Comercial precisa do CTO

Hoje o sistema é **single-tenant**: um projeto Supabase, um painel, uma instância de WhatsApp. Três
clientes significam três instalações — com o custo fixo e a operação multiplicados.

| Opção | Como funciona | A favor | Contra |
|---|---|---|---|
| **A · Uma instalação por cliente** | Um projeto Supabase e um painel por cliente | Isolamento máximo; atende exigência contratual de "dados separados" | O plano gratuito permite só **dois projetos**; a partir do terceiro, custo por cliente; cada cliente é uma migração manual; o motor, o painel e as correções passam a ser replicados N vezes |
| **B · Multi-empresa no mesmo sistema** | Coluna `empresa_id` e isolamento por papel/política, um motor, um painel, um roadmap | Uma evolução serve todos; preço por assento fica sustentável; operação de suporte única | Migration estrutural grande, revisão de segurança obrigatória, risco de vazamento entre clientes se a política falhar |
| **C · Híbrido** | Cliente pequeno no sistema compartilhado; cliente grande isolado, com preço maior | Atende os dois discursos | Duas linhas de produto para manter e testar |

**Recomendação do Comercial:** **B**, com **A** como exceção contratual paga (cliente que exija
isolamento físico). Motivo comercial: preço por assento só fecha com custo fixo diluído; e a
evolução do produto — que é o principal ativo aqui — não pode ser replicada à mão por cliente.

**O que o Comercial precisa do CTO:** estimativa de esforço em semanas, risco de segurança e o que
muda no preço se a opção A for a escolhida.

---

## 6. A unidade de cobrança

Três unidades, porque há três coisas diferentes sendo compradas:

| Unidade | O que é | Por que é ela |
|---|---|---|
| **Assento de gestão** | Usuário que opera o painel (`admin`, `gestor`, `leitura`) | É quem usa o sistema todo dia; escala com o tamanho da operação do cliente |
| **Técnico ativo** | Quem recebe escala e responde | É onde está o valor (a confirmação) e onde está o custo variável (mensagem e ligação) |
| **Implantação** | Cadastro de técnicos, locais, tipos de atividade, modelos de documento, treinamento e acompanhamento do primeiro ciclo | Hoje não há autoatendimento: a implantação é trabalho real e precisa ser paga, não dada de brinde |

Duas decisões de desenho que a prática costuma errar:

- **Mínimo mensal:** sem ele, um cliente com 3 técnicos não paga nem o custo fixo do próprio
  ambiente.
- **Técnico ativo, não cadastrado:** cobra-se quem está apto a receber escala. Cadastro inativo não
  gera custo nem valor — e cobrar por ele quebra a confiança na renovação.

**Serviços e consumo, fora da assinatura:** ligação da URA (custo por ligação atendida, hoje
**R$ 0,24**), leitura de documento na nuvem quando ligada (cota gratuita do Google Vision: 1.000
páginas por mês) e treinamento adicional.

---

## 7. Piso de custo e a conta que fecha

O que eu consigo afirmar com os números do próprio projeto:

| Item | Custo | Origem |
|---|---|---|
| WhatsApp oficial (quando migrar) | **R$ 8 a R$ 11 por mês no volume atual** (≈ 13 técnicos) → **≈ R$ 0,60 a R$ 0,85 por técnico ativo/mês** | decisão 3 |
| Ligação da URA | **R$ 0,24** por ligação atendida de 40 s | `docs/telefonia.md` |
| Banco de dados | 199 MB por ano com 200 técnicos e 52 mil escalas; o limite de 500 MB do plano gratuito chega em ~2,5 anos nesse volume | `docs/analise-global.md` |
| Arquivos de documento | Limite de 8 MB por arquivo; 1 GB no plano gratuito. Estimativa: 4 arquivos por técnico a ~3 MB = ~12 MB por técnico → **~80 técnicos por GB** | `supabase/setup/documentos.md` |
| Painel | Vercel Hobby **não pode**; Cloudflare Pages gratuito pode | decisão 6 / etapa 17 |
| Backup | GitHub Actions, gratuito, 30 dias | `docs/operacao.md` |
| VPS da Evolution | valor **não está no repositório** — pendência a levantar | — |

**A conclusão que orienta o preço:** o custo variável por técnico é da ordem de **R$ 1,50 a R$ 2,00
por mês** (mensagem + uma ligação eventual). Isso é quase nada. **A conta não fecha nem deixa de
fechar no variável — fecha no custo fixo por cliente e no tempo de implantação e suporte.** Por
isso:

1. mínimo mensal existe;
2. implantação é cobrada;
3. preço por técnico ativo é quase todo margem, e serve para crescer a conta dentro do cliente;
4. o que precisa de escala é o número de **clientes**, não o de técnicos.

Sem essa leitura, o erro clássico é dar desconto no mínimo mensal para ganhar o cliente e ficar
sustentando infraestrutura e suporte no prejuízo.

---

## 8. Pacotes (estrutura firme, valores em hipótese)

**Modular, por usuário, mensal** — como pedido. A estrutura abaixo é proposta; os valores só se
publicam depois da terceira conversa de venda.

| Pacote | Para quem | Inclui | Unidade |
|---|---|---|---|
| **Essencial** | Quem só precisa parar de confirmar escala por telefone | Escalas e agenda, confirmação por WhatsApp com botões e 1/2, lembretes de 30 min, escalonamento ao supervisor, alerta de 16h/18h, operação do dia por local | Técnico ativo + mínimo mensal; 2 assentos de gestão inclusos |
| **Conformidade** | RH, BPO e construção, com auditoria e fiscalização | Tudo do Essencial + documentos (NR, CNH, ASO) com vencimento e alerta semanal, habilidades, requisitos por tipo de atividade, aviso de inaptidão | Técnico ativo + assento de gestão |
| **Completo** | Operação que quer reduzir não-resposta a quase zero | Tudo do Conformidade + URA de voz (cobrada por ligação) + indicadores de recusa e tempo de resposta | Idem + consumo de ligação |
| **Implantação** | Todos | Carga de técnicos, locais e tipos de atividade, configuração de documentos e jornada, treinamento e acompanhamento do primeiro ciclo | Valor único, por escopo |
| **Assento extra** | — | Usuário de painel adicional | Assento de gestão/mês |

**Hipóteses de valor** (a testar, sem fonte de mercado — ver seção 15): mínimo mensal na casa de
poucas centenas de reais; técnico ativo na casa de unidades de reais por mês, com faixas
decrescentes por volume; implantação na casa de um a três meses de assinatura. **Não publicar antes
de testar.** O método de teste está na seção 10.

---

## 9. ICP, dor e mensagem

### 9.1 Empresas de RH e BPO de serviços com equipe de campo — meta: 3 em 2026

**Quem é:** empresa que aloca pessoal em campo para terceiros — limpeza, portaria, manutenção,
facilities, conservação, vigilância. Tem dezenas a centenas de trabalhadores, alta rotatividade e
contratos com o cliente tomador que preveem conformidade documental.

**A dor, em ordem de valor:**
1. **No-show e confirmação por telefone.** Supervisor liga um a um; quem não confirma simplesmente
   não aparece, e o cliente tomador cobra.
2. **Conformidade na auditoria.** ASO, NR e CNH vencidos geram glosa, multa e risco de
   responsabilidade solidária. Hoje o controle é planilha.
3. **Prova de que o trabalhador foi avisado.** Numa reclamação trabalhista, "eu avisei" sem registro
   não vale. Aqui vale: horário de envio, entrega, leitura e resposta ficam gravados.
4. **Substituição rápida** quando alguém recusa, sem perder o posto.

**Por que nós:** o trabalhador não instala aplicativo, não cria login, não aprende nada — responde no
WhatsApp que ele já usa. É o que faz a adoção ser imediata, e é o que ferramenta com app próprio não
consegue em operação de campo com rotatividade alta.

**Ressalva honesta:** este produto **não é sistema de ponto** e não deve ser vendido como tal. O
backlog 4 (`docs/backlog.md`) já registra que bloquear registro de ponto por falta de aceite cria
passivo trabalhista. Se o cliente quiser conciliação de ponto, isso é projeto, não módulo.

### 9.2 Construtoras — meta: 1 até 30/12/2026

**Quem é:** construtora com canteiro ativo, equipe própria e subcontratada, fiscalização e
auditoria de segurança do trabalho.

**A dor:**
1. **NR-18, NR-35, NR-10 e ASO no canteiro.** Documento vencido é interdição e autuação.
2. **Comprovar que a equipe foi avisada** da tarefa, do horário e do local — vale na fiscalização e
   na defesa jurídica.
3. **Escala de frentes de serviço** com troca constante por chuva, atraso de material e
   remanejamento.

**Por que nós:** conformidade documental com alerta antes do vencimento + registro da comunicação +
substituição rápida. O discurso é de **risco evitado**, não de produtividade.

### 9.3 O que perguntar na descoberta (para quantificar a dor)

Sem isso a proposta vira preço por feature. Com isso, vira conta:

- Quantos trabalhadores de campo e quantos supervisores?
- Quantas horas por dia o supervisor gasta confirmando escala?
- Quantos no-show por mês e qual o custo de cada um (hora extra, remanejamento, glosa)?
- Já houve glosa, multa ou autuação por documento vencido? De quanto?
- Quantas reclamações trabalhistas envolvendo "não fui avisado"?
- Quem assina, quem usa e quem paga?

---

## 10. Roteiro até 30/12/2026

| Período | O quê | Critério de saída |
|---|---|---|
| **Outubro** | G1, G2 e G3 decididos pelo responsável. 10 conversas de descoberta (6 RH/BPO, 2 construtora, 2 indicações). Demo com dados fictícios na homologação | Decisão sobre o canal oficial registrada; 10 conversas feitas; dor quantificada em pelo menos 4 |
| **Novembro** | 3 propostas em modelo **piloto pago** (60 a 90 dias, escopo fechado, termo assinado, preço de entrada). Implantação assistida de 2 clientes. Marca e site no ar | 3 pilotos assinados; 2 implantações concluídas; material comercial com lastro conferido |
| **Dezembro** | Converter 2 pilotos em contrato de 12 meses. Fechar 1 construtora. Levantar o custo real de operação por cliente | 1 construtora assinada; 2 contratos de 12 meses; 3 clientes de RH ativos |

**A verdade sobre a meta de RH.** "3 empresas de RH ainda em 2026" é alcançável em **piloto pago**;
como contrato anual, depende de G1–G3 resolvidos em outubro. Se o canal oficial não for decidido
até o fim de outubro, o caminho honesto é: três pilotos pagos com o risco do canal escrito no termo,
e conversão em 2027. Vender como contrato anual com canal não oficial é transferir para o cliente um
risco que é nosso — e é o tipo de venda que o Comercial tem o dever de recusar.

A meta da construtora tem data firme e **não depende** de multi-empresa se for uma instalação
dedicada (opção A).

---

## 11. Árvore de mensagem — o que dizemos e o que não dizemos

### Como construímos cada frase

| Camada | Papel | Exemplo |
|---|---|---|
| **Promessa** | O que o cliente ganha, em uma frase | "Você sabe em minutos quem vai estar em cada posto amanhã." |
| **Prova operacional** | O mecanismo, concreto | "O técnico recebe no WhatsApp com dois botões; sem resposta, o sistema reenvia a cada 30 minutos, até três vezes, e avisa o supervisor." |
| **Prova técnica** | O lastro, quando o cliente perguntar | "O registro fica gravado com horário de envio, entrega, leitura e resposta." |

### O que **não** dizemos

| Não dizemos | Dizemos |
|---|---|
| "Somos certificados ISO 27001" | "Hospedado em infraestrutura com ISO/IEC 27001 e SOC 2; o controle de acesso por papel, a criptografia e a trilha de auditoria são do produto" (`docs/seguranca.md`) |
| "Garantimos disponibilidade" / SLA sem contrato | "Existe aviso automático quando o motor de envio para e um plano de contingência manual documentado. SLA formal não está contratado" |
| "100% conforme à LGPD" | "Controle de acesso por papel, retenção definida para documentos, exclusão a pedido e trilha de auditoria. O que depende do contratante está no anexo de tratamento" |
| "Jornada CLT garantida" | "Cálculo parametrizado e auditável; a validação jurídica é do RH do cliente" (decisão 7) |
| "Plataforma completa de gestão de campo" | "Escalas, confirmação, conformidade documental e indicadores. Não fazemos ponto, checklist nem laudo hoje" |
| "Funciona com qualquer número" | "Cada cliente usa um número dedicado; o canal atual é o WhatsApp Web automatizado e a migração para a API oficial está em curso" |

**Regra de ouro da proposta:** toda proposta tem a seção **"O que não está incluso"** com os itens da
seção 3 que o cliente poderia razoavelmente esperar. A surpresa em 90 dias custa mais que a venda
perdida em 30.

---

## 12. Riscos comerciais

| Risco | Efeito | Mitigação |
|---|---|---|
| **Bloqueio do número (G1)** | Cliente sem operação; dano reputacional e jurídico | Migrar para a API oficial antes de escalar; enquanto isso, piloto com risco escrito |
| **Plano gratuito (G2)** | Uso comercial vedado; sem backup nativo; limites de armazenamento | Migrar o painel para Cloudflare Pages; avaliar plano pago do Supabase com a receita |
| **LGPD como operador (G3)** | Multa, incidente, rescisão | Contrato com anexo, inventário, retenção, canal do titular, plano de incidente |
| **Gargalo de uma pessoa** | Suporte e implantação não escalam; 4 clientes saturam o responsável | Implantação paga e padronizada; documentação de operação; roteiro de suporte antes do 3º cliente |
| **Dependência de terceiros** | Evolution (VPS de terceiro), Twilio, Google Vision, Supabase, Cloudflare | Registrar cada um como operador no anexo de tratamento |
| **Concorrência estabelecida** | Provedores de gestão de campo com mais telas e mais tempo de mercado | Não competir por amplitude: competir por adesão (sem app) e por conformidade documental |
| **Promessa que a operação não sustenta** | Churn no primeiro ano, indicação negativa | A regra do lastro (seção 1) e o veto das personas |

---

## 13. Backlog comercial — o que o Comercial pede ao PO e ao CTO

Cada item abaixo é um pedido formal, para o PO transformar em item com critério de aceite e o CTO
opinar sobre viabilidade. Ordenados por impacto na receita.

| # | Item | Por que o comercial precisa | Prioridade |
|---|---|---|---|
| 1 | **Multi-empresa** (`empresa_id`, isolamento e papéis por cliente) | Sem isso, cada cliente é uma instalação e o preço por assento não fecha (§5) | P0 |
| 2 | **Relatório/dossiê de conformidade** (por obra, posto ou cliente tomador; PDF com validade dos documentos e registro das comunicações) | É o que o RH entrega ao cliente tomador e o que a construtora mostra na fiscalização. Vende sozinho | P0 |
| 3 | **Trilha de leitura de documento** (quem abriu, quando, qual) | Pergunta obrigatória em questionário de segurança de qualquer cliente médio | P1 |
| 4 | **MFA** para administradores | Bloco 1 de segurança; trava venda para cliente maior | P1 |
| 5 | **Portal do técnico** ("minhas escalas", confirmação fora do WhatsApp) | Reduz dependência do canal e atende cliente que não quer WhatsApp | P1 |
| 6 | **Administração de contas** (painel do fornecedor: clientes, limites, status) | Sem isso a operação de 3 a 5 clientes é manual e some | P1 |
| 7 | **Cobrança e assinatura** (fatura mensal, histórico, bloqueio por inadimplência) | Faturamento manual não escala além de 5 clientes | P2 |
| 8 | **Expurgo automático dos documentos** (o prazo de 5 anos não roda sozinho) | Prometemos retenção; hoje ela é declaração | P2 |
| 9 | **Checklist e laudo pelo técnico** (backlog 1) | Aumenta o valor por técnico e abre o discurso de execução, não só de aceite | P2 |
| 10 | **SLA e monitoramento por cliente** | Só quando houver contrato que exija | P3 |

Os itens 1 a 4 já estão, em parte, nos grupos **Segurança** e **SaaS** do Roadmap na produção —
que eu **não li** (seção 15). A reconciliação é o primeiro passo do PO ao aceitar esta lista.

---

## 14. Decisões que só o responsável toma

1. **Migrar para a API oficial do WhatsApp?** Se sim, em que data. É o caminho crítico de tudo.
2. **Preço:** valor do mínimo mensal, do técnico ativo e da implantação; política de desconto.
3. **Multi-empresa (B) ou uma instalação por cliente (A)?** Custo fixo contra isolamento.
4. **Aceitar vender em piloto com o canal atual**, com o risco escrito no termo?
5. **Plano pago do Supabase** quando o gratuito não sustentar (rompe a decisão 29).
6. **Marca:** aprovar o nome e a identidade (seção de marca em `docs/marca.md`).
7. **Quem atende o cliente** depois da venda — suporte, prazo de resposta e o que é gratuito.
8. **Os 3 RH são usuários finais ou canal/revenda?** Muda o desenho todo: se for revenda, o produto
   precisa de marca própria e de um painel de parceiro, e o preço passa a ser por volume.

---

## 15. Fontes, limites e o que falta

**Fontes usadas:** `docs/arquitetura.md`, `docs/banco-de-dados.md`, `docs/decisoes.md`,
`docs/backlog.md`, `docs/seguranca.md`, `docs/seguranca-homologacao.md`, `docs/operacao.md`,
`docs/telefonia.md`, `docs/analise-global.md`, `docs/plano-de-trabalho.md`,
`supabase/setup/documentos.md`, `supabase/setup/backlog_seguranca_saas.sql`, e as 48 migrations.

**Limites declarados (não verifiquei):**

1. **Itens do grupo SaaS do Roadmap** — vivem em `backlog_itens` na produção e não foram lidos.
   Enquanto isso, esta lista da seção 13 pode duplicar ou contrariar itens que já existem.
2. **Preço de mercado** — não obtive benchmark público verificável de concorrentes brasileiros de
   gestão de campo (a página de preços consultada não estava disponível). Os valores da seção 8 são
   hipótese, não referência de mercado. Um levantamento com fonte é o próximo passo natural, e não
   foi feito.
3. **Custo da VPS da Evolution** não está no repositório.
4. **Titularidade do domínio `evo.vluma.com.br`**, usado como endereço da Evolution, não está
   documentada — relevante para o anexo de tratamento de dados.
5. Disponibilidade de nome e domínio: foi feito apenas um teste de DNS, que **não é prova** de
   disponibilidade (ver `docs/marca.md`).
