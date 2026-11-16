# Conformidade do Trilha Ponto como REP-P (Portaria MTP 671/2021)

Base do Atestado Técnico e Termo de Responsabilidade (Art. 89). O Atestado afirma **expressamente** que o programa
"atende às determinações desta Seção" (Seção IV, **arts. 72 a 101**, e Anexo IX). Revisado pelo `juridico` em 15/11. **Só se assina quando todas as linhas abaixo
estiverem "Atende"** (ou com a exceção decidida por escrito pelo responsável, com parecer). Declarar conformidade que
não existe é declaração falsa em documento eletrônico (risco penal e trabalhista do signatário).

Levantamento de 15/11/2026, contra o texto compilado em `docs/legislacao/portaria-mtp-671-2021-compilada-2026-07-21.txt`
(os anexos de leiaute e o modelo do Atestado foram revogados pela Portaria 1.486/2022 e estão no gov.br: conferir).

Legenda: **Atende** · **Falta** (bloqueia a assinatura) · **Conferir** (precisa de evidência ou parecer).

## 1. Programa (Seção IV, arts. 72 a 101)

| # | Exigência | Artigo | Situação | Evidência ou o que falta |
|---|---|---|---|---|
| 1 | Registrar fielmente; vedado restringir a marcação, marcação automática, exigir autorização prévia para hora extra e permitir alterar o registrado; vedados "parametrizações e bloqueios na marcação" (apreensão pelo auditor) | 74 e 98 | **Falta** | Atende: sem marcação automática; hora extra não exige autorização para marcar (decisão 100); ajuste não altera a original (migration 65); marcações imutáveis (migration 54). **Falta: dois bloqueios** — a recusa durante afastamento médico (decisão 60, migration 69) e a recusa no WhatsApp sem localização. Proposta do `juridico`: aceitar, sinalizar ("marcação durante afastamento" / "sem localização"), avisar o gestor. Muda a decisão 60: **decisão do responsável** |
| 1a | Registro fiel da hora: no WhatsApp a hora é a da chegada ao servidor | 74 | **Conferir** | Medir o atraso da fila e sinalizar ao gestor quando passar de um limite (cautela) |
| 1b | REP-P usado exclusivamente para o registro de jornada | 78 | **Conferir** | O Trilha também faz escalas: o registro no INPI e o identificador devem apontar o módulo de ponto como programa separado |
| 2 | REP-P em servidor ou nuvem, com certificado de registro no INPI | 78 e 91 | **Falta** | Registro do programa no INPI (e-Software) não feito (item 078) |
| 3 | Comprovante com os campos do Art. 79 (incluso número do INPI e hash) | 79 | **Falta** | Campos presentes (migration 110), mas o número do INPI ainda não existe (linha 2) |
| 3a | Comprovante com o local da prestação ou o endereço do estabelecimento, para atividade externa | 79, IV | **Conferir** | Técnicos de campo: o comprovante traz o local da escala quando há; conferir o caso sem escala |
| 3b | Comprovante acessível logo após cada marcação, sem pedir; extração dos comprovantes das últimas 48 h | 80, par. único, II e III | **Conferir** | `ponto_meus_comprovantes` (48 h) e o PDF no app; conferir WhatsApp e URA |
| 3c | Hash do comprovante igual ao do tipo 7 no AFD | 79, VIII e 81 | **Falta** | Hoje são diferentes (cadeia do banco x hash do AFD); `juridico` recomenda um só |
| 4 | Comprovante eletrônico em PDF assinado (PAdES) pelo desenvolvedor | 80, 86 §1º, 88 §1º | **Falta** | O PDF existe (`web/src/ponto/comprovantePdf.ts`), **sem assinatura**. Assinar a cada marcação exige o certificado no servidor (decisão de segurança e custo) |
| 5 | AFD no leiaute vigente, por período, assinado (CAdES destacado) pelo desenvolvedor | 81, 86 §1º, 88 §2º | **Conferir** | Tipos 1, 2, 5, 7 e 9 pelo leiaute de 2021 (migration 157, decisão 139); falta conferir contra o gov.br e com a contadora; assinatura fora do painel com o e-CNPJ da Infoxtec, que vale também para clientes de fora (desenvolvedor, Art. 86 §1º) |
| 5a | AFD "prontamente gerado" ao auditor; arquivos e relatórios em até 2 dias | 81 §2º e 85 | **Conferir** | A assinatura manual fora do painel precisa caber no prazo: procedimento escrito e quem assina na ausência do responsável |
| 6 | Tratamento sem alterar as marcações originais | 82 | **Atende** | Ajustes e abonos em tabelas próprias; desconsiderada continua gravada |
| 7 | AEJ no leiaute vigente, assinado (desenvolvedor ou empregador) | 83, 86 §2º, 88 §2º | **Conferir** | Gerado (migration 157); conferência do leiaute; assinatura fora do painel |
| 8 | Espelho de ponto com os campos do Art. 84 (admissão, cargo, horário e jornada contratual, noturno reduzido) | 84 | **Conferir** | Espelho mensal congelado (migrations 88 a 107); falta a lista campo a campo como evidência — e 10 funcionários da produção ainda sem admissão e matrícula |
| 9 | Arquivos e relatórios à disposição da fiscalização | 85 | **Atende** | AFD, AEJ e espelhos pelo painel do admin; exportação da conta (migration 144) |
| 9a | Dados de rastreamento entregues ao auditor | 100 | **Conferir** | Exportação da conta e trilhas de acesso; listar o que se entrega |
| 9b | LGPD | 101 | **Conferir** | Inventário e avisos (`seguranca`) |
| 10 | Atestado Técnico em PDF/PAdES, assinatura qualificada de **pessoa física** (e-CPF ICP-Brasil) do responsável técnico e do responsável legal | 89 §§ 1º a 3º | **Falta** | Este documento (rascunho em `atestado-tecnico-rep-p.md`); faltam os e-CPF |

