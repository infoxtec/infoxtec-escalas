# Manual de uso

Manual do painel **Infoxtec Escalas** — https://infoxtec-escalas.vercel.app

Cada seção descreve uma tela, o que cada botão faz e o efeito no sistema.

---

## 1. Entrar no sistema

Abra o endereço e informe e-mail e senha. O acesso tem **duas etapas**, e as duas precisam existir:

1. O usuário precisa estar convidado no Supabase (Authentication → Users).
2. O mesmo e-mail precisa estar cadastrado na aba **Usuários** do painel, com um papel.

Quem tem login mas não está na lista de usuários vê a tela "Acesso não autorizado".

**Esqueci minha senha** envia um link por e-mail para criar uma nova. O link vale por uma hora.

### Papéis

| Papel | O que pode fazer |
|---|---|
| **Somente leitura** | Ver tudo: agenda, operação, técnicos, locais e habilidades. Nenhum botão de ação aparece |
| **Gestor** | Tudo acima + criar escalas, mudar status, remover, reenviar, editar técnicos, locais e habilidades |
| **Administrador** | Tudo acima + excluir técnicos definitivamente e gerenciar usuários do painel |

No topo direito aparecem seu nome e seu papel. O carimbo ao lado do título (ex.: `v1.4 · 22/09 16:40`)
diz qual versão do painel está no ar — útil quando algo parece não ter atualizado.

---

## 2. Agenda

É a tela principal: todas as escalas de um período.

### Barra superior

- **De / Até** — período exibido. Abre em hoje até daqui a 7 dias.
- **Atualizar** — recarrega na hora. A tela também se atualiza sozinha a cada minuto.
- **Importar** — sobe uma planilha com várias escalas de uma vez (seção 4).
- **Nova escala** — abre o formulário (seção 3).

### Indicadores

Total de escalas no período, Confirmadas, Aguardando resposta, Críticas (escalas em que o
supervisor já foi acionado por falta de resposta) e % de confirmação.

### Técnicos sem escala

Painel logo abaixo dos indicadores. Mostra quem está **ativo e sem nenhuma escala** no dia
escolhido — Hoje, Amanhã ou outra data. Depois do meio-dia ele abre já em "Amanhã".

- Um selo indica o prazo: **amarelo** antes das 18h, **vermelho** depois, **verde** quando a
  escala do dia seguinte está completa.
- Clicar no nome de um técnico abre a Nova escala já com ele e a data preenchidos.
- **Criar escala para os N** abre o formulário com todos os pendentes selecionados.
- A seta à direita recolhe o painel.

### Filtros e tabela

Filtros por técnico e por status. **Limpar filtros** volta ao padrão.

Colunas: Data, Horário (início–término calculado pela jornada), Técnico, Local, Tarefa, Status,
Envio e Resposta. Um ícone de lua marca jornadas noturnas e mistas.

- **Ordenar**: clique no título da coluna. Outro clique inverte. A seta mostra a coluna ativa.
- **Ajustar largura**: arraste a borda direita do título. Duplo clique volta ao padrão daquela
  coluna, e **Larguras padrão** reseta todas. As larguras ficam salvas no seu navegador.
- **Texto cortado**: passe o mouse por cima para ver o conteúdo completo.
- **Clicar na linha** abre o painel lateral da escala.

### Cores do status

| Cor | Significa |
|---|---|
| Verde | Confirmada, em execução ou concluída |
| Âmbar | Notificada, aguardando resposta |
| Vermelho | Recusada, cancelada, ou supervisor já acionado |
| Cinza | Rascunho ou agendada, ainda não enviada |

### Painel lateral da escala

Abre ao clicar numa linha. Mostra os dados completos, o endereço com link do Google Maps, o
histórico de envio (enviada, entregue, lida, resposta) e a **linha do tempo**, que junta tudo o
que aconteceu: criação, mudanças de status, eventos do WhatsApp e respostas do técnico, com
quem fez cada coisa.

Ações disponíveis (gestor e administrador):

| Botão | Quando aparece | O que faz |
|---|---|---|
| **Liberar envio** | Escala em rascunho | Marca como agendada; o WhatsApp sai em até 1 minuto |
| **Reenviar WhatsApp** | Agendada ou notificada | Dispara a mensagem de novo, agora, como nova tentativa |
| **Marcar em execução** | Escala aceita ou aguardando | Registra que o técnico está no local |
| **Concluir** | Escala em execução | Fecha a escala; entra no % de conclusão da tela Operação |
| **Cancelar** | Qualquer uma não concluída | Mantém o histórico e libera o horário do técnico |
| **Remover escala** | Só enquanto o técnico não recebeu | Apaga definitivamente. Se a mensagem já saiu, ele recebe um aviso de cancelamento |

