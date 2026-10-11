# Justificativa de ponto pelo funcionário (084 entrega 3)

Planejamento de 11/10/2026, com o time todo: PO, CTO, `seguranca` e `marca`. O pedido veio do
responsável: o funcionário justifica falta, atraso ou falha no registro pelo WhatsApp (palavra
**ajuste**) ou pelo app (aba **Ajuste**), e o gestor aprova ou nega.

## Problema e valor

Hoje o atestado e o "esqueci de bater" chegam por foto no WhatsApp pessoal do gestor. O pedido
não fica registrado, ninguém confere prazo nem limite legal, e não há trilha de auditoria.

O gestor tem duas saídas, e as duas são ruins:

- deixar a falta sem tratamento;
- usar "incluir marcação" (migration 65) para cobrir um dia de atestado. Isso **inventa uma
  marcação que não aconteceu** e enfraquece o ponto como prova (Portaria 671; Súmula 338 do TST).

Com a funcionalidade, o funcionário ganha um canal formal com número de pedido, e o espelho fecha
sem conversa paralela. A ausência justificada vira **abono**, sem nenhuma marcação inventada.

## Arquitetura (CTO)

**Tabelas novas**, todas com RLS e sem políticas:

| Tabela | Conteúdo |
|---|---|
| `ponto_motivos` | Motivos e limites editáveis por empresa: base legal, quantidade, unidade, janela, exige anexo, é dado de saúde |
| `ponto_justificativas` | O pedido. Estados: `aguardando_anexo` → `pendente` → `aprovada` / `negada`, mais `cancelada` e `revertida` |
| `ponto_justificativa_anexos` | O documento enviado |
| `ponto_abonos` | Só inclusão, imutável como `ponto_ajustes`. O estorno é uma linha nova |

**Regras de aprovação:**

- Falta ou atraso aprovado gera um **abono**, nunca uma marcação.
- Falha de registro aprovada gera um `ponto_ajustes incluir` ligado ao pedido, com o gestor como
  autor e motivo genérico.
- O espelho passa a mostrar **falta** (dia com escala e sem marcação) e **abonado**. Hoje o dia sem
  marcação nem aparece.
- Um limite excedido gera **alerta, nunca bloqueio**: acima da lei, abonar é liberalidade do
  gestor, e isso fica registrado.

## Segurança e LGPD (`seguranca`)

Atestado, pré-natal e exame preventivo são **dados de saúde** (LGPD art. 11). O próprio motivo
escolhido já revela saúde.

**Bases legais:**

- art. 11, II, a (obrigação legal);
- art. 11, II, d (exercício de direitos em processo);
- consentimento não serve de base.

**Compatibilidade com decisões anteriores:**

- **Decisão 40:** é compatível. Nada disso passa pela recusa de escala.
- **Decisão 52:** é compatível. A justificativa é uma entidade própria, e o ajuste gerado leva
  motivo genérico.

**Bloqueadores, todos antes de coletar dado de saúde:**

1. Definir quem vê o anexo e o motivo de saúde. A decisão 39 já proíbe deixar isso aberto a todo
   gestor.
2. Definir o caminho do anexo.
3. Tirar a mídia e a legenda do `webhook_eventos`, que guarda o payload por 30 dias.
4. Garantir a guarda com executor (5 anos), a limpeza de envios soltos e a exclusão do anexo junto
   com o funcionário.
5. Proibir OCR e CID.
6. Atualizar o aviso de privacidade e obter a revisão do Gabriel antes de ligar na produção.

**Controles:**

- Arquivo de até 8 MB, só PDF, JPG ou PNG, com o tipo conferido pelos primeiros bytes.
- EXIF removido da imagem.
- Download só como anexo, com registro de acesso.
- O papel `leitura` vê apenas "abonado" ou "pendente".

## Fatiamento

| Entrega | O que entrega | Dado de saúde? | Quando |
|---|---|---|---|
| **E1** | `ponto_motivos`, `ponto_justificativas` e `ponto_abonos`. Falta e abonado no espelho. Categoria **Ponto** (esqueci de marcar, app falhou, atraso ou saída antecipada) pelo app e pelo WhatsApp, só com texto, comprovante opcional. Painel: lista de pedidos, aprovar ou negar, abono lançado pelo gestor | Não | Sprint 13–23/10 (a folga cobre) |
| **E2** | Categorias **Saúde**, **Família** e **Convocação**, com anexo obrigatório, visibilidade restrita, alerta de limite e prazo de 48 h | Sim | Próxima sprint, depois das decisões e do parecer do Gabriel |
| **E3** | Reincidência (só o fato, nunca o rótulo "desídia"), alerta de pedido parado há mais de 2 dias úteis e métrica | — | Depois da E2 |

**Métrica de 30 dias:**

- 90% dos dias com falta ou atraso com decisão registrada em até 2 dias úteis;
- zero "incluir" usado para cobrir ausência;
- zero acesso a anexo de saúde fora de quem tem a permissão.

## Base legal: conferências (valores ficam em `ponto_motivos`, nunca no texto)

