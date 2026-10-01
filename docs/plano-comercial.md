# Plano comercial — Trilha (v1)

Escrito em 27/09/2026 pela persona **Comercial** (Diretor Comercial e Branding), com os dados que o
CTO e o PO já produziram no repositório. Substitui qualquer material de venda anterior.

**Produto:** Trilha · *Trilha. O caminho para o sucesso.* — nome, narrativa e identidade em
[`docs/marca.md`](marca.md).
**Empresa:** Infoxtec Tecnologia e Serviços Ltda — CNPJ 04.309.223/0001-96, EPP, lucro presumido.
**Endereço do produto:** `www.infoxtec.com.br/trilha`.

**Como ler este documento**

- A **matriz de capacidade** (seção 2) é a fonte da verdade. Nenhuma frase de proposta, site ou
  conversa cita capacidade que não esteja lá, com estado.
- **Preço é hipótese** até a terceira conversa de venda. O que já é firme é o **piso de custo**
  (seção 7) e a estrutura de cobrança (seção 6).
- **A seção 15 é nova e muda o desenho do produto:** em 27/09 o escopo passou de "escala" para
  **plataforma da jornada do recurso** — ponto, documentos, escala e projetos, com RH, Operações e
  gestor imediato na mesma base. Ela tem um **muro regulatório**; leia antes de prometer ponto.
- Quatro coisas **ainda faltam** para este plano fechar, e estão marcadas ao longo do texto:
  1. os itens do grupo **SaaS** do Roadmap, que vivem em `backlog_itens` na **produção** e não
     puderam ser lidos (a consulta de exportação está em `supabase/setup/backlog_seguranca_saas.sql`);
  2. o **parecer do CTO** sobre multi-empresa (seção 5) e sobre o modelo de acesso por módulo (§15.3);
  3. o **preço final e a política de desconto**, que são do responsável (seção 14);
  4. a **decisão sobre o ponto** (§15.2), que é regulatória antes de ser técnica.

---

## Quem vende

**Infoxtec Tecnologia e Serviços Ltda** — CNPJ **04.309.223/0001-96**, empresa de pequeno porte
(EPP), tributada pelo **lucro presumido**. O produto se chama **Trilha** (`docs/marca.md`).

Três consequências que valem para proposta, contrato e preço:

1. **O preço tem tributo dentro.** No lucro presumido, serviço carrega IRPJ e CSLL sobre base
   presumida de 32%, PIS/COFINS no regime cumulativo e ISS municipal — da ordem de **13% a 16% da
   receita**, antes de qualquer custo. O piso da seção 7 passa a incluir isso; **confirmar alíquotas
   e o enquadramento do software (ISS ou ICMS) com a contabilidade**.
2. **EPP é vantagem em licitação.** Empresa de pequeno porte tem tratamento diferenciado em compras
   públicas. Se o cliente atende contrato público — comum em RH/BPF de serviços, facilities e
   construção — isso entra na conversa como diferencial, não como detalhe.