Cancelar e remover são coisas diferentes: **cancelar** preserva o histórico; **remover** apaga,
e só é permitido enquanto o WhatsApp não confirmou a entrega no aparelho.

---

## 3. Nova escala

- **Técnicos** — seleção múltipla com busca. Uma escala é criada para cada um.
- **Tipo de atividade** — define as habilidades exigidas. Se algum técnico selecionado não tiver
  a habilidade no nível exigido, aparece um aviso vermelho com o que falta. A escala pode ser
  criada mesmo assim: a decisão é do supervisor.
- **Local** — opcional. Sem local, a mensagem diz "a confirmar".
- **Data e Hora de início** — o **término é calculado sozinho** pela jornada CLT e aparece logo
  abaixo, junto do tipo de jornada (diurna, noturna ou mista). Não existe campo de duração.
- **Prioridade** — baixa, normal ou urgente.
- **Descrição da tarefa** — obrigatória; é o que o técnico lê no WhatsApp.
- **Enviar WhatsApp agora** — marcado, a escala sai em até 1 minuto. Desmarcado, fica como
  rascunho e nada é enviado.

Ao salvar, se algum técnico já tiver escala naquele dia e horário, o sistema informa **conflito**
para ele e cria as demais normalmente. Escala cancelada não gera conflito.

---

## 4. Importar escalas

1. **Baixar modelo Excel** — planilha com as colunas certas.
2. **Lista de técnicos e locais** — nomes exatos para preencher sem erro.
3. Selecione o arquivo. A prévia mostra cada linha e o que está errado nela.
4. **Importar N escalas** — só as linhas sem erro são importadas.

Regras: nomes de técnico e local não diferenciam acentos nem maiúsculas, mas precisam ser únicos
— um nome parcial que combine com dois técnicos é recusado como ambíguo. Data aceita DD/MM/AAAA,
hora aceita HH:MM, e a coluna **enviar** aceita sim ou não. O término é calculado pela jornada.

---

## 5. Operação

Acompanhamento do dia **agrupado por local**. Escolha a data (Hoje, Amanhã ou outra).

- Indicadores no topo: locais, escalas no dia, % de aceite e % de concluído.
- Um cartão por local: endereço, link do mapa, barras de aceite e conclusão, contagem por
  situação e a lista de técnicos com horário e status.
- Selo vermelho quando há escalas críticas naquele local.
- Atualiza sozinho a cada minuto.

O **% de conclusão** conta as escalas marcadas como concluídas no painel lateral.

---

## 6. Técnicos

Cadastro da equipe.

| Campo | Observação |
|---|---|
| Nome | — |
| Telefone com DDI | Só dígitos: país + DDD + número. Ex.: 5571981776307 |
| Função | Ex.: instalador, cabista |
| Equipe | Opcional, para organização |
| **Supervisor** | Recebe os alertas: recusa, falta de resposta, prazo das 18h e documentos vencidos |
| **Autorização WhatsApp** | **Sem isso o sistema não envia nada para ele.** Registre o aceite antes de ligar |
| Ativo | Inativo não aparece em novas escalas; o histórico é preservado |

Técnico sem autorização aparece com o selo "Sem autorização".

**Excluir definitivamente** (só administrador) apaga o técnico e todo o histórico dele — escalas,
mensagens e auditoria. Exige digitar o nome para confirmar, e é recusado se ele tiver escala em
aberto de hoje em diante ou se for o último supervisor ativo. Para apenas parar de escalar,
desmarque **Ativo**.

---

## 7. Locais

Nome, cliente, endereço, cidade, referência, contato no local e **link do Google Maps**, que vai
dentro da mensagem do técnico. Locais inativos somem da seleção de novas escalas.

---

## 8. Habilidades

Quatro seções.

### Por técnico

Um técnico por linha, com a quantidade de habilidades e a situação dos documentos. **Clique na
linha** para abrir o submenu com a lista completa: habilidade, categoria, nível e validade.

**Atribuir habilidades** (ou o lápis na linha) abre a tela de atribuição:

1. Escolha o técnico — se ele já tiver habilidades, elas vêm marcadas.
2. Marque tudo o que ele tem, definindo o nível de cada uma.
3. NRs, CNH e ASO **exigem a data de validade**; o campo fica com borda vermelha até preencher.
4. Salvar. **O que ficar desmarcado é removido do técnico.**

