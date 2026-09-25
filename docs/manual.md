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

É a tela principal, dividida em quatro telas pelo submenu do topo:

| Tela | Para quê |
|---|---|
| **Escala** | Indicadores, filtros e a tabela de escalas do período |
| **Nova Escala** | Criar escala para um ou vários técnicos |
| **Técnicos sem Escala** | Quem está sem escala no dia, com o prazo das 18h |
| **Importar Escala** | Carga em lote por planilha |

Nova Escala e Importar Escala aparecem só para gestor e administrador.

### Barra superior (tela Escala)

- **De / Até** — período exibido. Abre em hoje até daqui a 7 dias.
- **Atualizar** — recarrega na hora. A tela também se atualiza sozinha a cada minuto.
- **Nova escala** — leva para a tela de criação (seção 3).

### Indicadores

Total de escalas no período, Confirmadas, Aguardando resposta, Críticas (escalas em que o
supervisor já foi acionado por falta de resposta) e % de confirmação.

**Os quatro primeiros são clicáveis e funcionam como filtro.** Clicar em Críticas deixa na tabela
só as escalas críticas; clicar de novo remove. O indicador ativo fica destacado, e Total limpa
os filtros. As contagens **não incluem técnicos de perfil de teste**.

### Técnicos sem escala

Tela própria no submenu. Mostra quem está **ativo e sem nenhuma escala** no dia
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
| **Ligar agora** | Agendada ou notificada | Liga para o técnico: uma voz lê a escala e ele digita 1 para aprovar ou 2 para negar |
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
- **Data e Hora de início** — a escala **nunca pode começar no passado**: o mínimo é 5 minutos à
  frente do horário atual. O campo de data não aceita dias anteriores a hoje, e no mesmo dia a
  hora mínima aparece como dica. O **término é calculado sozinho** pela jornada CLT e aparece logo
  abaixo, junto do tipo de jornada (diurna, noturna ou mista). Não existe campo de duração.
- **Prioridade** — baixa, normal ou urgente.
- **Descrição da tarefa** — obrigatória; é o que o técnico lê no WhatsApp.
- **Escala de teste** — funciona igual a uma escala normal (envia WhatsApp, aceita resposta,
  liga), mas fica **fora de todos os indicadores** e pode ser removida a qualquer momento, mesmo
  depois de entregue e respondida. Marca sozinha quando todos os técnicos escolhidos são de
  perfil de teste. Na tabela da Agenda, essas escalas aparecem com o selo roxo "teste".
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
| **Data de desligamento** | Inicia a contagem de guarda dos documentos (5 anos) |
| **Habilidades** | Marque o que o técnico sabe fazer e o nível de cada uma. Documentos com validade ficam em Habilidades → Documentos |
| **Perfil de teste** | Para homologação: recebe mensagens e ligações manuais normalmente, mas fica fora dos indicadores, do painel de pendências, dos alertas e das ligações automáticas |
| Ativo | Inativo não aparece em novas escalas; o histórico é preservado |

Técnico sem autorização aparece com o selo "Sem autorização"; o de homologação, com o selo "Teste".

**Excluir definitivamente** (só administrador) apaga o técnico e todo o histórico dele — escalas,
mensagens e auditoria. Exige digitar o nome para confirmar, e é recusado se ele tiver escala em
aberto de hoje em diante ou se for o último supervisor ativo. Para apenas parar de escalar,
desmarque **Ativo**.

---

## 7. Locais

Nome, cliente, endereço, cidade, referência, contato no local e **link do Google Maps**, que vai
dentro da mensagem do técnico. Locais inativos somem da seleção de novas escalas.

---

## 8. Habilidades e documentos

Três seções, e a distinção entre elas é o coração da tela:

**Habilidade** é o que o técnico sabe fazer — CFTV, fibra óptica, cabeamento. **Não vence.**

**Documento** é NR, CNH e ASO. **Sempre vence** e pode impedir a escala numa atividade que o exija.

### Documentos

Um técnico por linha, com o resumo da situação: vencidos, sem data, vencendo em 30 dias ou em dia.
Clique na linha para abrir a lista completa, com validade e quantidade de anexos de cada documento.
O filtro **"Só quem tem pendência"** deixa na tela apenas quem precisa de atenção.

