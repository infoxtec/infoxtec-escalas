# Ata do reinício do módulo de registro de ponto

Registro interno (decisão 138; LGPD art. 37). Sem dado de pessoa. Os campos marcados com ⏳ são preenchidos depois da
execução na produção.

**Empregador:** Infoxtec (e as demais contas da instalação Trilha).
**Autorização:** David Cerqueira, responsável, em 13/11/2026.
**Execução:** migration 156 pelo workflow Aplicar, com aprovação do responsável no ambiente `producao` do GitHub.
⏳ Data e hora: ____ · ⏳ Execução do Aplicar: ____ · ⏳ Backup disparado antes: ____

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

⏳ Contagens por tabela (de `interno.ponto_reinicios.contagens`): ____

**Não foram alterados:** cadastro de funcionários, escalas, motivos de ajuste, locais e configurações das empresas.

## 3. Depois do reinício

- O registro de ponto oficial começa em **01/12/2026**. O NSR de cada empresa recomeça em **1**.
- AFDs, espelhos e comprovantes gerados até 30/11/2026 são de teste e **não têm validade**.
- Todos os funcionários dão nova ciência das regras do ponto no primeiro uso oficial.
- Cópias residuais, cifradas e de acesso restrito, que vencem sozinhas: backup diário (30 dias), cópias no Drive e no
  OneDrive (até 12 meses), backup do Supabase (cerca de 7 dias), mensagens no log do WhatsApp (até 30 dias).
  Restaurar uma cópia anterior ao reinício exige repetir o reinício antes de reabrir o sistema.

## 4. Assinaturas

Responsável: ______________________ Data: __/__/____

Contadora (recomendado pelo `juridico`): ______________________ Data: __/__/____
