# Backlog — próximos 60 dias

> **O backlog agora vive dentro do sistema**, na aba **Roadmap** (administradores), com status
> editável por quem toca o projeto. Este documento guarda a análise de viabilidade de cada item,
> que não cabe numa tela. Carga inicial: `supabase/setup/backlog_seed.sql`.

## Revisão de 10/10 (PO e Scrum Master)

O Kanban (aba Roadmap) é a fonte do status; esta revisão alinha o documento a ele.
- **Entregues na produção:** 080, 081 e 082 (07/10); 083 e 090 (08/10, migrations 56 a 60); 084 entrega 1
  (avisos da CLT e espelho, 09/10). 073 concluída em 30/09; 064 e 065 em 28/09.
- **Decididos em 27/09 (decisão 32):** os pontos em aberto dos itens 14, 15 e 16 (CPF no cadastro, quem vê
  suspensão e advertência, CNH continua).
- **004 (VRmais):** substituído pelo 075, o módulo de ponto próprio (decisão 48); a conciliação de escala
  com ponto passa a fazer parte do 084.
- **Novo, 091:** endurecimento da decisão 51 (service_role, âncora do backup, token do webhook). *Em 10/10: partes 1 e 2 concluídas (restauração com âncora verde), parte 3 publicada (token no cabeçalho), migration 63 na homologação. 63 na produção em 10/10. Faltam a troca do token (14/10), a chave antiga (16/10) e o fim da URL (20/10).*
- **002 (URA):** decidido em 10/10 (decisão 54) — sem bloqueio da assinatura; disparo automático ativado, só em dia útil, das 08:00 às 20:00, fora de feriado (migration 64).
- **Sprint de 13 a 23/10:** `docs/sprint-13-23-out.html`; regras da 084 entrega 2 na decisão 52.

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
| 10 | Upload de documentos com OCR | M | Storage + OCR | **Entregue** |
| 11 | Perfil de teste para técnicos | P | — | **Entregue** |
| 12 | Indicadores clicáveis na Agenda | P | — | **Entregue** |
| 13 | Submenu da Agenda | P | — | **Entregue** |

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


---

## 10. Upload de documentos com leitura automática da validade — ENTREGUE (24/09/2026)

**Problema:** hoje a validade de NR, CNH e ASO é digitada à mão e o documento em si fica fora do
sistema. Numa fiscalização ou auditoria, ninguém encontra o arquivo.

**Escopo:** anexar PDF ou JPG na habilidade do técnico, com visualização e download pelo painel.
Com OCR ligado, o sistema lê o documento e **sugere** a data de validade, já preenchida no campo,
para a pessoa conferir e confirmar.

**Como fazer:** arquivos no Supabase Storage (1 GB no plano gratuito, suficiente para centenas de
documentos comprimidos), com acesso apenas por link assinado e temporário. Para o OCR, três
caminhos: **Google Vision** (1.000 páginas grátis por mês, melhor precisão em documento
fotografado), **Tesseract no próprio navegador** (grátis e sem enviar o documento para fora, mas
erra mais em foto torta) ou **modelo de visão via API** (bom em documento bagunçado, custa
centavos por página).

**Regra que não deve ser flexibilizada:** o OCR **sugere, nunca grava sozinho**. Uma data errada
lida de um ASO vencido é pior que campo em branco, porque cria uma falsa sensação de conformidade.

**Riscos:** são documentos pessoais — controle de acesso restrito, link temporário e prazo de
retenção definido. Vale alinhar com o RH quanto tempo guardar após o desligamento.

**Entregue:** bucket privado com criptografia em repouso, acesso só por link assinado de 2 minutos
e restrito a admin/gestor, retenção de 5 anos após o desligamento e OCR opcional para imagens.
Configuração em `supabase/setup/documentos.md`. O OCR liga ao cadastrar `GOOGLE_VISION_KEY`.

---

## 11. Perfil de teste para técnicos — ENTREGUE (24/09/2026)

**Problema:** técnicos criados para homologação entram nas contagens, aparecem no painel de
técnicos sem escala e disparam o alerta das 18h como se fossem equipe real.

**Escopo:** marcação "perfil de teste" no cadastro. Quem tiver a marca fica fora da seleção de
escalas de produção, do painel de pendências, dos indicadores e dos alertas — mas continua
recebendo mensagens e ligações, que é justamente para o que serve.

**Como fazer:** coluna na tabela de técnicos e um filtro a mais nas views que já existem
(`vw_acoes_pendentes`, `fn_pendencias_escala`, `app_resumo`, `vw_ligacoes_pendentes`).

**Aceite:** técnico de teste recebe mensagem normalmente e não aparece em nenhuma contagem.