3. **Identificação do operador.** Razão social e CNPJ entram no contrato e no anexo de tratamento de
   dados (LGPD), porque a Infoxtec é quem **opera** os dados pessoais do cliente controlador. É o
   primeiro item do G3.

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
| **Motivo da recusa** | Depois do "2", o técnico escolhe o motivo por número (transporte, conflito de agenda, falta de material, outro — saúde saiu na migration 49, decisão 40) e o detalhe por texto | Homologação (migration 47; PR #12) | Falta aplicar em produção |
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
| **Integrações** com chamados e almoxarifado (backlog 8 e 9) | Dependem de levantamento de API que ninguém fez |
| **Ponto e jornada (M3)** | Não iniciado, e é **programa regulado** — ver §15.2 antes de qualquer promessa |
| **Atividades e projetos: Kanban, Gantt e Curva S (M4)** | Não existe; Curva S é domínio de PMO, com outro comprador (§15.4) |
| **Acesso por área** (RH, Operações, gestor imediato) com módulos e escopo por equipe | Hoje só existem `admin`, `gestor` e `leitura` (§15.3) |
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
| **G6 · Ponto é programa regulado** | **Só vale para quem vender o módulo de ponto.** Enquadramento como REP-P, registro do programa no INPI, atestado técnico e termo de responsabilidade, comprovante ao trabalhador e Arquivo Eletrônico de Dados. Decide-se **antes de desenvolver**, com jurídico e contabilidade | §15.2 + [gov.br](https://www.gov.br/participamaisbrasil/portaria-horario-trabalho) | Responsável + jurídico |

O **G6 não bloqueia** a venda de M1 e M2 — ele só existe se o ponto entrar no escopo.

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
| **Tributos sobre a receita** | **~13% a 16% do preço** — IRPJ 4,8% + CSLL 2,88% (base presumida de 32%), PIS/COFINS 3,65% (cumulativo) e ISS de 2% a 5% | regime informado pelo responsável; **confirmar com a contabilidade** |

**O tributo entra no piso, não no lucro.** Como a alíquota incide sobre o **preço** e não sobre o
custo, a conta correta é:

```
preço mínimo  ≥  custo direto por cliente  ÷  (1 − alíquota de tributos)
```

Com 15% de tributo, cada R$ 100 de custo direto exigem **R$ 117,65** de preço só para empatar — antes
de margem, suporte e implantação. Ignorar isso é o erro que faz um SaaS parecer rentável na planilha
e não fechar o mês no caixa.

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

**Hipóteses de valor** (a testar, sem fonte de mercado — ver seção 16): mínimo mensal na casa de
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

| # | Item | Por que o comercial precisa | Já existe no quadro? | Prioridade |
|---|---|---|---|---|
| 1 | **Multi-empresa** (`empresa_id`, isolamento por cliente) | Sem isso, cada cliente é uma instalação e o preço por assento não fecha (§5) | **Sim: 029** (multi-tenant) | P0 |
| 2 | **Dossiê de conformidade** por obra, posto ou cliente tomador | É o que o RH entrega ao cliente tomador e o que a construtora mostra na fiscalização. Vende sozinho | **Parcial: 018** (histórico de auditoria exportável) e **047** (exportação de dados do cliente); o recorte por obra não existe | P0 |
| 3 | **RBAC com escopo por equipe** e *entitlement* por módulo | É o pedido central: RH, Operações e gestor na mesma base, cada um no seu módulo (§15.3) | **Não** — o 029 isola empresas, não áreas | P0 |
| 4 | **Publicação em `www.infoxtec.com.br/trilha`** — `base: '/trilha/'` no Vite, `/version.json` relativo, rewrite da Vercel e Redirect URLs do Auth nos dois projetos | Sem isso o painel não abre no endereço decidido, e a recarga automática de versão falha em silêncio | **Não** | P0 |
| 5 | **Registro de acesso a documento** (quem abriu, quando, qual) | Pergunta obrigatória em questionário de segurança de qualquer cliente médio | **Dentro do 015** — não criar item novo | P1 |
| 6 | **Retenção por tipo de documento** e expurgo automático | Prometemos retenção e hoje ela é declaração; o ASO pode exigir 20 anos, não 5 (§15.5) | **Não** (o 047 exclui a pedido, não expurga por prazo) | P1 |
| 7 | **Portal do técnico** ("minhas escalas", confirmação fora do WhatsApp) | Reduz dependência do canal e atende cliente que não quer WhatsApp | **Não** | P1 |
| 8 | **Página do produto e materiais de venda** | Sem material com lastro, cada proposta começa do zero | **Não** | P1 |
| 9 | **MFA** para administradores | Bloco 1 de segurança; trava venda para cliente maior | Grupo `seguranca`, bloco 1 | P1 |
| 10 | **Checklist e laudo pelo técnico** | Aumenta o valor por técnico e abre o discurso de execução, não só de aceite | **Sim: 001** | P2 |

**O que saiu desta lista depois da exportação de 27/09** (já existe no quadro, não é trabalho novo):
administração de contas (**034**), cobrança e assinatura (**036**, com **019** de medição de uso),
SLA e monitoramento (**058**, com **032**) e o canal oficial do WhatsApp (**023** — é o portão G1).

**Itens do quadro que este plano não tinha visto e que mudam decisões:** **017** (cadastro e
onboarding da empresa cliente), **030** (validar preço e modelo com 3 clientes piloto), **040**
(marca do cliente no painel — white-label), **042** (fila de envio com limites por número) e **055**
(CI/CD com testes e migrations versionadas, que sobrepõe as etapas 14 e 15 do plano de trabalho).

> **Reconciliação de 27/09:** a análise consolidada do backlog — duplicidades, itens prontos que
> constam como pendentes, bloqueios por decisão e a fila recomendada — está em
> [`docs/analise-backlog.md`](analise-backlog.md). Três correções vieram dela: o "trilha de leitura
> de documento" virou **"registro de acesso a documento"** (colisão com o nome do produto) e nasce
> dentro do item **015**; a integração com o ponto VRmais (item **004**) é o mesmo território do
> módulo **Ponto (M3)**; e o item **018** do quadro precisa ser renomeado para "Histórico de
> auditoria exportável", pelo mesmo motivo de marca.

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
9. **O ponto entra no produto?** Se sim: REP-P próprio (com o custo e o risco regulatório) ou
   **integração** com um REP-P já homologado (§15.2). É a decisão de maior consequência aberta hoje.
10. **O ponto será registrado pelo celular do trabalhador?** Se sim, geolocalização entra no
    tratamento de dados, e o produto precisa deixar de parecer vigilância — é decisão de LGPD e de
    posicionamento ao mesmo tempo.
11. **Qual o escopo de acesso de cada área** (RH, Operações, gestor imediato)? A matriz do §15.3 é
    proposta; quem define o que cada um vê é o responsável, com a Segurança.
12. **M4 entra no produto ou vira linha separada?** Kanban ligado à escala é evolução; Gantt depende
    de cliente pagante; Curva S é outro produto (§15.4).
13. **Retenção por tipo de documento:** confirmar com o RH/jurídico os prazos reais — o ASO pode
    exigir 20 anos, e não os 5 configurados hoje — e autorizar a mudança do parâmetro único para
    regra por tipo (§15.5).
14. **Nome do produto** — **decidido em 27/09: Trilha** (`docs/marca.md`). Falta a verificação de
    INPI e de domínio, que é o que ainda pode derrubar o nome.

---

## 15. A plataforma: jornada do recurso, módulos e o muro do ponto

**O que o responsável definiu (27/09):** o produto deixa de ser só escala. O RH, a área de Operações e
o gestor imediato passam a usar **a mesma ferramenta, em módulos distintos, sobre os mesmos dados**,
com **toda a jornada do recurso registrada**: o ponto (dev ainda não iniciado), a escala e a
programação, os documentos exigidos para liberar entrada em obra, e a gestão de atividades e projetos
(Kanban, Gantt, Curva S).

Isso é mudança de **identidade**, não de roadmap. As consequências, na ordem em que importam:

### 15.1 Os quatro módulos, com estado real

| Módulo | O que é | Estado |
|---|---|---|
| **M1 · Escala e programação** | o produto de hoje: criar, confirmar por WhatsApp, cobrar, escalonar, indicadores | **entregue** |
| **M2 · Documentos e liberação para obra** | NR, CNH e ASO com validade, alerta de vencimento, arquivo privado, vínculo com a aptidão do técnico | **entregue, com lacunas** (expurgo sem executor, sem trilha de leitura, retenção única de 5 anos) |
| **M3 · Ponto e jornada** | registro de ponto e apuração da jornada | **não iniciado** — e é programa regulado (§15.2) |
| **M4 · Atividades e projetos** | Kanban, Gantt, Curva S, gestão de atividades | **não existe** |

A boa notícia estrutural: M1 e M2 **já compartilham o mesmo modelo de dados** (técnico, local, escala,
documento, aptidão) e a mesma regra no banco. É isso que torna "mesmos dados, módulos distintos"
barato para M1+M2 — e caro só onde o domínio é novo, em M3 e M4.

### 15.2 O muro do ponto (M3): ler antes da primeira linha de código

Ponto não é funcionalidade: é **programa regulado**. A anotação do horário de trabalho é disciplinada
pelo art. 74 da CLT e pela portaria que o regulamenta, que exige **Atestado Técnico e Termo de
Responsabilidade** ([gov.br](https://www.gov.br/participamaisbrasil/portaria-horario-trabalho);
[modelo do Atestado e do Termo](https://espacolegislacao.totvs.com/wp-content/uploads/2022/08/modelo-do-atestado-tecnico-e-termo-de-responsabilidade.pdf)).
Na prática — e isto **o jurídico e a contabilidade precisam confirmar no texto oficial antes de
qualquer desenvolvimento**:

- enquadramento como **REP-P** (registro eletrônico de ponto por programa), com **registro do
  programa no INPI**, atestado técnico e termo de responsabilidade assinados;
- **comprovante de registro ao trabalhador** e **pré-assinalação** do intervalo;
- geração do **Arquivo Eletrônico de Dados (AED)** no layout oficial, para fiscalização;
- **carimbo do tempo** e trilha que resista a questionamento pericial;
- se o registro for pelo celular do trabalhador, **geolocalização** entra no tratamento: dado pessoal
  com base legal própria — e o pior lugar possível para um produto que já precisa não parecer
  vigilância.

**Recomendação, alinhada ao que já está escrito no backlog 4:** decidir antes de desenvolver entre
**(a)** virar REP-P de verdade, com jurídico e contabilidade no projeto desde o primeiro dia; ou
**(b) integrar** com um REP-P já homologado e ficar com a parte que é nossa — escala, documento e
jornada calculada. A opção (b) entrega o discurso comercial sem assumir a responsabilidade
regulatória do registro. E o backlog já registra que **bloquear** ponto por falta de aceite de escala
cria passivo trabalhista: **conciliar e alertar, nunca impedir**.

Some-se que hoje o sistema **não é** sistema de ponto; passar a ser muda o contrato, o risco e o
seguro. É decisão do responsável (item 9 da seção 14).

### 15.3 Acesso por área: os três papéis atuais não bastam

O pedido é RH, Operações e gestor imediato na mesma ferramenta, cada um no seu módulo, sobre os mesmos
dados. Hoje existem só `admin`, `gestor` e `leitura` — insuficiente. O que falta é um modelo de
**módulo + papel + escopo**:

| Área | Precisa ver | Não pode ver |
|---|---|---|
| RH | documentos e vencimentos de todos, ponto e jornada, dados cadastrais | a operação do dia a dia (escala, tarefa, projeto) além do necessário |
| Operações | escala, programação, alocação, atividades e projetos | detalhe de saúde do ASO. (O motivo de saúde da recusa deixou de existir na migration 49) |
| Gestor imediato | a própria equipe: escala, confirmação, documentos **do seu time**, pendências | outras equipes; dados de RH do resto da empresa |
| Trabalhador | a própria escala e o próprio comprovante | qualquer dado de terceiro |

Isso é **RBAC com escopo por equipe** mais *entitlement* por módulo (o que o cliente contratou).
Para o CTO: (i) o papel atual precisa ganhar escopo (empresa, área, equipe); (ii) cada função `app_*`
passa a exigir módulo **e** escopo; (iii) a Segurança precisa aprovar essa matriz antes do primeiro
código, porque é ela que define o que vaza entre áreas — e, vendendo a terceiros, entre empresas.

### 15.4 Gestão de atividades e projetos (M4): cuidado com a dispersão

Kanban, Gantt e **Curva S** não são telas: são domínio de PMO. Curva S exige **avanço
físico-financeiro** — EAP, medição por serviço, orçamento e desembolso. Quem compra isso já usa MS
Project, Primavera, Smartsheet, Monday ou ClickUp.

Recomendação: **não vender M4 antes de existir e antes de um cliente pagar por ele**. Kanban simples
de atividades ligado à escala é evolução plausível do M1 (a atividade já está no produto); Gantt é o
passo seguinte; **Curva S é outro produto**, com outro comprador (PMO/engenharia) e outro concorrente
— e é o item que mais ameaça o foco do que já vende.

### 15.5 Retenção: um prazo só não serve mais

Com ponto e documentos na mesma base, o prazo único de 5 anos deixa de fazer sentido. Cada tratamento
tem prazo próprio, e o mais longo não é o da jornada: a NR-7 exige guarda do ASO/prontuário por
**20 anos** após o desligamento, muito além dos 5 anos configurados hoje (**confirmar com o
RH/jurídico**). Isso muda o desenho: `retencao_documentos_anos` precisa virar **retenção por tipo de
documento**, e o expurgo — que hoje não roda — passa a ter consequência legal nos dois sentidos:
apagar cedo demais e guardar além do necessário são igualmente errados.

### 15.6 O que muda no pacote e no preço

- **M1** continua sendo a cunha: é o que abre a porta e o que ninguém entrega do jeito que entregamos.
- **M2** vira o pacote de conformidade — e, com RH e Operações na mesma base, deixa de ser "documento
  do técnico" para ser **o arquivo de conformidade da empresa**.
- **M3** é pacote regulado, com preço e risco próprios; só entra com o jurídico no projeto.
- **M4** é linha separada, comprada à parte.

O módulo passa a ser a unidade de *entitlement*; a cobrança continua por assento de gestão e por
técnico ativo (seção 6). Sem isso, "modular" vira promessa de folheto.

### 15.7 Sequência sugerida (por receita, não por vontade)

| Ordem | O quê | Por quê nesta posição |
|---|---|---|
| 1 | Fechar G1–G3 e vender **M1+M2** | é o que existe e é o que a meta de 2026 exige |
| 2 | **RBAC com escopo por equipe** em M1+M2 | é o pedido central: RH, Operações e gestor na mesma ferramenta |
| 3 | **Retenção por tipo de documento** e expurgo | débito legal do M2, hoje prometido e não executado |
| 4 | **M3 (ponto)**, com jurídico: REP-P próprio ou integração | maior risco regulatório; não começar sem a decisão |
| 5 | **M4 Kanban** de atividades ligado à escala | evolução natural, esforço contido |
| 6 | **M4 Gantt** | só com cliente pagante |
| 7 | **M4 Curva S** | outro produto; tratar como tal |

### 15.8 Impacto no nome

O escopo ampliado mudou o brief, e o responsável decidiu: o produto se chama **Trilha** — a trilha da
pessoa (documento → escala → ponto → obra) e a trilha de auditoria (a prova de cada passo).
Assinatura, mote e narrativa em `docs/marca.md`.

---

## 16. Fontes, limites e o que falta

**Fontes usadas:** `docs/arquitetura.md`, `docs/banco-de-dados.md`, `docs/decisoes.md`,
`docs/backlog.md`, `docs/seguranca.md`, `docs/seguranca-homologacao.md`, `docs/operacao.md`,
`docs/telefonia.md`, `docs/analise-global.md`, `docs/plano-de-trabalho.md`,
`docs/analise-backlog.md`, `docs/agente-ia.md`, `supabase/setup/backlog_seed.sql`,
`supabase/setup/documentos.md`, `supabase/setup/backlog_seguranca_saas.sql`, as 48 migrations, e a
portaria que regulamenta o art. 74 da CLT
([gov.br](https://www.gov.br/participamaisbrasil/portaria-horario-trabalho)) com o
[modelo de Atestado Técnico e Termo de Responsabilidade](https://espacolegislacao.totvs.com/wp-content/uploads/2022/08/modelo-do-atestado-tecnico-e-termo-de-responsabilidade.pdf).

**Limites declarados (não verifiquei):**

1. **Itens do grupo SaaS do Roadmap** — vivem em `backlog_itens` na produção e não foram lidos.
   Enquanto isso, esta lista da seção 13 pode duplicar ou contrariar itens que já existem.
2. **Preço de mercado** — não obtive benchmark público verificável de concorrentes brasileiros de
   gestão de campo (a página de preços consultada não estava disponível). Os valores da seção 8 são
   hipótese, não referência de mercado. Um levantamento com fonte é o próximo passo natural, e não
   foi feito.
3. **Custo da VPS da Evolution** não está no repositório.
4. **O endereço da Evolution é um `sslip.io`** (derivado do IP do servidor da Oracle, desde 28/09 —
decisão 43): não há domínio de terceiro a titularizar, mas a dependência passou a ser de um serviço de
DNS gratuito e sem contrato, além do próprio IP. O risco antigo de titularidade não está
   documentada — relevante para o anexo de tratamento de dados.
5. Disponibilidade de nome e domínio: foi feito apenas um teste de DNS, que **não é prova** de
   disponibilidade (ver `docs/marca.md`, §8).
6. **Os requisitos exatos da portaria do art. 74 da CLT** (REP-P, INPI, AED, comprovante,
   pré-assinalação) vieram de fonte secundária e de conhecimento geral; **não li o texto oficial
   inteiro**. É exatamente por isso que a decisão do §15.2 começa pelo jurídico e pela contabilidade,
   não por este documento.
7. **O escopo da plataforma (§15) não tem parecer do CTO**: o custo de RBAC com escopo, multi-empresa
   e retenção por tipo está estimado em ordem de grandeza, não medido. Multi-empresa (§5) continua
   sem estimativa.
8. **A NR-7 e os 20 anos de guarda do ASO** precisam de confirmação do RH/jurídico antes de virarem
   regra no banco — está como pergunta, não como fato.
9. **Alíquotas de tributo (seção 7)** são estimativa de lucro presumido para serviços, informadas a
   partir do regime da empresa. O enquadramento do software (ISS ou ICMS) e as alíquotas efetivas do
   município **não foram confirmados** — dependem da contabilidade.
10. **A marca Trilha não passou por INPI nem por registro de domínio.** O DNS de `trilha.com.br`
    resolve, o que indica que o endereço está ocupado (`docs/marca.md`, §7).
