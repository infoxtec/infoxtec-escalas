# Atestado Técnico e Termo de Responsabilidade — rascunho

**Rascunho. Não assinar** antes de todas as linhas de `conformidade-rep-p.md` estarem "Atende" e de o advogado (item
076) revisar. O modelo vigente está no gov.br (Art. 89 §1º, redação da Portaria 1.486/2022); este texto segue o modelo
do Anexo VII original (revogado, só referência) e **tem de ser conferido contra o do gov.br**. Revisado pelo `juridico`
(persona de apoio, sem OAB) em 15/11: só o texto do modelo, com os campos preenchidos; cada frase a mais é uma afirmação
a mais sob pena de falsidade (o detalhe técnico fica na matriz).

**Forma (Art. 89 §§ 2º e 3º):** documento eletrônico em **PDF**, com assinatura **PAdES** qualificada (ICP-Brasil),
de **pessoa física** (e-CPF), do responsável técnico pelo programa **e** do responsável legal da desenvolvedora (quem
representa a empresa pelo contrato social). A mesma pessoa pode ocupar os dois papéis (provável; confirmar com o
advogado): nesse caso, os dois blocos preenchidos e **duas assinaturas PAdES**, uma em cada qualidade. Sem o Atestado,
o empregador não pode usar o sistema (§ 4º).

**Um ou dois?** O modelo pede um único "Tipo do REP/PTRP". O Trilha é REP-P e também PTRP (espelho, AEJ): provavelmente
dois Atestados, um para cada tipo (conferir no modelo do gov.br).

---

## ATESTADO TÉCNICO E TERMO DE RESPONSABILIDADE

Na qualidade de responsável técnico e de responsável legal da empresa **[RAZÃO SOCIAL DA INFOXTEC]**, CNPJ
**[00.000.000/0000-00]**, os signatários abaixo, em atenção ao art. 89 da Portaria MTP nº 671, de 8 de novembro de
2021, atestam e declaram que o programa identificado abaixo está em conformidade com a Seção IV do Capítulo V
(arts. 72 a 101) e com o Anexo IX da Portaria MTP nº 671, de 2021.

| Campo | Conteúdo |
|---|---|
| Tipo do REP/PTRP | **REP-P** (no segundo Atestado: **PTRP**) |
| Marca do equipamento | N/A |
| Modelo do equipamento | N/A |
| Certificado de conformidade | N/A |
| Número de fabricação | N/A |
| Número de registro no INPI | **[número do certificado de registro de programa de computador]** |
| Identificador do programa | **Trilha Ponto** (o módulo de ponto, como registrado no INPI) |
| Versão do programa | **[versão na data da assinatura: painel 3.xx.0, banco 2026xxxxxxxxxx]** |
| Chave pública | N/A |
| Algoritmo de criptografia assimétrica | N/A |
| Algoritmo de hash | N/A |

**Empresa/pessoa destinatária:** **[RAZÃO SOCIAL DO EMPREGADOR]**, CNPJ **[00.000.000/0000-00]** (hoje, a própria
Infoxtec).

Os signatários declaram estar cientes das consequências legais, cíveis e criminais quanto à falsa declaração, falso
atestado e falsidade ideológica. Este documento deve ficar disponível para pronta apresentação à Inspeção do Trabalho.

**[Cidade]**, **[data]**.

Responsável técnico: **[nome]**, CPF **[000.000.000-00]** — assinatura digital qualificada (e-CPF ICP-Brasil)

Responsável legal: **[nome]**, CPF **[000.000.000-00]**, **[cargo no contrato social]** — assinatura digital
qualificada (e-CPF ICP-Brasil)

---

## Como emitir (quando a conformidade estiver completa)

1. Conferir o texto contra o modelo do gov.br e preencher os campos entre colchetes.
2. Gerar o PDF (sem campos editáveis) e guardar o SHA-256 dele.
3. Assinar no Assinador do ITI ou do Serpro, com o **e-CPF**, em **PAdES**: primeiro como responsável técnico, depois
   como responsável legal, sobre o PDF já assinado.
4. Conferir as assinaturas no validador do ITI.
5. Entregar ao empregador e guardar com a ata e os documentos da legalização.
6. **Nova versão que mude o que está declarado** (relógio, comprovante, AFD, AEJ, armazenamento) pede novo Atestado.
