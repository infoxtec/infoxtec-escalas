-- Backlog: marcar o que foi concluído
-- Rodar UMA vez no SQL Editor da PRODUÇÃO (projeto zpckrxydqqmmcrphrkxz).
--
-- Exceção combinada em 26/09 (CLAUDE.md): o registro do backlog vai direto na produção, na tabela
-- `backlog_itens` e só nela. O SQL Editor roda sem JWT, então `app_mover_backlog_item` não pode ser
-- usada (o `app_exigir` dela exige sessão de admin) — este script faz o mesmo que ela faria:
-- `coluna`, `status`, `entregue_em`, `observacao` e `updated_at`.
--
-- Colunas válidas (migration 28): backlog | a_fazer | fazendo | revisao | feito
-- Status válidos (migration 26): planejado | em_andamento | parcial | bloqueado | concluido

-- 1. Antes: veja o que vai mudar ---------------------------------------------------------------
select numero, titulo, coluna, status, entregue_em
  from backlog_itens
 where numero in (2, 3, 5, 10, 11, 12, 13, 64, 65)
 order by numero;

-- 2. Concluídos e parciais ---------------------------------------------------------------------
-- Sete vão para `feito`; dois ficam em `revisao` porque a entrega é parcial e há tema aberto no
-- painel de temas (a observação registra qual).
with alvo(numero, coluna, status, entregue_em, observacao) as (
  values
    ( 5, 'feito',   'concluido', date '2026-09-25', null),
    (10, 'feito',   'concluido', date '2026-09-24', null),
    (11, 'feito',   'concluido', date '2026-09-24', null),
    (12, 'feito',   'concluido', date '2026-09-24', null),
    (13, 'feito',   'concluido', date '2026-09-24', null),
    (64, 'feito',   'concluido', date '2026-09-28', null),
    (65, 'feito',   'concluido', date '2026-09-28', null),
    ( 2, 'revisao', 'parcial',   null,
     'URA de voz entregue em 23/09 e testada em produção. Falta ligar o bloqueio da assinatura da Twilio — tema SEG-05 no painel de temas.'),
    ( 3, 'revisao', 'parcial',   null,
     'Painel por local entregue em versão parcial; o percentual real de conclusão depende do item 001.')
)
update backlog_itens b
   set coluna     = a.coluna,
       status     = a.status,
       entregue_em = coalesce(b.entregue_em, a.entregue_em),
       observacao = coalesce(a.observacao, b.observacao),
       updated_at = now()
  from alvo a
 where b.numero = a.numero
returning b.numero, b.titulo, b.coluna, b.status, b.entregue_em;

-- O campo `posicao` fica como está: o quadro deixa arrastar o cartão para a ordem que você quiser.

-- 3. Depois: confira o resultado -----------------------------------------------------------------
select coluna, count(*) as itens, min(entregue_em) as primeiro, max(entregue_em) as ultimo
  from backlog_itens
 group by coluna
 order by coluna;

select numero, titulo, coluna, status, entregue_em
  from backlog_itens
 where coluna in ('feito', 'revisao')
 order by coluna, numero;
