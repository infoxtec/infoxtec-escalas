# Backlog — próximos 60 dias

> **O backlog agora vive dentro do sistema**, na aba **Roadmap** (administradores), com status
> editável por quem toca o projeto. Este documento guarda a análise de viabilidade de cada item,
> que não cabe numa tela. Carga inicial: `supabase/setup/backlog_seed.sql`.

Nove funcionalidades pedidas, analisadas por viabilidade, dependência e esforço.

**Escala de esforço:** P = até 3 dias · M = 1 a 2 semanas · G = 3 semanas ou mais.

## Resumo

| # | Funcionalidade | Esforço | Depende de | Cabe em 60 dias? |
|---|---|---|---|---|
| 5 | Painel de skills dos técnicos | P/M | — | **Entregue** |
| 1 | Checklist e laudo pelo WhatsApp | M/G | — | Sim (em 2 fases) |
| 3 | Painel por local e % de conclusão | M | #1 | **Entregue em versão parcial** |
| 2 | Ligação de voz com IA | M | fornecedor de telefonia | **Entregue como URA** |
| 8 | Integração com chamados Infoxtec | ? | API do sistema atual | Depende do levantamento |
| 9 | Integração com almoxarifado Infoxtec | ? | API do sistema atual | Depende do levantamento |
| 4 | Integração com ponto VRmais | M/G | API VRmais + parecer jurídico | Parcial (sem bloqueio) |
| 6 | IA que sugere a escala | G | #5, #3, geolocalização | Protótipo só |
| 7 | Predição e pré-programação | G | #6, #8 | Não |

**Semana 0 é levantamento.** Sem a documentação das APIs do VRmais, do sistema de chamados e do
almoxarifado, três itens não podem nem ser estimados. Pedir isso agora é o que destrava o resto.

---

## 1. Checklist e laudo preenchidos pelo técnico

**Problema:** hoje o técnico confirma a escala, mas não há registro do que foi executado no local.

**Escopo — fase 1 (checklist):** cada tipo de atividade tem um modelo de checklist. Ao confirmar
a chegada, o técnico recebe um link seguro que abre no celular, com os itens para marcar, campo
de observação e envio de fotos. Ao finalizar, a escala vai para `concluida` e o supervisor é
avisado.

**Escopo — fase 2 (laudo):** o checklist preenchido vira um PDF com logo, dados do cliente,
fotos e assinatura do responsável no local, colhida na tela do celular.

**Como fazer:** novas tabelas `checklist_modelos`, `checklist_itens`, `execucoes` e
`execucao_respostas`. O link é uma página nova no mesmo painel Vercel, aberta por token de uso
único (sem exigir login do técnico). Fotos no Supabase Storage. PDF gerado por Edge Function.

**Por que link em vez de conversa no WhatsApp:** um checklist de 10 itens vira 10 idas e voltas
de mensagem, com alto índice de erro. O link abre em uma tela só, funciona com foto e assinatura,
e continua chegando pelo WhatsApp. Se a equipe preferir, a versão conversacional pode vir depois
para checklists de até 3 itens.

**Riscos:** internet ruim no local — a tela precisa salvar rascunho e reenviar; armazenamento de
fotos no plano gratuito do Supabase é 1 GB (comprimir no celular antes de enviar).

**Aceite:** técnico conclui um checklist com foto pelo celular; supervisor vê no painel; PDF do
laudo baixa pelo painel.

---

## 2. Ligação de voz para aceite da escala — ENTREGUE (URA)

**Problema:** quem não responde o WhatsApp hoje depende de o supervisor ligar na mão.

**Escopo v1 (URA):** se a escala não for confirmada até X minutos antes do prazo, o sistema liga.
Uma voz sintetizada lê a escala e pede: "digite 1 para confirmar, 2 se tiver um problema". O
retorno cai no mesmo fluxo de confirmação que já existe.

**Escopo v2 (conversa com IA):** o agente entende a resposta falada e pergunta o motivo da recusa,
transcrevendo para a ocorrência.

**Como fazer:** conta em provedor de voz (Twilio é o mais documentado no Brasil) com número de
saída. O disparo entra como fase 5 do dispatcher. A URA é um fluxo simples; a v2 exige streaming
de áudio e um agente conversacional.

**Custo:** por minuto de ligação, na casa de centavos; com 10 técnicos o impacto é pequeno, mas
deixa de ser custo zero.

**Riscos:** LGPD — gravação e transcrição de voz exigem aviso no início da ligação e política de
retenção. Ligação automática em horário impróprio gera atrito: respeitar a mesma janela do
WhatsApp.

**Recomendação:** começar pela URA. Ela resolve 90% do problema com 20% do esforço, e a IA
conversacional entra depois sem refazer a base.

