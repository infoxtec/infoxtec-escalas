# Roteiro de validação do ponto — setembro/2026 (homologação)

Pedido do responsável em 13/10: validar o registro de ponto e a folha do mês para assinatura, com todas as
situações. A massa foi criada na **homologação** por `supabase/setup/validacao-ponto-setembro.sql`. Ela é
fictícia e permanente, porque marcação de ponto é imutável.

- **Empresa:** Validação do Ponto Ltda (fictícia), CNPJ de exemplo 88.888.888/0001-91.
- **Local:** Sede Validação (fictícia).
- **Marcos Teixeira (validação):** CPF 808.080.801-56, admitido em 10/03/2025. Concentra horas extras, noturno, domingo, feriado, faltas e atrasos.
- **Juliana Prado (validação):** CPF 808.080.802-37, admitida em 03/06/2024. Concentra abonos, afastamento, comparecimento e faltas.
- **Telefones** com DDD 00 e sem autorização de WhatsApp: nenhuma mensagem sai.
- **Marcações:** 142, com NSR de 1 a 142, sem lacuna e com hash encadeado conferido. Foram gravadas como o app grava, só que com a hora de setembro.
- **Também gravados:** 40 escalas, 2 ajustes do gestor, 8 abonos (1 deles é a folga compensatória) e 3 pedidos aprovados (2 atestados e 1 declaração de comparecimento).

Regras da empresa (config da homologação):
- jornada de 8h de segunda a sexta e 4h no sábado;
- intervalo de 1h;
- tolerância de 10 min no dia;
- sábado sem expediente é abonado.

Marque **OK** ou **NOK** em cada item. Quando der NOK, anote o que apareceu.

---

## 0. Preparação

| # | Passo | Esperado | OK/NOK |
|---|---|---|---|
| 0.1 | No Linux: `cd ~/infoxtec-escalas && git pull && ./scripts/painel.sh iniciar` e abra http://localhost:5173. Para o celular, use o endereço de *preview* da Vercel do último PR, que aponta para a homologação. | Painel da **homologação** (projeto `infoxtec-escalas-dev`) | |
| 0.2 | Entre como admin. | Menu completo, com a página Ponto | |

## 1. Registro de ponto (marcações)

Em **Ponto › Marcações**, mês **setembro de 2026**:

| # | Conferir | Esperado | OK/NOK |
|---|---|---|---|
| 1.1 | Total da empresa Validação | 142 marcações, NSR de 1 a 142 em ordem de horário | |
| 1.2 | Canais | Marcos: app, com WhatsApp nos dias 9, 21 (menos a entrada repetida das 08:02) e 30, e URA no sábado 12. Juliana: app | |
| 1.3 | 18/09, Marcos | 3 marcações originais (entrada, saída almoço, volta). A saída das 17:00 vem de ajuste | |
| 1.4 | 21/09, Marcos | Duas entradas (08:00 e 08:02). A das 08:02 aparece como desconsiderada | |
| 1.5 | 08 a 10/09, Juliana | Nenhuma marcação: estava afastada | |

## 2. Espelho de jornada (tela do gestor)

Em **Ponto › Espelho de jornada**, mesmo mês. Escolha um funcionário de cada vez.

**Marcos:**

| Dia | Situação montada | Esperado no dia | OK/NOK |
|---|---|---|---|
| 01 ter | Saiu às 19:00 | Trabalhado 10h00, HE 2h00 | |
| 03 qui | Entrou às 08:40 | Aviso de atraso; trabalhado 7h20 | |
| 04 sex | Saiu às 16:00 | Trabalhado 7h00 | |
| 07 seg | Feriado (Independência), trabalhou 08–15 | Trabalhado 6h00 | |
| 08 ter | Entrou às 08:07 | Aviso de atraso (7 min), trabalhado 7h53 | |
| 10 qui | Escala e nenhuma marcação | **Falta** | |
| 12 sáb | 08–12, pela URA | Trabalhado 4h00 | |
| 13 dom | 08–12 | Trabalhado 4h00 | |
| 15 ter | Saiu às 20:30 | HE 3h30 e aviso de HE acima de 2h | |
| 17 qui | 08–17 sem almoço | Aviso de "sem intervalo"; trabalhado 9h00 | |
| 18 sex | Saída por ajuste | Trabalhado 8h00 | |
| 20 dom | 08–12 | Trabalhado 4h00 | |
| 22 ter | Folga compensatória | Abono do dia inteiro | |
| 24 qui | 14:00–23:30 | Trabalhado 8h30 | |
| 29 ter | Entrou às 07:00, depois de sair às 23:00 do dia 28 | Aviso de interjornada curta | |

