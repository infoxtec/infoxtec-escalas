# Ata do reinício do módulo de registro de ponto

Registro interno (decisão 138; LGPD art. 37). Sem dado de pessoa.

**Empregador:** Infoxtec (e as demais contas da instalação Trilha).
**Autorização:** David Cerqueira, responsável, em 13/11/2026.
**Execução:** migration 156 pelo workflow Aplicar, com aprovação do responsável no ambiente `producao` do GitHub.
Data e hora: **13/11/2026, 11:10:21 UTC (08:10 em Salvador)** · Aplicar: execução 43414662036 (migrations 152 a 156) ·
Backup disparado antes: execução 43414290022 (concluída com sucesso às 11:08 UTC).

## 1. Declaração

Os registros do módulo de ponto existentes na produção até o reinício foram gerados **exclusivamente em teste** do
sistema. O responsável confirmou, em 13/11/2026, que:

1. nenhum funcionário registrou ponto pelo sistema em dia de trabalho real;
2. nenhum espelho, AFD ou fechamento do sistema entrou em folha de pagamento ou serviu para pagar ou descontar valores;
3. nenhum atestado real de ausência real foi enviado pelo sistema;
4. não há reclamação trabalhista nem fiscalização em andamento.

## 2. O que foi apagado (sem cópia)

Marcações (com o controle de NSR e a cadeia de hash), ajustes, abonos, justificativas e atestados, pedidos de hora
extra, espelhos e PDFs, fechamentos, AFDs gerados, documentos do ponto, ciências, conversas, códigos, sessões,
acessos e o cache de bairro e cidade das marcações.

Contagens apagadas (de `interno.ponto_reinicios.contagens`; tabelas sem linhas omitidas):

| Tabela | Linhas |
|---|---|
| Marcações (`ponto_marcacoes`) | 23 |
| Controle de NSR (`ponto_nsr`) | 1 |
| Abonos | 17 |
| Ajustes | 2 |
| Justificativas | 6 |
| Anexos das justificativas (atestados) | 4 |
| Acessos aos anexos | 16 |
| Documentos do ponto (registros e sequência) | 4 e 1 |
| AFDs gerados | 3 |
| Ciências | 4 |
| Conversas, sessões e acessos do app | 2, 6 e 2 |
| Cache de bairro e cidade | 9 |

Conferência depois da execução (responsável, SQL Editor, só leitura): 1 reinício registrado, 0 marcações, função de
reinício removida, 13 funcionários e 384 escalas (a função recusa e desfaz tudo se essas contagens mudarem).

**Não foram alterados:** cadastro de funcionários, escalas, motivos de ajuste, locais e configurações das empresas.

## 3. Depois do reinício

- O registro de ponto oficial começa em **01/12/2026**. O NSR de cada empresa recomeça em **1**.
- AFDs, espelhos e comprovantes gerados até 30/11/2026 são de teste e **não têm validade** (foram gerados 3 AFDs de teste:
  cópias baixadas devem ser descartadas).
- Todos os funcionários dão nova ciência das regras do ponto no primeiro uso oficial.
- Cópias residuais, cifradas e de acesso restrito, que vencem sozinhas: backup diário (30 dias), cópias no Drive e no
  OneDrive (até 12 meses), backup do Supabase (cerca de 7 dias), mensagens no log do WhatsApp (até 30 dias).
  Restaurar uma cópia anterior ao reinício exige repetir o reinício antes de reabrir o sistema.

## 4. Assinaturas

Responsável: ______________________ Data: __/__/____

Contadora (recomendado pelo `juridico`): ______________________ Data: __/__/____