**Roteiro detalhado, custos e script:** [docs/telefonia.md](telefonia.md). Resumo: Twilio com
US$ 15 de crédito no trial (~340 ligações), R$ 0,24 por ligação de 40s em produção, menos de
R$ 20/mês para a equipe atual.

**Entregue em 23/09/2026:** URA na Twilio. Quem não respondeu duas mensagens recebe ligação
automática entre 08h e 20h (máximo 2 por escala); a voz lê a escala e pede 1 para aprovar ou 2
para negar. A resposta usa o mesmo caminho do WhatsApp. Botão **Ligar agora** no painel para
disparo manual. Custo ~R$ 0,24 por ligação atendida.

**Falta para a v2 (IA conversacional):** colher o motivo da recusa por voz, em vez de pedir o
detalhe por mensagem.

---

## 3. Painel por local com % de conclusão do dia — ENTREGUE (parcial)

**Problema:** o gestor não enxerga o andamento da obra, só o aceite da escala.

**Escopo:** novo painel agrupado por local, mostrando os técnicos escalados, o status de cada um
(confirmado, a caminho, no local, executando, concluído) e o percentual concluído do dia, por
local e no total. Atualização automática.

**Como fazer:** a maior parte é SQL sobre dados que já existem. O que falta é o **progresso**:
hoje o sistema sabe confirmado e recusado, mas não sabe "cheguei" e "terminei". Duas fontes
possíveis: palavras-chave no WhatsApp ("cheguei", "concluí") ou o checklist do item 1 — que é a
fonte confiável.

**Depende de:** item 1 para o percentual ser real. Sem ele, o painel mostra aceite, não execução.

**Entregue:** aba **Operação** no painel, agrupando o dia por local, com percentual de aceite,
percentual de conclusão, lista de técnicos com horário e status, e atualização automática.

**Falta para completar:** o percentual de conclusão hoje considera a escala marcada como
concluída no painel. Quando o checklist do item 1 existir, ele passa a alimentar esse número
sozinho, com hora de chegada e de término reais.

---

## 4. Integração com o ponto VRmais

**Problema:** aceite da escala e registro de ponto são hoje dois mundos separados.

**Pedido original:** impedir o registro do ponto quando não houver aceite da escala.

**Ressalva importante, antes do escopo:** a CLT (art. 74) e a Portaria 671/2021 tratam o registro
de ponto como obrigação de refletir a jornada real. Impedir o empregado de registrar o ponto pode
virar passivo trabalhista — inclusive quando ele trabalhou de fato e o sistema barrou. Não sou
advogado; essa é uma avaliação de risco, não um parecer. **Recomendo validar com o jurídico ou
com a contabilidade antes de construir o bloqueio.**

**Escopo alternativo que recomendo:** em vez de bloquear, **conciliar e alertar**. O sistema
cruza aceite de escala e batidas de ponto e aponta as divergências: bateu ponto sem escala aceita;
tem escala aceita e não bateu; bateu fora do local previsto. O supervisor recebe a lista.
Mesmo ganho de controle, sem risco trabalhista.

**Como fazer:** depende inteiramente do que o VRmais oferece — API REST, exportação de arquivo,
banco acessível. **Levantar isso é a primeira tarefa.** Sem API, o caminho é importar o arquivo
de espelho de ponto periodicamente.

**Aceite:** relatório diário de divergências entre escala e ponto.

---

## 5. Painel de skills e habilidades — ENTREGUE

**Problema:** não há registro de quem sabe fazer o quê, nem de certificações com validade.

**Escopo:** cadastro de habilidades (CFTV, fibra óptica, cabeamento estruturado, controle de
acesso, links de internet, NR-10, NR-35, CNH) com nível e validade. Cada tipo de atividade exige
um conjunto de habilidades. Ao montar a escala, o técnico sem a habilidade exigida aparece com
aviso, e as certificações vencendo nos próximos 30 dias viram alerta.

**Como fazer:** tabelas `habilidades`, `tecnico_habilidades` (nível, validade) e
`atividade_requisitos`; telas de cadastro no painel; aviso no modal de nova escala.

**Por que fazer primeiro:** é o item mais barato da lista e é **pré-requisito dos itens 6 e 7** —
sem saber quem faz o quê, nenhuma IA sugere escala com sentido.

**Entregue:** aba **Habilidades** com três seções — por técnico, catálogo e tipos de atividade com
requisitos. A atribuição é feita de uma vez: escolhe o técnico e marca todas as habilidades dele,
com o nível de cada uma. Ao montar a escala, quem não atende o tipo de atividade aparece com aviso.

**Gestão de documentos (migration 22):** NRs (1, 6, 10, 11, 12, 18, 33, 35), CNH e ASO exigem data
de validade. A aba **Documentos** mostra vencidos, sem data, vencendo em 30 dias e em dia, e os
supervisores recebem a lista toda segunda às 8h pelo WhatsApp.