**Juliana:**

| Dia | Situação montada | Esperado no dia | OK/NOK |
|---|---|---|---|
| 02 qua | Entrou 09:00; gestor abonou 08–09 | "Atraso abonado", abono 08:00–09:00 | |
| 04 sex | Saiu às 18:00 | HE 1h00 | |
| 08 a 10 | Atestado de 3 dias | "Falta abonada", abono do dia inteiro (sem dizer o motivo) | |
| 15 ter | Comparecimento 08–10, chegou 10:00 | "Atraso abonado", abono 08:00–10:00 | |
| 18 sex | Dispensada pela empresa | "Falta abonada", dia inteiro | |
| 22 e 23 | Escala e nenhuma marcação | **Falta** nos dois dias | |
| 24 qui | Trabalhou 08–12; atestado 13–17 | Trabalhado 4h00, abono 13:00–17:00 | |
| 26 sáb | 08–14 sem intervalo | Trabalhado 6h00, aviso de "sem intervalo" | |
| 27 dom | 08–12 | Trabalhado 4h00 | |
| 29 ter | Sem escala e sem ponto | Dia sem registro | |
| 30 qua | 08:03 a 16:55 | Trabalhado 7h52, sem aviso (dentro da tolerância) | |

## 3. Ajustes e abonos

Em **Ponto › Ajustes**:

| # | Conferir | Esperado | OK/NOK |
|---|---|---|---|
| 3.1 | Ajustes do Marcos | "Incluir saída 18/09 17:00" e "Desconsiderar entrada 21/09 08:02", com motivo e autor | |
| 3.2 | Tentar lançar folga compensatória de setembro para o Marcos (Ajuste "Folga compensatória", domingo trabalhado 13/09, folga 10/09) | **Recusado**: "Folga já passada só pode ser lançada até 7 dias depois" | |
| 3.3 | O mesmo com folga 15/09 | **Recusado**: "Há trabalho registrado no ponto em 15/09: não foi folga" | |

## 4. AFD

Em **Ponto › Arquivo Fonte de Dados (AFD)**, empresa **Validação do Ponto**, de 01/09 a 30/09:

| # | Conferir | Esperado | OK/NOK |
|---|---|---|---|
| 4.1 | Nome do arquivo | Termina em `_CONFERENCIA` (o leiaute oficial ainda depende da assinatura CAdES) | |
| 4.2 | Conteúdo | Cabeçalho, 142 registros de marcação (tipo 7) com NSR 000000001 a 000000142, e trailer | |
| 4.3 | Andreia | Mesmo padrão do AFD que ela validou | |

## 5. Emissão da folha (espelho mensal)

Em **Ponto › Espelhos mensais**, Mês **2026-09**:

| # | Passo | Esperado | OK/NOK |
|---|---|---|---|
| 5.1 | Clique em **Emitir espelhos do mês** | Marcos e Juliana emitidos, cada um com nº de registro e código de verificação. Pode aparecer também quem mais tiver CPF na homologação | |
| 5.2 | Clique em **Emitir** de novo | "Sem mudança": não cria versão nova | |
| 5.3 | **Ver** o espelho do Marcos | Documento com QR, empresa, CNPJ, CPF, função, jornada e todos os dias | |

### 5.4 Resumo esperado: Marcos

| A pagar | HH:MM | A descontar | HH:MM |
|---|---|---|---|
| Hora extra 50% | **07:13** (01: 2h00 + 15: 3h30 + 17: 1h00 + 24: 0h43) | Horas em débito | **09:40** (03: 0h40 + 04: 1h00 + 10: 8h00) |
| Hora extra 100% | **10:00** (feriado 07: 6h00 + domingo 13: 4h00) | Dias sem registro | **1** (10/09) |
| Adicional noturno (reduzidas) | **02:52** (24: 1h30 → 1h43 + 28: 1h00 → 1h09) | Semanas com falta (DSR) | **1** |
| Intervalo não concedido | **01:00** (17/09) | | |
| **Total de HE** | **17:13** | | |

**Informativo:**
- previstas 172:00; trabalhadas 175:13;
- noturnas no relógio 02:30;
- folgas compensatórias 1;
- dias trabalhados 23;
- dias com mais de 2h extras 1;
- interjornada curta 1;
- feriados: 07/09.

