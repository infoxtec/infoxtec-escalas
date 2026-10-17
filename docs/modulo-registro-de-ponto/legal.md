# Legal, normativo e burocrático — Módulo Registro de Ponto

Tudo aqui precisa ser **confirmado no texto oficial** por **Gabriel Pirolli** (advogado) e **Andreia
Monteiro** (contadora). Este documento organiza as perguntas; não substitui o parecer.

## 1. Normas aplicáveis

| Norma | O que exige |
|---|---|
| **CLT art. 74** | Registro obrigatório acima de 20 empregados; o §2º **permite** pré-assinalar o intervalo |
| **CLT arts. 59 e 71** | Hora extra limitada a 2 h/dia; intervalo de 1 a 2 h para jornada acima de 6 h |
| **CLT art. 71, §4º** | Intervalo não concedido, total ou parcial: paga só o tempo suprimido, com 50% (natureza indenizatória desde a Lei 13.467/2017) — no resumo do espelho (decisão 83) |
| **CLT art. 73** | Adicional noturno de 20%, hora noturna reduzida de 52'30" entre 22 h e 5 h |
| **CLT art. 58, §1º** | Variação de até 5 min por marcação e 10 min no dia não é descontada nem paga como extra |
| **Lei 605/1949, arts. 6º e 9º; Súmula 146 do TST** | Falta sem justificativa pode tirar o DSR da semana; domingo e feriado trabalhados sem folga compensatória são pagos em dobro |
| **Assinatura do espelho (decisão 84)** | Assinatura eletrônica simples com HMAC: prova contra alteração da tabela, **não** contra quem administra o projeto Supabase (que lê o Vault). Não vender como "inviolável"; a cópia em PDF com o QR, nas mãos do funcionário, é a outra metade da prova |
| **OJ 410 da SDI-1 do TST** | Repouso semanal concedido depois do 7º dia seguido de trabalho é pago em dobro: a folga compensatória fica na mesma semana (decisão 84) |
| **Súmula 376 do TST** | HE acima de 2 h por dia continua devida e integra as demais verbas; o limite é infração administrativa, não perda do pagamento |
| **Portaria MTP 671/2021** | Registro eletrônico de ponto: REP-C, REP-A e **REP-P**; NSR, comprovante, AFD e AEJ, Atestado Técnico |
| **Convenção coletiva da categoria** | Tolerâncias, banco de horas, adicional de HE, intervalos — a jornada é do sindicato, não do município |
| **Súmula 338 do TST** | A prova da jornada é do empregador: o registro precisa ser íntegro |
| **LGPD (Lei 13.709/2018)** | Base legal, finalidade, minimização, transparência e prazo da localização e do CPF |
| **MP 2.200-2/2001 e Lei 14.063/2020** | Assinatura eletrônica (comprovante, arquivos, declaração ao INPI) |

## 2. Perguntas do parecer jurídico (backlog 076 — Gabriel)

As perguntas abaixo foram substituídas pela consulta de 17/10/2026 (`Consulta-REP-P-Trilha-Ponto-v3.docx`, decisão
103): 7 pareceres e 4 confirmações de sim ou não, conferidos no texto oficial (§8); o resto foi respondido pelo `juridico`.

1. O enquadramento é **REP-P** (programa registrado no INPI, Atestado Técnico emitido pelo
   desenvolvedor)? Nossa leitura: sim — o REP-A dependeria de acordo coletivo em cada cliente, o que
   inviabiliza o produto.
2. **WhatsApp** e **URA** podem ser meios de marcação do REP-P, ou só o app?
3. O **comprovante** pode ser a resposta do WhatsApp, ou precisa ser documento assinado (PDF)?
4. Que **assinatura** a Portaria exige no comprovante, no AFD e no AEJ (ICP-Brasil)?
5. **Localização obrigatória**: base legal (legítimo interesse, com avaliação registrada) e limites.
6. **Pré-assinalação do intervalo**: convém oferecer como opção por cliente?
7. Lembrete só da **saída** para o almoço, sem lembrete do retorno: confirma que não gera risco?
8. Contrato do produto: **cliente controlador, Infoxtec operadora**; responsabilidades do Atestado.

## 3. Contabilidade (backlog 077 — Andreia)

1. Convenção coletiva das categorias da Infoxtec: tolerância de atraso, HE, banco de horas, intervalos.
2. Formato do espelho de ponto para a folha; relação com o eSocial.
3. Conferência do AFD e do AEJ gerados contra o layout oficial (fase F5).

## 4. Registro do programa no INPI (backlog 078) — roteiro online

1. **Certificado digital e-CNPJ A1** (ICP-Brasil) da Infoxtec — necessário para assinar a declaração.
2. **Cadastro no e-INPI** (gov.br/inpi) como pessoa jurídica.
3. **GRU** do serviço *Pedido de Registro de Programa de Computador*. A Infoxtec é EPP e tem
   desconto: conferir o valor na tabela vigente ao emitir. Pagar e guardar o número.
4. **Hash do código-fonte** (resumo criptográfico): o código **não é enviado**. O Claude gera o
   arquivo e o resumo; a cópia fica guardada pelo responsável, em sigilo.