## 2. Requisitos do REP-P (Anexo IX, redação da Portaria 1.486/2022)

| # | Requisito | Situação | Evidência ou o que falta |
|---|---|---|---|
| 1 | Identificar a organização e o trabalhador | **Atende** | Empresa (CNPJ) e funcionário (CPF) em toda marcação |
| 2 | Relógio sincronizado com a Hora Legal Brasileira (Observatório Nacional), desvio máximo de 30 s | **Conferir** | A hora é a do servidor do banco (`clock_timestamp()`, Supabase/AWS, sincronizado por NTP), não a do aparelho. Falta a **evidência**: medição periódica do desvio contra o NTP.br/ON, com registro e alerta acima de 30 s |
| 3 | Todo coletor exibe relógio não analógico com horas, minutos e segundos no momento da marcação | **Falta** | O app do ponto **não mostra relógio** (bloqueante). WhatsApp e URA: o comprovante depois **não atende** na leitura literal (`juridico`). Mitigação: antes de gravar, mostrar ou falar a hora do servidor com segundos e pedir confirmação (WhatsApp risco médio; URA médio a alto); alternativa conservadora: o WhatsApp manda o link da tela do app |
| 4 e 5 | Coletor on-line; off-line só excepcionalmente, com envio posterior seguro | **Atende** | Só on-line: sem conexão não há marcação (não existe modo off-line) |
| 6 | Armazenamento (ARP) com redundância, alta disponibilidade e confiabilidade | **Conferir** | Supabase (banco gerenciado, backup diário próprio e cópias cifradas fora, decisão 51); dizer o plano e o SLA do fornecedor |
| 6.1 | Inclusão e alteração do empregador, com data, hora e responsável | **Atende** | Tipo 2 (migration 157); depende do CPF do responsável cadastrado |
| 6.2 | Ajuste do relógio, com antes, depois e responsável | **Atende (não se aplica)** | Não há ajuste manual do relógio: a hora vem do servidor; declarar no Atestado |
| 6.3 | Inclusão, alteração e exclusão de empregado, com responsável | **Atende** | Tipo 5 I/A/E (migration 157) |
| 6.4 | Eventos sensíveis do REP | **Falta** | Não registramos indisponibilidade nem retorno (tipo 6 do AFD). Proposta: gravar a partir do monitoramento (vigia e checklist de saúde) |
| 6.5 e 10 | Marcação com NSR, CPF, data, hora e fuso da marcação e da gravação, coletor e SHA-256 | **Atende** | `ponto_marcacoes` (momento com fuso, empresa com fuso, canal, hash encadeado) |
| OBS | NSR próprio por **estabelecimento**, começando em 1 | **Conferir** | Hoje por empresa (CNPJ, `ponto_nsr`); atende se cada estabelecimento for uma empresa cadastrada (a Infoxtec tem filial?) |
| 7 | Nada apagado ou alterado no prazo legal | **Atende** | Gatilhos de imutabilidade em linha e truncate; âncora diária fora do banco; o reinício de 13/11 foi antes do uso oficial (ata) |
| 8 | Identificação inequívoca, hora confiável, gravação e comprovante | **Conferir** | Identificação por código de uso único, telefone conferido ou PIN da URA; comprovante depende das linhas 3 e 4 do quadro 1 |
| 11 e 12 | AFD a partir da ARP, por intervalo de datas | **Atende** | `app_ponto_afd(empresa, de, ate)` e AFD completo |
| 13 | Alta disponibilidade em todas as etapas | **Conferir** | Três canais independentes (app, WhatsApp, URA); o WhatsApp depende de um servidor único (Oracle). Registrar a disponibilidade medida |

## 3. O que falta para assinar, em ordem

1. **Certificado do INPI** (e-Software): processo em andamento não basta (Arts. 78, 79 VII e 91). Responsável.
2. **Retirar os dois bloqueios** (afastamento e WhatsApp sem localização): aceitar e sinalizar (Arts. 74 e 98). Muda
   a decisão 60: responsável.
3. **Relógio com segundos no app**; WhatsApp e URA mostram ou falam a hora do servidor antes de gravar.
4. **Comprovante em PDF assinado (PAdES)**, com o hash igual ao do AFD. Hipótese do `juridico`: assinar quando o
   comprovante é aberto pode bastar. Onde fica o certificado: CTO e `seguranca`.
5. **Evidência do relógio (HLB ± 30 s)** — medição registrada e alerta.
6. **Eventos sensíveis (tipo 6)** — gravar indisponibilidade e retorno.
7. **Conferência do leiaute do AFD e do AEJ** contra o gov.br e com a contadora; procedimento de assinatura no prazo.
8. Conferir Art. 79 IV, Art. 80 II e III, Art. 84 campo a campo, NSR por estabelecimento, Arts. 100 e 101.
9. **e-CPF**; preencher e assinar o(s) Atestado(s) em PDF/PAdES.

**Se não ficar pronto em 01/12** (`juridico`): adiar o uso oficial e manter o controle atual (registro manual é
permitido, CLT art. 74 §2º; trabalho externo, §3º), evitando dois registros que se contradigam. Assinar o Atestado
sabendo que algo falta é risco penal e pessoal do signatário (Código Penal, art. 299).
