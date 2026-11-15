# Atestado Técnico e Termo de Responsabilidade — rascunho

**Rascunho. Não assinar** antes de todas as linhas de `conformidade-rep-p.md` estarem "Atende" e de o `juridico` e o
advogado (item 076) revisarem. O modelo vigente está no gov.br (Art. 89 §1º, redação da Portaria 1.486/2022); este
texto segue o modelo do Anexo VII original e tem de ser conferido contra ele.

**Forma (Art. 89 §§ 2º e 3º):** documento eletrônico em **PDF**, com assinatura **PAdES** qualificada (ICP-Brasil),
de **pessoa física** (e-CPF), do responsável técnico pelo programa **e** do responsável legal da desenvolvedora. A
desenvolvedora entrega o arquivo ao empregador, que o guarda para a Inspeção do Trabalho (§ 3º). Sem ele, o empregador
não pode usar o sistema (§ 4º).

---

## ATESTADO TÉCNICO E TERMO DE RESPONSABILIDADE

Na qualidade de responsável técnico e de responsável legal da empresa **[RAZÃO SOCIAL DA INFOXTEC]**, CNPJ
**[00.000.000/0000-00]**, desenvolvedora do programa identificado abaixo, os signatários, em atenção ao art. 89 da
Portaria MTP nº 671, de 8 de novembro de 2021, **atestam e declaram** que o programa identificado abaixo está em
conformidade com a Seção que trata do registro eletrônico de ponto (arts. 74 a 91) e com o Anexo IX da mesma Portaria.

| Campo | Conteúdo |
|---|---|
| Tipo do REP/PTRP | REP-P e PTRP (Programa de Tratamento de Registro de Ponto) |
| Marca do equipamento | N/A |
| Modelo do equipamento | N/A |
| Certificado de conformidade | N/A |
| Número de fabricação | N/A |
| Número de registro no INPI | **[número do certificado de registro de programa de computador]** |
| Identificador do programa | Trilha Ponto |
| Versão do programa | **[versão do painel e da base na data da assinatura, ex.: painel 3.xx.0, banco versão 2026xxxxxxxxxx]** |
| Assinatura eletrônica | N/A (exigida só para o REP-C) |

Declaram ainda que:

1. o programa é executado em ambiente de nuvem, utilizado exclusivamente para o registro de jornada, e registra
   fielmente as marcações, sem restrição de horário, sem marcação automática, sem exigir autorização prévia para a
   marcação de sobrejornada e sem permitir a alteração ou a exclusão dos dados registrados (art. 74);
2. a data e a hora de cada marcação são obtidas do servidor, sincronizado com a Hora Legal Brasileira com variação
   máxima de 30 segundos; **não há ajuste manual do relógio** pelo empregador ou pelo usuário;
3. as marcações são feitas apenas por coletores on-line (aplicativo web, WhatsApp e atendimento telefônico), que
   exibem ou informam a hora com horas, minutos e segundos no momento da marcação;
4. o Comprovante de Registro de Ponto do Trabalhador é disponibilizado em PDF assinado no padrão PAdES (arts. 79 e 80);
5. o AFD e o AEJ são gerados conforme os leiautes publicados no portal gov.br e assinados no padrão CAdES, em arquivo
   destacado (arts. 81, 83 e 88);
6. os registros de inclusão e alteração do empregador, de inclusão, alteração e exclusão de empregado, os eventos
   sensíveis e as marcações são gravados em armazenamento com redundância, com NSR próprio por estabelecimento, e não
   são apagados nem alterados pelo prazo legal (Anexo IX).

**[Cidade]**, **[data]**.

Responsável técnico: **[nome]**, CPF **[000.000.000-00]** — assinatura digital qualificada (e-CPF ICP-Brasil)

Responsável legal: **[nome]**, CPF **[000.000.000-00]**, **[cargo]** — assinatura digital qualificada (e-CPF ICP-Brasil)

---

## Como emitir (quando a conformidade estiver completa)

1. Preencher os campos entre colchetes; conferir o texto contra o modelo do gov.br.
2. Gerar o PDF (sem campos editáveis) e guardar o SHA-256 dele.
3. Cada signatário assina no Assinador do ITI (assinador.iti.br) ou do Serpro, com o **e-CPF**, em **PAdES**; os dois
   assinam o mesmo arquivo (a segunda assinatura sobre o PDF já assinado).
4. Conferir as duas assinaturas no validador do ITI (validar.iti.gov.br).
5. Entregar ao empregador (hoje, a própria Infoxtec) e guardar junto com a ata e os documentos da legalização.
6. **Nova versão do programa que mude o que está declarado** (relógio, comprovante, AFD, AEJ, armazenamento) pede
   novo Atestado.