5. **Formulário e-Software**: título (Trilha Ponto), data de criação, linguagens, campo de aplicação,
   autores, titular (Infoxtec), hash.
6. **Declaração de veracidade** assinada com o e-CNPJ.
7. **Certificado de registro** em cerca de 10 dias, publicado na RPI. O número entra no Atestado.

Mudança grande de versão pede novo registro (barato).

## 5. Documentos a produzir (backlog 079)

| Documento | Redige | Revisa | Assina |
|---|---|---|---|
| Atestado Técnico e Termo de Responsabilidade (modelo do anexo da Portaria 671) | Claude | Gabriel | responsável |
| [Aviso de privacidade ao trabalhador](aviso-de-privacidade.md) | Claude | Gabriel | — |
| Termo de uso do app do funcionário | Claude | Gabriel | — |
| Contrato do produto com anexo de tratamento de dados (COM-03) | Gabriel | responsável | as partes |

## 6. O que podemos afirmar (comercial)

- **Nunca:** "homologado pelo MTE", "certificado pelo governo", "à prova de fraude".
- **Depois do INPI e do parecer:** *"Em conformidade com a Portaria MTP 671/2021, programa registrado
  no INPI."* — redação final com o Gabriel e a persona `marca`.

## 7. Correções à análise do DeepSeek (registradas para não voltarem)

| Afirmação | Correção |
|---|---|
| "Para software, REP-A, sem atestado" | Software é **REP-P** (INPI + Atestado do desenvolvedor); REP-A exige acordo coletivo — a confirmar no parecer |
| Arquivo "ACJEF" | Era da Portaria 1510; na 671 é o **AEJ**, e o AFD tem layout novo |
| "§4º proíbe a pré-assinalação" | O **§2º do art. 74 permite** pré-assinalar o intervalo |

## 8. Conferência no texto oficial (17/10/2026)

Texto: Portaria MTP 671/2021 compilada pelo gov.br em 21/07/2026, em `docs/legislacao/` (o PDF é o mesmo arquivo de
`docs/AFD.pdf`: a compilação inteira, não só o Anexo V). Conferência do `juridico`; consulta ao Gabriel na v3
(decisão 103).

**Respondido pelo texto (sai da consulta):**
- **Quem assina:** AFD e comprovante, o **desenvolvedor** (art. 86, §1º); AEJ, desenvolvedor ou empregador (§2º);
  Atestado, duas pessoas físicas — responsável técnico e legal — com assinatura qualificada (art. 89, §2º).
- **Padrões:** ICP-Brasil qualificada; comprovante em PDF com PAdES; AFD e AEJ em CAdES `.p7s` destacado (art. 88).
- **Comprovante (art. 79):** título literal, NSR, empregador, local, **nome e CPF completos**, data e hora, nº do INPI e
  **SHA-256 da marcação**; acesso no sistema após cada marcação, sem pedido, e extração das últimas 48 h (art. 80).
- **Espelho (art. 84):** inclui **data de admissão, cargo, horário e jornada contratual**, marcações incluídas,
  desconsideradas e pré-assinaladas, e duração com hora noturna reduzida. **Não exige assinatura do empregado.**
- **Fiscalização:** AFD "prontamente" (art. 81, §2º); AEJ e espelho em no mínimo 2 dias (art. 85).
- **Tratamento** (art. 82, parágrafo único): só acrescenta informação ou indica marcação indevida. A regra de o gestor
  nunca incluir marcação (decisões 89 e 100) é cautela nossa, mais rígida que a Portaria.
- **Guarda de 5 anos:** não está na Portaria (o Anexo IX, item 7, fala em "prazo mínimo legal"); os 5 anos vêm da
  prescrição (CF art. 7º, XXIX). Anexo VII revogado: o modelo do Atestado está no gov.br.

**O que o Trilha Ponto não cumpre hoje (entra no backlog do PO):**
1. Comprovante: não é PDF assinado, CPF mascarado, sem INPI, sem extração de 48 h; conferir se o código de
   autenticação é o SHA-256 da marcação e o título literal.
2. AFD sem os tipos 2, 5 e 6 e sem CAdES; AEJ inexistente (prazo de adequação vencido em 11/01/2023, art. 97).
3. Espelho: conferir data de admissão, cargo e horário contratual (art. 84, II e IV).
4. Anexo IX, item 3: relógio com segundos no coletor — o WhatsApp e a ligação não exibem (pergunta V7).
5. Anexo IX, item 6: NSR **por estabelecimento** (hoje por empresa; só atende se cada empresa for um CNPJ de
   estabelecimento); eventos do empregador, do empregado, do ajuste de relógio e sensíveis gravados com o responsável.
6. Anexo IX, item 2: sincronismo com a Hora Legal Brasileira, variação máxima de 30 s, sem prova hoje.
7. Anexo IX, item 7: conferir que a exclusão definitiva de técnico (decisão 8) nunca alcança marcações nem eventos.
8. Anexo IX, itens 8.1 e 13: disponibilidade permanente e alta disponibilidade (login depende do WhatsApp; plano
   gratuito).
9. Atestado e INPI: sem eles o empregador não pode usar o sistema (art. 89, §4º).