---

## 12. Indicadores clicáveis na Agenda — ENTREGUE (24/09/2026)

**Problema:** o gestor vê "3 críticas" e precisa montar o filtro na mão para descobrir quais são.

**Escopo:** clicar no indicador aplica o filtro correspondente na tabela; clicar de novo remove.
O indicador ativo fica destacado.

**Como fazer:** só tela. Os filtros já existem na Agenda.

**Aceite:** clicar em Confirmadas deixa a tabela só com escalas confirmadas.

---

## 13. Submenu da Agenda — ENTREGUE (24/09/2026)

**Problema:** Nova Escala e Importar são janelas sobre a Agenda, e Técnicos sem Escala é um painel
embutido que divide espaço com a tabela.

**Escopo:** dividir a Agenda em quatro telas, na ordem: **Escala**, **Nova Escala**, **Técnicos sem
Escala**, **Importar Escala** — no mesmo formato de submenu usado no Roadmap.

**Ponto de atenção:** hoje o painel de pendências cria escala com o técnico já preenchido. Ao virar
telas separadas, esse atalho precisa continuar funcionando, senão a mudança custa um clique a mais
no fluxo mais usado do dia.

**Aceite:** as quatro telas na ordem pedida, e criar escala a partir de um técnico pendente
continua levando o técnico preenchido.

---

## 14. Identificação automática do documento: tipo e técnico

**Problema:** hoje o documento é enviado já dentro da ficha de um técnico, e o tipo é deduzido pelo
nome do arquivo ou pelo texto (decisão 23). Quem recebe uma pasta de documentos misturados precisa
abrir um por um para saber de quem é cada arquivo.

**Escopo:** ao carregar um ou vários arquivos, ler o título (nome do arquivo e o texto da primeira
página) e **sugerir** o tipo de documento e o técnico a que ele pertence. Nada é gravado sem a
pessoa conferir na tabela de revisão.

**Como fazer:** reaproveitar a leitura já existente (texto embutido do PDF, OCR no navegador para
imagem) e a classificação por palavra-chave. Para o técnico, comparar o nome encontrado no
documento com o cadastro, sem acento e por palavras. Sugestão com baixa confiança aparece
destacada, para escolha manual.

**Decidido em 27/09 (decisão 32):** o cadastro do técnico passa a ter CPF, usado no casamento seguro.

**Decisão pendente:** o casamento por nome falha com homônimos. O casamento seguro é pelo CPF, que
hoje não existe no cadastro. Incluir o CPF é dado pessoal a mais (LGPD) e precisa de base legal
registrada.

**Regra:** a sugestão nunca grava sozinha (decisão 15). Esforço: M.

## 15. Pré-visualização do documento e download com aviso de LGPD

**Problema:** hoje o arquivo só é visto depois de gravado, abrindo em outra aba. Na hora de
preencher a validade ou corrigir o nome, a pessoa não vê o documento ao lado do formulário.

**Escopo:**
- **No envio:** o documento aparece ao lado dos campos (tipo, técnico, validade), para conferir e
  corrigir o que a leitura automática não acertou.
- **Depois de gravado:** o mesmo visualizador, dentro do painel, sem baixar o arquivo.
- **Download separado da visualização:** antes de baixar, a pessoa lê e aceita um aviso de
  responsabilidade sobre dados pessoais (LGPD). Cada download fica registrado: quem, quando e qual
  documento.

**Como fazer:** o leitor de PDF (pdf.js) já está no painel; imagens abrem direto. O acesso
continua por link assinado de curta duração. A trilha de downloads é uma tabela nova, gravada pela
mesma função que libera o link.

**Riscos:** visualizar no navegador ainda permite captura de tela; o aviso e a trilha tornam o uso
rastreável, não impossível. Esforço: M.

## 16. Classificação obrigatória: ASO, NR, suspensão ou advertência

**Problema:** hoje um documento pode ser gravado sem tipo, e ele some dos controles de validade e
das auditorias.

**Escopo:** nenhum documento lido é gravado sem indicar a categoria: **ASO**, **NR**,
**suspensão** ou **advertência**. A regra vale no banco, não só na tela.

**Como fazer:**
- `tipos_documento` ganha a categoria. ASO e NR exigem validade; suspensão e advertência não
  vencem, mas pedem a data do fato.
- `app_registrar_documento` recusa documento sem tipo.
- Os documentos antigos sem tipo aparecem numa lista para classificar. A trava vale para os novos
  desde o primeiro dia, e para todos quando a lista zerar.

**Decidido em 27/09 (decisão 32):** suspensão e advertência só para administradores, guardadas por 3 anos; CNH continua como categoria.

