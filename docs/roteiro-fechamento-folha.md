# Fechamento da folha de ponto — revisão do processo e roteiro

Decisão 96, migration 101, painel 3.40.0. Pedido do responsável em 14/10: fechar a folha num clique, mas só depois de
o sistema apontar, por funcionário, o que falta registrar ou justificar.

## 1. Como era e o que estava errado

Antes, "fechar a folha" era só emitir os espelhos do mês e mandar o link pelo WhatsApp (aba Folhas mensais). Faltavam
cinco coisas:

| # | Problema | Efeito |
|---|---|---|
| 1 | A emissão não conferia nada antes | Dia sem marcação virava falta descontada sem ninguém olhar; marcação incompleta saía com o dia zerado |
| 2 | Pedido do funcionário aguardando decisão não segurava a emissão | O espelho saía sem o ajuste ou atestado ainda não decidido; depois de assinado não se reemite |
| 3 | Nenhum registro de quem fechou | Não havia prova de quem aceitou descontar as faltas sem justificativa |
| 4 | Emissão de todos numa chamada só (cerca de 1,3 s por funcionário) | Acima de uns 6 funcionários, a chamada passava do limite de 8 s do banco e falhava |
| 5 | Link com prévia no WhatsApp | O espelho não chegava ao celular (corrigido na decisão 95, migration 100) |

## 2. Como fica

Aba **Ponto › Fechamento da folha**, separada das outras. Ela valida o mês e mostra cada funcionário numa situação:

| Situação | O que significa | O que fazer |
|---|---|---|
| **Ajustar antes de fechar** (vermelho) | Pedido do funcionário aguardando decisão, ou dia com marcação incompleta (entrada sem saída, almoço sem volta) | Aba Ajustes e pedidos: decidir o pedido; para a marcação que falta, o funcionário pede o ajuste pelo app ou WhatsApp (o gestor não inclui marcação, decisão 89) ou o gestor desconsidera a marcação errada ou abona o dia |
| **Confirmar faltas** (amarelo) | Dia da escala sem marcação e sem justificativa | Se houver justificativa, lançar o abono (ou pedir o atestado); se não, marcar a confirmação: o dia sai como falta descontada |
| **Pronto para fechar** (verde) | Nada pendente | Entra no fechamento |
| **Fechado** (azul) | Espelho emitido, ainda sem assinatura | Fechar de novo só gera nova versão se o ponto mudou |
| **Assinado** | O funcionário assinou | Não muda mais |
| **Sem ponto no mês** | Nenhum registro no mês | Não entra no fechamento |

Regras no banco (não dependem do painel):

- A emissão do espelho recusa o funcionário com pendência que bloqueia (pedido pendente ou marcação incompleta) e, sem
  a confirmação, quem tem falta sem justificativa — também por fora do painel.
- Toda emissão grava em `ponto_folha_fechamentos` quem fechou, quando e quais faltas confirmou. Esse registro não se
  altera nem se apaga. O papel leitura vê a validação, sem o e-mail de quem fechou, e não fecha.
- Dia devido segue a escala (`fn_carga_dia`). Feriado não é devido, salvo o plantão da 12x36. Sábado sem escala e sem
  expediente é abonado pela regra interna.

## 3. Fechar a folha num clique

1. **Ponto › Fechamento da folha**, escolha o mês (só mês encerrado).
2. Leia os cartões. Se houver **Ajustar antes de fechar**, resolva na aba Ajustes e pedidos e clique em **Validar de novo**.
3. Se houver **Confirmar faltas**, confira os dias listados. Justifique o que tiver justificativa; o resto, marque
   **"Conferi os dias sem registro... e confirmo que saem como falta descontada"**.
4. Deixe marcado **Enviar o espelho pelo WhatsApp para assinatura ao fechar**.
5. Clique em **Fechar a folha de MM/AAAA (N)**. O painel fecha um funcionário por vez, mostra o progresso e, no fim,
   envia os links. Quem ficou com pendência fica de fora e continua listado.
6. Acompanhe as assinaturas na própria aba (coluna Espelho) ou em Folhas mensais, onde também se reenvia o link.

Ajuste lançado depois do fechamento: enquanto o funcionário não assinou, feche de novo; sai uma nova versão e o link novo
vai pelo WhatsApp. Depois de assinado, o espelho não muda.

## 4. Logotipo na folha de ponto

Cadastro da empresa (aba Empresas): campo **Logotipo no espelho de ponto**, para empregadoras. A Infoxtec (CNPJ
04.309.223/0001-96) já sai com o logotipo dela nos dois ambientes, ligado pela migration 101. O logotipo entra congelado
no espelho na emissão: a folha já emitida não muda; a próxima emissão (ou o fechamento de novo) já sai com ele.

## 5. Roteiro de teste na homologação

Massa: funcionário **David (homologação)**, Infoxtec, jornada padrão (8 h + 4 h sábado), de maio a setembro de 2026
(carga de 14/10, registrada no plano de trabalho). Também Ana, Bruno e Gabriela, de junho a setembro.

| Mês | Situações do David |
|---|---|
| 05 | feriado 01/05 trabalhado (100%), atrasos de 7 e 25 min, HE de 1h30, 2h e 3h30, saída antecipada, domingo 17/05 trabalhado (100%), intervalo de 40 min, saída às 23h com interjornada curta, **falta sem justificativa em 26/05**, dia sem intervalo |
| 06 | HE, atraso, domingo 14/06 trabalhado com **folga compensatória em 17/06**, **atestado de 15 e 16/06** (aprovado), HE noturna |
| 07 | feriado 02/07 trabalhado, HE de 3h30, **afastamento por atestado de 20 a 25/07**, saída antecipada, **falta sem justificativa em 30/07** |
| 08 | HE, sábado com 2 h extras, **abono de testemunha em 11/08**, domingo trabalhado, HE noturna, sem intervalo, atraso |
| 09 | **pedido pendente** (saída esquecida em 15/09), **marcações incompletas em 15/09 e 21/09**, **falta sem justificativa em 17/09**, feriado 07/09 não trabalhado, domingo trabalhado |

Passos:

1. **Agosto:** o David aparece **Pronto para fechar**; o Bruno em **Ajustar antes de fechar** (marcação incompleta em
   28/08). Feche agosto: o Bruno fica de fora. Esperado: espelhos emitidos com o logotipo da Infoxtec no topo; o da
   Gabriela (Alfa) sem logotipo.
2. **Maio:** o David aparece em **Confirmar faltas** (26/05). Clique em fechar sem a confirmação: ele fica de fora.
   Marque a confirmação e feche: fecha, e a coluna Espelho mostra "1 falta confirmada".
3. **Setembro:** o David aparece em **Ajustar antes de fechar**, com o pedido nº do dia 15/09 e as marcações
   incompletas de 15 e 21/09. Aprove o pedido na aba Ajustes e pedidos (a saída das 17:00 entra). Valide de novo: sobra
   21/09. Peça a saída de 21/09 pelo app ou WhatsApp do David (ou desconsidere a entrada), valide de novo e confirme a
   falta de 17/09. Feche.
4. **Assinatura:** com o envio marcado, o link chega ao WhatsApp do funcionário que estiver na lista de números de teste.
   Abra, confira o logotipo e assine. Na aba, a situação passa a **Assinado**.
5. **Imprimir:** em Folhas mensais, **Ver** e **Imprimir ou salvar PDF**: o logotipo sai no papel.