**Conferências que provam a regra:**
- 20/09 (domingo) sai **sem 100%**, com "Compensado com folga em 22/09".
- 22/09 diz "Folga compensatória do trabalho de 20/09", sem débito.
- 08/09 (atraso de 7 min) e 28/09 (9 min de noturno reduzido) ficam dentro da tolerância de 10 min: sem débito e sem HE.
- 25/09, saída às 22:00 em ponto: sem minuto noturno.

### 5.5 Resumo esperado: Juliana

| A pagar | HH:MM | A descontar | HH:MM |
|---|---|---|---|
| Hora extra 50% | **03:00** (04: 1h00 + sábado 26: 2h00) | Horas em débito | **24:00** (22, 23 e 29: 8h00 cada) |
| Hora extra 100% | **04:00** (domingo 27) | Dias sem registro | **3** |
| Adicional noturno | **00:00** | Semanas com falta (DSR) | **2** |
| Intervalo não concedido | **00:15** (sábado 26, 6h sem intervalo) | | |
| **Total de HE** | **07:00** | | |

**Informativo:**
- previstas 172:00; trabalhadas 115:52;
- abonadas com justificativa 30:00 (3 dias de atestado + 2h de comparecimento + 4h de atestado parcial);
- abonadas pela empresa 09:00 (atraso de 02 + dispensa de 18);
- dias abonados com justificativa 5;
- dias trabalhados 16.

| # | Conferir | Esperado | OK/NOK |
|---|---|---|---|
| 5.6 | Palavra "atestado" | Não aparece em nenhum lugar do espelho da Juliana (decisão 83): os dias aparecem como abono | |
| 5.7 | Avisos ao pé do espelho | 7 frases, entre elas: valores em reais são da folha; 100% quando não há folga compensatória; HE e débito não se compensam; DSR | |

## 6. QR e conferência pública

| # | Passo | Esperado | OK/NOK |
|---|---|---|---|
| 6.1 | **Imprimir ou salvar PDF** no "Ver" | Só o documento sai no papel; QR legível | |
| 6.2 | Ler o QR com o celular (ou abrir `/v` e digitar o código) | Registro, empresa, CNPJ, mês, emissão, "íntegro" e "ainda não assinado". **Sem** nome, CPF ou horários | |

## 7. Envio e assinatura pelo funcionário

| # | Passo | Esperado | OK/NOK |
|---|---|---|---|
| 7.1 | **Enviar pelo WhatsApp** | "Sem WhatsApp" para Marcos e Juliana (sem autorização e com a trava da homologação). Nenhum dos dois fica marcado como enviado | |
| 7.2 | Em **Técnicos**, ícone de chave do Marcos: **Gerar código de acesso ao app do ponto** | Código de acesso, válido por 15 min | |
| 7.3 | No celular, abra `<endereço do preview>/ponto`. Entre com CPF 808.080.801-56 e o código | App do ponto do Marcos | |
| 7.4 | Aba **Espelho** › Espelho 09/2026 | O mesmo documento do item 5.4, com o resumo | |
| 7.5 | Tentar assinar sem desenhar ou sem marcar a ciência | Botão Assinar desabilitado | |
| 7.6 | Desenhar, marcar "Conferi este espelho..." e **Assinar** | "Espelho assinado em DD/MM/AAAA HH:MM"; a assinatura aparece no documento | |
| 7.7 | **Baixar PDF ou imprimir** no celular (testar Safari do iOS e Chrome) | PDF com a assinatura e o QR; mês cheio legível. Esta é a pendência de impressão da decisão 82 | |
| 7.8 | Ler o QR de novo | "Assinado pelo funcionário em ..." sem "não confere"; a imagem da assinatura não aparece | |
| 7.9 | No painel, **Ver** o espelho do Marcos | A assinatura aparece; o papel leitura não abre esse "Ver" | |
| 7.10 | **Emitir espelhos do mês** de novo | Marcos conta como "já assinado": não é reemitido | |
| 7.11 | Deixe a Juliana **sem assinar** | A lista mostra Marcos assinado e Juliana pendente | |

## 8. Encerramento

- Responda com a lista de NOK: cada um vira correção ou item de backlog.
- Com tudo OK: o script `supabase/setup/validacao-ponto-setembro.sql` sai do repositório no próximo PR. A massa continua na homologação para demonstração e treino.
- Cuidado: a massa usa o mês de setembro e a empresa fictícia. Não lance nada real nela.