**Decisões pendentes:**
- **Quem vê suspensão e advertência.** São registros disciplinares, mais sensíveis que ASO e NR.
  A sugestão é restringir a admin e manter uma retenção própria.
- **CNH:** o cadastro atual tem "CNH B" como tipo de documento. Confirmar se continua como
  categoria própria ou sai da lista.

Esforço: M. Depende do item 15 para a confirmação visual do tipo.

---

## 064. Motivo de recusa estruturado — ENTREGUE (28/09/2026, em produção)

**Problema:** quando o técnico responde 2 (não vai), a recusa fica sem motivo. A tabela
`ocorrencias` já tem o campo `motivo` (transporte, conflito de agenda, falta de material, outro —
saúde saiu do sistema na migration 49, decisão 40), mas ele nunca era preenchido; o que chega é texto livre em `detalhe`, que não dá para somar.

**Escopo entregue:** depois do "2", o WhatsApp pergunta o motivo numa lista numerada — **1 Transporte,
2 Conflito de agenda, 3 Falta de material, 4 Outro** (o motivo de saúde saiu na migration 49, decisão
40). O número vai para `ocorrencias.motivo`; o detalhe escrito continua opcional. O sistema também
grava o tempo entre o envio e a resposta.

**Critérios de aceite:**
- Dado um técnico que respondeu 2, quando ele responde 3, então a ocorrência fica com motivo
  "conflito de agenda".
- Dado um técnico que respondeu 2, quando ele manda texto em vez de número, então o texto vai para
  o detalhe e o motivo fica "outro".
- A aba Operação mostra recusas por motivo no período.

**Por que agora:** é a fase 0 de `docs/agente-ia.md` e pré-requisito dos itens 006 (IA que sugere
a escala) e 007 (predição). Cada semana sem ele é histórico perdido. Esforço: P (cerca de 1 dia).
Etapa 24 do plano de trabalho.

**Entregue em 28/09/2026, em produção:** migration 47 (`fn_wh_mensagem` e
`app_indicadores_resposta`), painel 3.5 e migration 49 (remoção do motivo de saúde). No quadro, o item
está na coluna **`feito`** (cartão movido em 27/09).

**Uma pendência que fica registrada aqui e vive no painel de temas:** o indicador de tempo de resposta
(`app_indicadores_resposta`) calcula a mediana por consulta a cada abertura da aba — sem índice
dedicado. É o tema **INF-07** (medição) e não bloqueia o item.

---

## 065. Editar e reagendar escala — ENTREGUE (28/09/2026, em produção)

**Problema:** para trocar horário, local ou técnico, o gestor precisa cancelar e criar de novo.
Depois de uma recusa, não há atalho para escalar outro técnico no mesmo horário. O status
`reagendada` existe no banco, mas nenhuma ação leva a ele.

**Escopo:** no detalhe da escala, "Editar" (horário, local, tarefa) e "Substituir técnico". A
escala editada recalcula a jornada, confere conflito e aptidão e manda a mensagem corrigida ao
técnico; a substituição cancela a do técnico anterior com aviso e cria a do novo.

**Critérios de aceite:**
- Dada uma escala confirmada, quando o gestor muda o horário, então o técnico recebe a mensagem
  corrigida e a escala volta a aguardar confirmação.
- Dada uma escala recusada, quando o gestor usa "Substituir técnico", então a nova escala é criada
  no mesmo horário e local, com o histórico ligando as duas.
- Edição que cria conflito de horário é recusada com mensagem.

**Decidido em 27/09:** editar uma escala confirmada pede nova confirmação do técnico só se mudar
data, hora ou local; mudar só a tarefa não pede. Esforço: M. Etapa 25 do plano de trabalho.

**Entregue em 28/09/2026, em produção:** migrations 47 e 48 (`app_editar_escala`,
`app_escala_edicao`, `app_substituir_tecnico`, `fn_edicao_permitida`) e painel 3.5. No quadro, o item
está na coluna **`feito`** (cartão movido em 27/09).

**Um defeito conhecido que sobra:** `app_substituir_tecnico` falha quando a escala **já começou** —
`fn_validar_inicio` exige início pelo menos 5 minutos à frente. É o tema **DEV-04** no painel de temas,
com a referência exata da cadeia de chamadas.

---

## 071. Evolution própria na Oracle Cloud — ENTREGUE (28/09/2026, em produção)

