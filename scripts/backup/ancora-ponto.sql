-- Âncora da cadeia de marcações do ponto (decisão 51, parte 2). Roda no backup diário, ANTES do
-- dump, numa transação só de leitura: confere que ponto_nsr concorda com as marcações (quantidade,
-- maior NSR e hash da última) e grava, por empresa, o último NSR e o último hash em
-- copia/ancora-ponto.csv — que vai dentro do arquivo criptografado. Quem reescrevesse a cadeia
-- inteira de forma consistente no banco não reescreve as âncoras já guardadas fora dele.
-- Divergência ou marcação sem âncora = erro, e o backup falha (melhor que guardar prova vazia).
--   psql "$URL" -X -q -f scripts/backup/ancora-ponto.sql
\set ON_ERROR_STOP on
begin transaction isolation level repeatable read read only;
set local search_path = pg_catalog, pg_temp;
\ir tipos-ponto.sql

do $$
declare r record; v_esq text := pg_catalog.current_setting('ancora.esq');
begin
  for r in execute pg_catalog.format($q$
    select coalesce(n.empresa_id, m.empresa_id) as empresa, n.ultimo, n.ultimo_hash, m.qtd, m.maior,
           (select x.hash from %1$I.ponto_marcacoes x where x.empresa_id = n.empresa_id and x.nsr = n.ultimo) as hash_ultima
      from %1$I.ponto_nsr n
      full join (select empresa_id, count(*) as qtd, max(nsr) as maior from %1$I.ponto_marcacoes group by 1) m
        on m.empresa_id = n.empresa_id$q$, v_esq)
  loop
    if r.ultimo is null then
      raise exception 'âncora: empresa % tem marcações e não tem ponto_nsr', r.empresa;
    end if;
    if coalesce(r.qtd, 0) <> r.ultimo or coalesce(r.maior, 0) <> r.ultimo then
      raise exception 'âncora: empresa % com ponto_nsr divergente das marcações', r.empresa;
    end if;
    if r.ultimo > 0 and r.hash_ultima is distinct from r.ultimo_hash then
      raise exception 'âncora: empresa % com hash da última marcação divergente', r.empresa;
    end if;
  end loop;
end $$;

-- \copy não troca variáveis do psql: COPY ... TO STDOUT com \g grava no arquivo e aceita o :"esq" (psql 14+)
copy (select empresa_id, ultimo, ultimo_hash, to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') from :"esq".ponto_nsr order by empresa_id) to stdout with (format csv) \g 'copia/ancora-ponto.csv'
