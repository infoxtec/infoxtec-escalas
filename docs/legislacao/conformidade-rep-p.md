# Conformidade do Trilha Ponto como REP-P (Portaria MTP 671/2021)

Base do Atestado Técnico e Termo de Responsabilidade (Art. 89). O Atestado afirma **expressamente** que o programa
"atende às determinações desta Seção" (Arts. 74 a 91 e Anexo IX). **Só se assina quando todas as linhas abaixo
estiverem "Atende"** (ou com a exceção decidida por escrito pelo responsável, com parecer). Declarar conformidade que
não existe é declaração falsa em documento eletrônico (risco penal e trabalhista do signatário).

Levantamento de 15/11/2026, contra o texto compilado em `docs/legislacao/portaria-mtp-671-2021-compilada-2026-07-21.txt`
(os anexos de leiaute e o modelo do Atestado foram revogados pela Portaria 1.486/2022 e estão no gov.br: conferir).

Legenda: **Atende** · **Falta** (bloqueia a assinatura) · **Conferir** (precisa de evidência ou parecer).

## 1. Programa (Arts. 74 a 91)

| # | Exigência | Artigo | Situação | Evidência ou o que falta |
|---|---|---|---|---|
| 1 | Registrar fielmente; vedado restringir horário de marcação, marcação automática, exigir autorização prévia para hora extra e permitir alterar o registrado | 74 | **Conferir** | Sem marcação automática; hora extra não exige autorização para marcar (a aprovação vem depois, decisão 100); ajuste do gestor não altera a original (fica em `ponto_ajustes`, migration 65); marcações imutáveis (migration 54). **Risco:** a recusa de marcação durante afastamento médico (decisão 60, migration 69) pode ser lida como restrição à marcação — parecer do `juridico` e do advogado |
| 2 | REP-P em servidor ou nuvem, com certificado de registro no INPI | 78 e 91 | **Falta** | Registro do programa no INPI (e-Software) não feito (item 078) |
| 3 | Comprovante com os campos do Art. 79 (incluso número do INPI e hash) | 79 | **Falta** | Campos presentes (migration 110), mas o número do INPI ainda não existe (linha 2) |
| 4 | Comprovante eletrônico em PDF assinado (PAdES) pelo desenvolvedor | 80, 86 §1º, 88 §1º | **Falta** | O PDF existe (`web/src/ponto/comprovantePdf.ts`), **sem assinatura**. Assinar a cada marcação exige o certificado no servidor (decisão de segurança e custo) |
| 5 | AFD no leiaute vigente, por período, assinado (CAdES destacado) pelo desenvolvedor | 81, 86 §1º, 88 §2º | **Conferir** | Tipos 1, 2, 5, 7 e 9 pelo leiaute de 2021 (migration 157, decisão 139); falta conferir contra o gov.br e com a contadora; assinatura fora do painel, com o e-CNPJ da Infoxtec (só vale enquanto o empregador for a própria Infoxtec) |
| 6 | Tratamento sem alterar as marcações originais | 82 | **Atende** | Ajustes e abonos em tabelas próprias; desconsiderada continua gravada |
| 7 | AEJ no leiaute vigente, assinado | 83, 86 §2º, 88 §2º | **Conferir** | Gerado (migration 157); conferência do leiaute; assinatura fora do painel |
| 8 | Espelho de ponto com os campos do Art. 84 | 84 | **Atende** | Espelho mensal congelado, assinado pelo funcionário (migrations 88 a 107) |
| 9 | Arquivos e relatórios à disposição da fiscalização | 85 | **Atende** | AFD, AEJ e espelhos pelo painel do admin; exportação da conta (migration 144) |
| 10 | Atestado Técnico em PDF/PAdES, assinatura qualificada de **pessoa física** (e-CPF ICP-Brasil) do responsável técnico e do responsável legal | 89 §§ 1º a 3º | **Falta** | Este documento (rascunho em `atestado-tecnico-rep-p.md`); faltam os e-CPF |

## 2. Requisitos do REP-P (Anexo IX, redação da Portaria 1.486/2022)

