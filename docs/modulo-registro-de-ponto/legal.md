# Legal, normativo e burocrático — Módulo Registro de Ponto

Tudo aqui precisa ser **confirmado no texto oficial** por **Gabriel Pirolli** (advogado) e **Andreia
Monteiro** (contadora). Este documento organiza as perguntas; não substitui o parecer.

## 1. Normas aplicáveis

| Norma | O que exige |
|---|---|
| **CLT art. 74** | Registro obrigatório acima de 20 empregados; o §2º **permite** pré-assinalar o intervalo |
| **CLT arts. 59 e 71** | Hora extra limitada a 2 h/dia; intervalo de 1 a 2 h para jornada acima de 6 h |
| **Portaria MTP 671/2021** | Registro eletrônico de ponto: REP-C, REP-A e **REP-P**; NSR, comprovante, AFD e AEJ, Atestado Técnico |
| **Convenção coletiva da categoria** | Tolerâncias, banco de horas, adicional de HE, intervalos — a jornada é do sindicato, não do município |
| **Súmula 338 do TST** | A prova da jornada é do empregador: o registro precisa ser íntegro |
| **LGPD (Lei 13.709/2018)** | Base legal, finalidade, minimização, transparência e prazo da localização e do CPF |
| **MP 2.200-2/2001 e Lei 14.063/2020** | Assinatura eletrônica (comprovante, arquivos, declaração ao INPI) |

## 2. Perguntas do parecer jurídico (backlog 076 — Gabriel)

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
