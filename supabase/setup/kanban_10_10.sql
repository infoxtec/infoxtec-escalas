-- Kanban (aba Roadmap) alinhado à revisão do backlog de 10/10 e à sprint de 13 a 23/10.
-- Onde roda: PRODUÇÃO (zpckrxydqqmmcrphrkxz), SQL Editor. Só toca a tabela backlog_itens (exceção do
-- backlog, CLAUDE.md). Pode rodar de novo sem duplicar: cada passo confere se já foi feito.
-- Esperado: a última consulta mostra 83 e 90 em "feito", 84 e 21 "parcial", 4 com "[Arquivado]" e um
-- item novo de segurança "P1 · Endurecimento da decisão 51" em "fazendo". Script de uma vez só: sai do
-- repositório depois de aplicado (o registro durável é docs/backlog.md).

begin;

update backlog_itens set coluna = 'feito', status = 'concluido', entregue_em = '2026-10-08', updated_at = now(),
  observacao = coalesce(observacao || E'\n', '') || '10/10: na produção desde 08/10 (migrations 56, 59 e 60: palavras-chave, botões, localização em tempo real, recusa de encaminhada).'
 where numero = 83 and coluna <> 'feito';

update backlog_itens set coluna = 'feito', status = 'concluido', entregue_em = '2026-10-08', updated_at = now(),
  observacao = coalesce(observacao || E'\n', '') || '10/10: na produção desde 08/10 (migration 56; Registro de Ponto na Agenda, com bairro, cidade e GPS pela migration 58).'
 where numero = 90 and coluna <> 'feito';

update backlog_itens set coluna = 'a_fazer', status = 'parcial', updated_at = now(),
  observacao = coalesce(observacao || E'\n', '') || '10/10: entrega 1 (avisos da CLT e espelho, migration 61, painel 3.13.0) na produção. Entrega 2 (ajustes com justificativa) na sprint 13–23/10. Decidido em 10/10 (decisão 52): leitura vê totais e avisos sem localização; aviso ao gestor com o primeiro nome, nunca CPF; ajuste por admin e gestor, com aviso ao funcionário pelo WhatsApp.'
 where numero = 84 and status <> 'parcial';

update backlog_itens set status = 'parcial', updated_at = now(),
  observacao = coalesce(observacao || E'\n', '') || '10/10: supabase/tests/regressao.sql no CI (permissões, ponto, WhatsApp, jornada, carga). Na sprint 13–23/10: fuso do motor e habilidades.'
 where numero = 21 and status <> 'parcial';

update backlog_itens set status = 'parcial', updated_at = now(),
  observacao = coalesce(observacao || E'\n', '') || '10/10: localização encaminhada ou repetida recusada (migration 60, produção 08/10). Falta testar o pino arrastado no mapa.'
 where numero = 87 and status <> 'parcial';

update backlog_itens set updated_at = now(),
  observacao = coalesce(observacao || E'\n', '') || '10/10: troca do token do webhook da Evolution na sprint (17/10) e desativação da chave service_role antiga (20/10).'
 where numero = 31 and coalesce(observacao, '') not like '%10/10: troca do token%';

update backlog_itens set updated_at = now(),
  observacao = coalesce(observacao || E'\n', '') || '10/10: prazo para ligar o bloqueio da assinatura da Twilio vence em 27/10; decidir na revisão da sprint (23/10).'
 where numero = 2 and coalesce(observacao, '') not like '%vence em 27/10%';

update backlog_itens set titulo = '[Arquivado] ' || titulo, posicao = 997, updated_at = now(),
  observacao = coalesce(observacao || E'\n', '') || '10/10: substituído pelo 075 (módulo de ponto próprio, decisão 48); a conciliação de escala com ponto faz parte do 084.'
 where numero = 4 and titulo not like '[Arquivado]%';

-- número atribuído pelo banco (gatilho trg_backlog_numero)
insert into backlog_itens (tipo, titulo, descricao, status, esforco, coluna, posicao, observacao)
select 'seguranca', 'P1 · Endurecimento da decisão 51: service_role, âncora do backup e token do webhook',
  'Parte 1: nenhuma função interna executável pelo service_role e suíte de regressão no CI (migration 62). Parte 2: âncora da cadeia do ponto no backup, conferida no dia seguinte e na restauração. Parte 3: token do webhook da Evolution no cabeçalho, troca do token e fim do token na URL. Pendência: revogar tabelas e sequências do service_role (migration 63) e desativar a chave antiga.',
  'em_andamento', 'M', 'fazendo', 0,
  '10/10: parte 1 na produção (08/10, conferida 24 h); parte 2 em operação (PR #67, primeiro backup com âncora em 09/10). Parte 3 e migration 63 na sprint 13–23/10.'
 where not exists (select 1 from backlog_itens where titulo like 'P1 · Endurecimento da decisão 51%');

commit;

-- Conferência
select lpad(numero::text, 3, '0') as numero, coluna, status, left(titulo, 70) as titulo
  from backlog_itens
 where numero in (2, 4, 21, 31, 83, 84, 87, 90) or titulo like 'P1 · Endurecimento da decisão 51%'
 order by numero;