Dois botões por técnico:

| Botão | Para quê |
|---|---|
| **Enviar vários documentos** | Seleciona vários arquivos ou **uma pasta inteira** de uma vez |
| **+** | Informa só a validade, sem anexar arquivo |

No envio em lote, o sistema identifica cada arquivo pelo **nome** — `NR35_JOSE.pdf` vira NR-35 — e,
quando o nome não ajuda, pelo **conteúdo lido**. Também sugere a validade de cada um. Tudo aparece
numa tabela de conferência, onde você corrige o que estiver errado, e **nada é enviado antes de
você confirmar**. Arquivos sem documento ou sem validade ficam de fora do envio, marcados em
amarelo.

Abaixo da lista fica a seção **Arquivos**, com tudo o que já foi enviado — anexar um por vez,
vincular do Google Drive, abrir e excluir.

### Habilidades

Catálogo do que existe: nome, categoria, descrição e se está ativa. **A atribuição por técnico é
feita no cadastro dele**, na aba Técnicos — não existe mais tela separada para isso.

### Tipos de atividade

Cada tipo (Instalação CFTV, Fusão de fibra) define o que o técnico precisa ter: **habilidades** no
nível mínimo e **documentos válidos**. É o que alimenta o aviso ao montar a escala — quem não
atende aparece em vermelho, com a lista do que falta e o motivo: não cadastrado, vencido, sem data
ou nível abaixo.

## 9. Usuários (só administrador)

Quem entra no painel e com qual papel.

Liberar acesso a alguém tem **duas etapas**: convidar no Supabase (Authentication → Users →
Invite user), e cadastrar o mesmo e-mail aqui com o papel. Desativar o usuário tira o acesso na
hora. O sistema impede deixar o painel sem administrador ativo.

---

## 9b. Roadmap (só administrador)

Backlog do produto dentro do sistema. Mostra o progresso das 9 funcionalidades planejadas, o que
já foi implantado e as dívidas técnicas em aberto. Cada item traz status, esforço, dependências e
observações; o lápis edita qualquer campo, e o botão **Novo item** acrescenta.

O percentual no topo conta item concluído como inteiro e parcial como meio.

O Roadmap é a fonte oficial do que está planejado: pedidos novos entram aqui como cartão, e
`docs/backlog.md` guarda a análise de viabilidade de cada um.

Duas visões: **Kanban** (padrão) e **Visão geral**. No Kanban, arraste o cartão entre Backlog,
A fazer, Fazendo, Revisão e Feito. Ao cair em Feito, o item vira concluído e ganha a data de
entrega; em Fazendo, vira em andamento. Clique no cartão para editar qualquer campo.

## 10. O que o técnico recebe

### Mensagem da escala

Chega pelo WhatsApp com data, técnico, início e término previsto, tipo de jornada, local,
endereço, link do mapa e tarefa. Traz dois botões — **Ciente, confirmado** e **Tenho um
problema** — e também aceita responder **1** ou **2**.

### Ligação de voz (URA)

Quem recebeu a escala duas vezes no WhatsApp e não respondeu recebe uma ligação automática,
entre 08h e 20h, no máximo duas por escala. Uma voz em português lê a escala e pede:
**digite 1 para aprovar, 2 para negar**. A resposta cai no mesmo lugar da resposta do WhatsApp:
o status muda na hora, o técnico recebe a confirmação por mensagem, e na recusa os supervisores
são avisados. O painel lateral mostra cada ligação com status, tecla digitada e duração.

O supervisor também pode forçar a ligação pelo botão **Ligar agora**.

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

## 11b. Sessão e atualizações

**Inatividade.** Depois de **30 minutos sem nenhuma interação**, a sessão é encerrada e o painel
volta para a tela de login avisando o motivo. Mexer o mouse, digitar ou rolar a tela já conta como
atividade, então isso só acontece com a janela realmente abandonada.

**Versão nova.** Quando uma publicação nova entra no ar, o painel que estiver aberto **recarrega
sozinho** em poucos minutos, renovando a conexão com o banco. Isso evita tela antiga conversando
com um sistema já atualizado. O carimbo no topo mostra a versão em uso.

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