### Documentos

Gestão de vencimentos: quatro indicadores (vencidos, sem data, vencem em 30 dias, em dia) e a
lista ordenada pelo mais urgente. Dá para incluir técnicos inativos. Quando existe documento
vencido, aparece um aviso vermelho em qualquer aba levando até aqui.

Toda segunda às 8h os supervisores recebem essa lista pelo WhatsApp.

### Habilidades (catálogo)

Cadastro do que existe: nome, categoria (técnica, segurança, habilitação, outra), descrição,
**Exige validade** e Ativa.

**Excluir** recusa quando a habilidade está em uso e informa quantos técnicos e tipos seriam
afetados; para prosseguir é preciso marcar "excluir mesmo estando em uso", e aí as atribuições
vão junto. Para tirar de circulação sem perder histórico, desmarque **Ativa**.

### Tipos de atividade

Cada tipo (Instalação CFTV, Fusão de fibra...) lista as habilidades exigidas e o nível mínimo.
É o que alimenta o aviso de aptidão na Nova escala.

### Níveis

Básico, Intermediário e Avançado. Um requisito de nível intermediário é atendido por quem tem
intermediário ou avançado.

---

## 9. Usuários (só administrador)

Quem entra no painel e com qual papel.

Liberar acesso a alguém tem **duas etapas**: convidar no Supabase (Authentication → Users →
Invite user), e cadastrar o mesmo e-mail aqui com o papel. Desativar o usuário tira o acesso na
hora. O sistema impede deixar o painel sem administrador ativo.

---

## 10. O que o técnico recebe

### Mensagem da escala

Chega pelo WhatsApp com data, técnico, início e término previsto, tipo de jornada, local,
endereço, link do mapa e tarefa. Traz dois botões — **Ciente, confirmado** e **Tenho um
problema** — e também aceita responder **1** ou **2**.

### Respostas aceitas

| O técnico faz | O sistema entende |
|---|---|
| Botão "Ciente" ou responde 1, sim, ok, ciente, confirmado | Confirmada |
| Botão "Tenho um problema" ou responde 2, problema, não | Recusada |
| Escreve qualquer outra coisa | Não entendi: o bot orienta a responder 1 ou 2, uma vez só |

### O que acontece depois

- **Confirmou**: recebe "✅ Confirmado" e a escala fica verde no painel.
- **Recusou**: recebe um pedido para descrever o problema, e os supervisores são avisados na
  hora. O texto que ele escrever em seguida é repassado ao supervisor e guardado na ocorrência.
- **Não respondeu**: lembrete a cada 30 minutos, até 3 envios. Na segunda tentativa os
  supervisores recebem alerta para ligar.

Nada é enviado fora da janela das 06h às 21h, nem para técnico sem autorização.

---

## 11. Alertas que os supervisores recebem

| Alerta | Quando |
|---|---|
| Escala recusada | Assim que o técnico responde "problema" |
| Detalhe do problema | Quando ele descreve o motivo |
| Escala sem confirmação | Na segunda tentativa sem resposta |
| Escala de amanhã | Todo dia útil às 16h, se houver técnico sem escala, com prazo às 18h |
| Prazo encerrado | Às 18h, se ainda faltar alguém |
| Documentos vencidos | Segunda às 8h |

Supervisor é quem está marcado como tal na aba Técnicos. Ninguém recebe alerta sobre si mesmo.

---

## 12. Perguntas frequentes

**A mensagem não chegou para um técnico.** Confira, nesta ordem: ele está **ativo** e com
**autorização WhatsApp**? A escala está como rascunho? O horário está dentro da janela 06h–21h?
No painel lateral, a coluna Envio mostra o erro quando a Evolution recusou.

**O painel mostra "notificada" mas o técnico diz que não recebeu.** "Notificada" significa que a
Evolution aceitou o envio. Entregue e Lida aparecem no painel lateral e vêm do WhatsApp.

**Preciso mudar o intervalo dos lembretes, o prazo das 18h ou a jornada.** São parâmetros de
banco, sem deploy. Peça a quem administra o sistema; a lista está em `docs/banco-de-dados.md`.

**Cancelei uma escala e quero criar outra no mesmo horário.** Pode: escala cancelada libera o
horário do técnico.

**Um técnico saiu da empresa.** Desmarque **Ativo**. Use Excluir apenas quando for preciso apagar
os dados pessoais dele — a ação apaga o histórico e não tem volta.