| # | Requisito | Situação | Evidência ou o que falta |
|---|---|---|---|
| 1 | Identificar a organização e o trabalhador | **Atende** | Empresa (CNPJ) e funcionário (CPF) em toda marcação |
| 2 | Relógio sincronizado com a Hora Legal Brasileira (Observatório Nacional), desvio máximo de 30 s | **Conferir** | A hora é a do servidor do banco (`clock_timestamp()`, Supabase/AWS, sincronizado por NTP), não a do aparelho. Falta a **evidência**: medição periódica do desvio contra o NTP.br/ON, com registro e alerta acima de 30 s |
| 3 | Todo coletor exibe relógio não analógico com horas, minutos e segundos no momento da marcação | **Falta** | O app do ponto **não mostra relógio**. WhatsApp e URA não têm tela de relógio: o comprovante devolvido traz a hora com segundos (parecer: isso basta para esses canais?) |
| 4 e 5 | Coletor on-line; off-line só excepcionalmente, com envio posterior seguro | **Atende** | Só on-line: sem conexão não há marcação (não existe modo off-line) |
| 6 | Armazenamento (ARP) com redundância, alta disponibilidade e confiabilidade | **Conferir** | Supabase (banco gerenciado, backup diário próprio e cópias cifradas fora, decisão 51); dizer o plano e o SLA do fornecedor |
| 6.1 | Inclusão e alteração do empregador, com data, hora e responsável | **Atende** | Tipo 2 (migration 157); depende do CPF do responsável cadastrado |
| 6.2 | Ajuste do relógio, com antes, depois e responsável | **Atende (não se aplica)** | Não há ajuste manual do relógio: a hora vem do servidor; declarar no Atestado |
| 6.3 | Inclusão, alteração e exclusão de empregado, com responsável | **Atende** | Tipo 5 I/A/E (migration 157) |
| 6.4 | Eventos sensíveis do REP | **Falta** | Não registramos indisponibilidade nem retorno (tipo 6 do AFD). Proposta: gravar a partir do monitoramento (vigia e checklist de saúde) |
| 6.5 e 10 | Marcação com NSR, CPF, data, hora e fuso da marcação e da gravação, coletor e SHA-256 | **Atende** | `ponto_marcacoes` (momento com fuso, empresa com fuso, canal, hash encadeado) |
| OBS | NSR próprio por estabelecimento, começando em 1 | **Atende** | Por empresa (`ponto_nsr`); recomeçado em 1 antes do uso oficial (decisão 138) |
| 7 | Nada apagado ou alterado no prazo legal | **Atende** | Gatilhos de imutabilidade em linha e truncate; âncora diária fora do banco; o reinício de 13/11 foi antes do uso oficial (ata) |
| 8 | Identificação inequívoca, hora confiável, gravação e comprovante | **Conferir** | Identificação por código de uso único, telefone conferido ou PIN da URA; comprovante depende das linhas 3 e 4 do quadro 1 |
| 11 e 12 | AFD a partir da ARP, por intervalo de datas | **Atende** | `app_ponto_afd(empresa, de, ate)` e AFD completo |
| 13 | Alta disponibilidade em todas as etapas | **Conferir** | Três canais independentes (app, WhatsApp, URA); o WhatsApp depende de um servidor único (Oracle). Registrar a disponibilidade medida |

## 3. O que falta para assinar, em ordem

1. **Registro no INPI** (e-Software) — sem ele nada vale como REP-P (Arts. 78 e 91). Responsável.
2. **Relógio com segundos no app do ponto** — tela da marcação (painel; pequeno). Parecer sobre WhatsApp e URA.
3. **Comprovante em PDF assinado (PAdES)** — decidir onde fica o certificado para assinar a cada marcação (CTO e
   `seguranca`).
4. **Evidência do relógio (HLB ± 30 s)** — medição registrada e alerta (pequeno).
5. **Eventos sensíveis (tipo 6)** — gravar indisponibilidade e retorno.
6. **Conferência do leiaute do AFD e do AEJ** contra o gov.br e com a contadora.
7. **Parecer sobre o bloqueio no afastamento** (linha 1).
8. **e-CPF** do responsável técnico e do responsável legal; preencher e assinar o Atestado em PDF/PAdES.