| Motivo | Texto do responsável | Situação em 11/10 | Fonte a confirmar (Gabriel) |
|---|---|---|---|
| Nascimento de filho | 1 dia | **5 dias** (CF art. 7º XIX, ADCT art. 10 §1º; CLT 473 III pela Lei 14.457/2022). Lei 15.371/2026: 10 dias em 2027, 15 em 2028, 20 em 2029 | Texto oficial e vigência |
| Pré-natal | 2 dias por gestação | **Até 6 consultas ou exames** por gestação (CLT 473 X) | Redação atual no Planalto |
| Filho até 6 anos | 1 dia por ano | 1 dia por ano (473 XI) | — |
| Preventivo de câncer | 3 dias a cada 12 meses | 3 dias a cada 12 meses de trabalho (473 XII). Lei 15.377/2026 obriga o empregador a informar esse direito (§3º) | §3º e alcance |
| Doação de sangue | 1 a cada 12 meses | 1 dia a cada 12 meses (473 IV) | — |
| Mesário | — | Fora da CLT: Lei 9.504/97 art. 98 (dobro dos dias convocados) | Incluir no menu |
| Atestado acima de 15 dias | — | Afastamento previdenciário (INSS) | Alerta "encaminhar ao INSS" |
| Decreto 10.854/2021 art. 159 | Citado | Não conferido | Confirmar a citação |

## Textos (`marca`), na voz do Trilha

O menu é organizado pelo que aconteceu, não pelo inciso da lei: 4 opções, com **Ponto** em 4º.

**WhatsApp** (palavra **ajuste**; rodapé *{empresa} · Trilha Ponto*):

```
Ajuste de ponto, {nome}. O que aconteceu? Toque no botão ou responda o número:
*1* Saúde: atestado, consulta ou exame
*2* Família: falecimento, casamento ou nascimento
*3* Convocação: justiça, eleição ou outra
*4* Ponto: esqueci de marcar, atrasei ou o app falhou
*0* Cancelar
```

```
*Ponto.* O que aconteceu?
*1* Esqueci de marcar
*2* O app ou o WhatsApp não funcionou
*3* Cheguei atrasado ou saí mais cedo
*0* Voltar
O gestor analisa cada caso.
```

```
*Saúde.* Qual é o caso?
*1* Atestado médico: vale o dia ou o período indicado
*2* Declaração de comparecimento: vale só o horário da consulta
*3* Acompanhei consulta ou exame do pré-natal
*4* Levei filho de até 6 anos ao médico
*5* Fiz exame preventivo de câncer
*6* Doei sangue
*0* Voltar

Não precisa informar a doença. (CLT art. 473; Lei 605/49, art. 6º)
```

```
*Família.* O que aconteceu?
*1* Falecimento de familiar próximo: até 2 dias
*2* Casamento: até 3 dias
*3* Nascimento ou adoção de filho: {dias_paternidade} dias
*0* Voltar
(CLT art. 473)
```

```
*Convocação.* De quem?
*1* Justiça: audiência, testemunha ou júri
*2* Justiça Eleitoral: título ou mesário
*3* Outra: serviço militar, sindicato ou vestibular
*0* Voltar
```

**Perguntas do fluxo, uma por mensagem:**

- *Qual dia? Ex.: 15/10. Responda hoje ou ontem, se for o caso.*
- *Qual marcação ficou faltando? 1 Entrada · 2 Saída para almoço · 3 Volta do almoço · 4 Saída ·
  5 Início de hora extra · 6 Fim de hora extra*
- *Que horas foi? Ex.: 7h30.*
- *Agora mande a foto ou o PDF do {documento}: 📎 → Câmera ou Documento. Se o documento tiver o CID
  (código da doença), pode cobrir antes da foto.*

**Respostas ao funcionário:**

- *Pedido {numero} recebido · {motivo} · {período}. O gestor vai analisar. A resposta chega aqui e
  na aba Ajuste do app.*
- *Pedido {numero} aprovado · Abonado: esse período não é descontado.* No caso Ponto: *Marcação
  incluída: {tipo} às {hora}.*
- *Pedido {numero} não aprovado · Motivo do gestor: {texto}. Tem outro documento? Escreva ajuste e
  faça um novo pedido.*
- *A lei garante {regra}, e você já usou em {data}. O pedido pode seguir: o gestor decide se abona.*

**App, aba Ajuste:**

- Título: *Ajuste de ponto*.
- Subtítulo: *Justifique uma falta, um atraso ou uma marcação que ficou faltando. O gestor analisa,
  e você acompanha aqui.*
- Passos: *O que aconteceu?* → *Escolha o motivo* → *Quando foi?* → *Documento* → *Enviar para o
  gestor*.
- Lista *Meus pedidos*, com as situações *Em análise*, *Aprovado* e *Não aprovado*.

**Aviso legal ("Seus direitos"):**

> Falta com motivo previsto em lei e comprovada é abonada: o período não é descontado (CLT art.
> 473; Lei 605/49, art. 6º). O atestado médico vale para o dia ou o período indicado; a declaração
> de comparecimento vale só para o horário da consulta, e depois o trabalho continua. Falta ou
> atraso sem justificativa pode ser descontado, conforme as regras da empresa. Não precisa informar
> a doença.

**Recomendação do time:** não citar justa causa nem desídia (CLT 482) no fluxo. A mensagem chega
justamente quando a pessoa está fazendo a coisa certa, e soa como ameaça. A medida disciplinar é
ato do empregador e cabe no regulamento da empresa, não na tela.

## Decisões

**Decididas pelo PO:**

- menu em dois níveis, com 4 opções;
- limite que alerta e nunca bloqueia, com valores numa tabela por empresa;
- atestado depois de 48 h aceito com o selo "fora do prazo";
- declaração de comparecimento abona só o horário da consulta;
- comprovante opcional em Ponto e obrigatório nas faltas;
- reincidência mostrada só como fato;
- entidade chamada "justificativa"; "ajuste" fica sendo a palavra do WhatsApp e o nome da aba.

**Decididas pelo responsável em 11/10:** decisões 55 a 58 (abono; cofre criptografado só para
visualização por quem tem "vê saúde"; sem justa causa no texto; seguir sem o parecer, com a persona
`juridico`).