**Lista agrupada:** um técnico por linha, com contagem de habilidades e situação dos documentos;
o submenu abre a lista completa com nível e validade de cada item.

Já vêm cadastradas 10 habilidades (CFTV, fibra, cabeamento, controle de acesso, link, alarme,
NR-10, NR-35, NR-33, CNH B) e 6 tipos de atividade com os requisitos iniciais.

---

## 6. IA que sugere a escala dos próximos dias

**Problema:** montar a escala é trabalho manual e depende da memória do supervisor.

**Escopo:** a partir do histórico, das habilidades e da localização, o sistema propõe a escala dos
próximos dias, com o técnico sugerido por atividade, o modal de deslocamento e o horário de saída
estimado. O supervisor revisa e aprova — nunca envia sozinho.

**Como fazer, em duas camadas:** primeiro um motor de regras (disponibilidade, habilidade
exigida, proximidade, rodízio justo, jornada); depois uma camada de IA que explica a sugestão em
texto e resolve os casos ambíguos. Deslocamento exige geocodificar os locais e consultar tempo de
trajeto — serviço pago por consulta.

**Depende de:** #5 (habilidades), #3 (histórico de execução), coordenadas dos locais.

**Riscos:** sugestão ruim destrói a confiança na ferramenta rápido. Começar sugerindo e medindo
quanto o supervisor aceita sem alterar, antes de ampliar.

**Realista:** protótipo do motor de regras dentro dos 60 dias; a camada de IA depois.

---

## 7. Predição e pré-programação de recursos

**Problema:** a demanda chega com antecedência, mas a alocação só acontece na véspera.

**Escopo:** a partir da programação de atividades e das necessidades do cliente, o sistema projeta
a demanda futura por dia, aponta onde vão faltar técnicos ou habilidades, e reserva as pessoas e
os recursos com antecedência.

**Depende de:** #6 (motor de alocação) e #8 (de onde vem a demanda) e, para material, #9.

**Realista:** não cabe em 60 dias. É o passo seguinte natural, quando 5, 6, 8 e 9 estiverem de pé.

---

## 8. Integração com o sistema de chamados Infoxtec

**Problema:** o chamado nasce num sistema e a escala em outro; alguém digita duas vezes.

**Escopo:** chamado aberto e agendado vira escala automaticamente, com cliente, local e descrição
preenchidos; o desfecho da escala (concluída, recusada, ocorrência) volta para o chamado.

**Como fazer:** desconhecido até o levantamento. Três cenários: (a) o sistema tem API REST — é a
integração mais simples da lista; (b) tem banco acessível — dá para ler direto, com cuidado;
(c) não tem nenhum dos dois — exige exportação de arquivo ou trabalho no fornecedor.

**Primeira tarefa:** levantar com quem mantém o sistema — existe API? autenticação? webhooks?
ambiente de teste?

**Valor:** alto. É a integração que elimina retrabalho diário.

---

## 9. Integração com o almoxarifado Infoxtec

**Problema:** o técnico chega na obra sem o material, ou o material sai sem vínculo com a escala.

**Escopo:** a escala lista o material previsto; o sistema reserva no almoxarifado; a retirada é
vinculada à escala; sobra e devolução voltam ao estoque. O técnico recebe no WhatsApp a lista do
que precisa retirar.

**Como fazer:** mesmo levantamento do item 8.

**Depende de:** #1 é um bom parceiro — o checklist confirma o material aplicado na obra.

---

## Sequência sugerida (60 dias)

| Período | Entrega |
|---|---|
| **Semana 0** | Levantamento das APIs: VRmais, chamados, almoxarifado. Consulta ao jurídico sobre o item 4. Conta de telefonia para o item 2 |
| **Semanas 1–2** | ~~#5 skills completo~~ (feito) · #1 fase 1 (checklist com foto) |
| **Semanas 3–4** | #1 fase 2 (laudo em PDF com assinatura) · ~~#3 painel por local~~ (feito; completar com dados do checklist) |
| **Semanas 5–6** | #2 ligação automática em URA · início de #8 ou #9, conforme o levantamento |
| **Semanas 7–8** | Conclusão da integração iniciada · #4 na versão de conciliação · protótipo do motor de regras do #6 |
| **Depois dos 60 dias** | #6 com camada de IA · #7 predição · segunda integração |

## Antes de começar, três dívidas atuais

1. **Desligar o painel Retool.** Enquanto existir, quem tem acesso de edição lá executa SQL no banco.
2. **Remover as funções da bancada de teste** (`fn_teste_wa_*`) da migration 07.
3. **Arrumar o repositório do Vercel** para que só exista uma fonte de verdade.