**Problema:** a Evolution rodava num servidor de terceiros (`evo.vluma.com.br`), sem controle da
chave-mestra; a chave tinha ficado exposta em 21/09 (SEG-01).
**Entrega:** servidor Oracle Always Free (E2.1.Micro, São Paulo), `https://163-176-68-206.sslip.io`,
instância `infoxtec` no número 71 4101-9605. Chave-mestra e token do webhook novos (fecha SEG-01 e
SEG-02). Versão 2.4.0-rc2, porque a 2.3.7 entrega botões como "visualização única". Roteiro e lições
em `docs/evolution-propria.md`; decisão 43.
**Aceite verificado:** escala de teste enviada 26 s depois de criada, com botões, e confirmada.

## 072. Confirmação de entrega (✓✓) na Evolution 2.4 — dívida

Os `messages.update` chegam, mas retornam `status_atualizados: 0`: a notificação fica em "enviada".
Hipótese: o id da mensagem ou o JID (sem o nono dígito, `557181776307@s.whatsapp.net`) mudou de formato
na 2.4. Investigar na homologação com um evento real; não afeta a confirmação da escala.

## 073. Desligar a Evolution antiga e consolidar o servidor — dívida

Parte F: desconectar o aparelho da vluma no celular da empresa. Depois de alguns dias estável,
parar a 2.3.7 (`evolution`), transformar a `evolution24` no serviço único do `docker-compose.yml` e
atualizar `infra/evolution/` (imagem 2.4, sem o `Caddyfile.teste`).

## 074. Esquema privado: só as funções `app_*` expostas na API — planejado (P1)

**Problema:** hoje tabelas e funções internas ficam no `public`, o esquema que a API do Supabase
expõe. Estão protegidas (RLS ligado e sem política, permissões revogadas, `app_exigir` em toda
`app_*`), mas a proteção depende de nenhuma dessas camadas falhar.
**Proposta:** mover tabelas e `fn_*` para um esquema `interno`, não exposto; no `public` ficam só as
`app_*`. Um erro futuro de permissão ou de RLS deixa de expor dado.
**Por que agora:** é requisito de maturidade para vender como serviço e para certificação (superfície
de API mínima, controle de acesso em camadas), e fica mais barato antes do multi-tenant (029).
**Aceite:** o linter não lista tabela nem `fn_*` no esquema exposto; o painel, o motor e o webhook
funcionam iguais; `plpgsql_check` zero; as migrations rodam do zero no CI.
**Esforço:** G. Etapa 24 do plano.

## 075. Módulo Registro de Ponto (Trilha Ponto) — planejado, urgente

**Oportunidade registrada em 06/10/2026.** Ponto eletrônico aderente à CLT e à Portaria MTP 671/2021,
pelo app web (principal), WhatsApp (complementar) e URA (contingência), sempre com data, hora do
servidor e localização. Nasce vendável; começa pela avaliação na Infoxtec.
**Tudo do módulo está em [`docs/modulo-registro-de-ponto/`](modulo-registro-de-ponto/README.md)**:
decisões, plano por fases, parte legal (Gabriel Pirolli e Andreia Monteiro) e aviso de privacidade.
**Tarefas:** itens **076 a 089** (L1–L4 legalização, F1–F8 desenvolvimento). Decisão 48.
**Substitui** a opção de só integrar com um ponto de terceiros (item 4, VRmais).

## Plano Diretor Comercial do Trilha

**Pedido em 27/09/2026.** Guarda-chuva comercial do produto, registrado no grupo `saas` do Roadmap.

**Problema:** o produto tinha plano de produto e plano de trabalho, mas não tinha plano comercial.
Marca, pacotes e preço vinham sendo decididos caso a caso, e cada conversa de venda começaria do
zero.

**Escopo:** manter vivos `docs/plano-comercial.md` e `docs/marca.md` como base; produzir os materiais
de venda (proposta, uma página do produto, apresentação); definir a política de preço e desconto; o
contrato e o anexo de tratamento de dados; a publicação em `www.infoxtec.com.br/trilha`; e o
acompanhamento das metas (3 empresas de RH em 2026 e 1 construtora até 30/12/2026).

**Fora de escopo:** o desenvolvimento dos módulos — cada um é item próprio —, mídia paga (decisão 29
limita a planos gratuitos) e o preço final, que é do responsável.

**Depende de:** portões **G1** (canal oficial do WhatsApp), **G2** (painel fora do plano gratuito da
Vercel) e **G3** (contrato e tratamento de dados). Sem os três, é documento, não venda.

**Esforço:** M. **Critério de aceite:** três propostas emitidas do mesmo material, com a seção "o que
não está incluso" preenchida a partir da matriz de capacidade, e o item-pai com os filhos registrados
no quadro.

**Análise completa do backlog, filhos propostos e fila recomendada:** [analise-backlog.md](analise-backlog.md).
