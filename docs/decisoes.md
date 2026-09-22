# Decisões de arquitetura

Registro do que foi decidido, quando e por quê — inclusive o que foi descartado.

## 1. Regra de negócio no banco, não no painel

**Decisão:** toda regra em SQL (views e funções); o painel só chama funções.
**Por quê:** permite trocar de painel sem reescrever regra — o que de fato aconteceu na migração
do Retool para o Vercel. Mudanças de regra entram sem deploy.
**Custo:** quem mantém precisa saber SQL; depurar PL/pgSQL é mais chato que depurar TypeScript.

## 2. Supabase no lugar do n8n

**Decisão:** `pg_cron` + `pg_net` + Edge Function, sem orquestrador externo.
**Por quê:** o n8n era o único item pago (~R$ 130/mês) de uma stack que precisava custar zero.
**Descartado:** n8n Cloud (pago) e n8n auto-hospedado (servidor a manter).

## 3. Evolution API no lugar da API oficial da Meta

**Decisão:** Evolution API em VPS própria.
**Por quê:** decisão do cliente, com VPS já disponível.
**Ressalva registrada:** a Meta custaria cerca de R$ 8 a R$ 11 por mês para o volume atual,
sem risco de banimento e com botões garantidos. A Evolution usa biblioteca não oficial, o que
viola os termos do WhatsApp e expõe o número a bloqueio.
**Mitigações:** chip dedicado, no máximo 3 tentativas, envios espaçados, janela de silêncio.

## 4. Botões com resposta numérica junto

**Decisão:** enviar botões e, no mesmo texto, "responda 1 ou 2".
**Por quê:** na Evolution 2.3 os botões chegavam como "visualização única" e não abriam no
celular. Na 2.4 passaram a funcionar. Como isso pode quebrar de novo numa atualização do
WhatsApp, o caminho numérico sempre acompanha. `usar_botoes` desliga os botões sem deploy.

## 5. Envio em duas fases

**Decisão:** marcar `enviada` só depois de conferir a resposta da Evolution.
**Por quê:** o dispatcher anterior marcava como enviada antes da confirmação e o painel mostrava
"notificada" para mensagens que tinham falhado com erro 400.

## 6. Painel próprio no Vercel em vez do Retool

**Decisão:** React + Vite publicado no Vercel.
**Por quê:** o Retool travou em três limites — créditos de IA para qualquer alteração, código
somente leitura e teto de 5 usuários no plano gratuito.
**Ressalva registrada:** o plano Hobby do Vercel é restrito a uso não comercial pela definição
da própria Vercel, que considera comercial qualquer projeto produzido por funcionário pago.
O Cloudflare Pages não tem essa cláusula.

## 7. Jornada calculada, sem campo de duração

**Decisão:** o término vem da CLT, a partir da hora de início.
**Por quê:** evita que cada escala tenha uma duração digitada à mão, e garante coerência entre
o que o técnico recebe e a jornada legal.
**A validar:** a regra deve ser confirmada pelo RH. Não é parecer jurídico.

## 8. Exclusão definitiva apaga o histórico

**Decisão:** excluir técnico remove escalas, mensagens e auditoria dele.
**Por quê:** "removido" significa removido, e atende pedido de exclusão de dados pessoais.
**Travas:** não exclui quem tem escala aberta, nem o último supervisor ativo; exige digitar o
nome para confirmar; registra em `log_exclusoes`.

## 9. Cancelada libera o horário

**Decisão:** índice único parcial ignorando `cancelada`.
**Por quê:** escala cancelada não ocupa mais o horário do técnico.
**Em aberto:** escalas `recusadas` ainda bloqueiam o horário.

## 10. Habilidades sem controle de validade

**Decisão:** o cadastro de habilidades não guarda data de vencimento de certificação.
**Por quê:** pedido do cliente — o controle de validade de NR e CNH é feito fora do sistema.
**Consequência:** o alerta semanal de certificações vencidas não roda. As colunas `validade` e
`exige_validade` seguem no banco, dormentes; religar é mudar `alerta_certificacoes_dow` de `0`
para o dia da semana desejado e voltar os campos na tela.
