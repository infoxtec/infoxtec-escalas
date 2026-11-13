#!/usr/bin/env bash
# Confere na produção, em transação só de leitura, que a âncora do backup anterior continua valendo:
# cada (empresa, NSR, hash) dela ainda existe igual. Quem reescrevesse a cadeia (mesmo de forma
# consistente) entre um backup e outro mudaria o hash ancorado, e o backup falha.
#
# Única exceção (decisão 138, migration 155): o reinício do módulo de ponto antes do uso oficial. A linha da âncora
# que sumiu só é aceita se TUDO valer:
#   - interno.ponto_reinicios tem um registro feito depois da âncora, com aquela empresa e NSR maior, ou igual com o
#     mesmo hash (o backup é disparado à mão logo antes; uma marcação no meio não trava os backups para sempre);
#   - a cadeia atual da empresa recomeçou de fato: menor NSR 1 (ou nenhuma marcação) e nenhuma marcação de antes
#     do reinício;
#   - os registros de reinício não passam do autorizado fora do banco, em .github/workflows/reinicios-ponto-autorizados.txt
#     (cada um dentro de uma janela dali; mudar o arquivo exige o merge do responsável).
# Aceitar avisa com ::warning:: (a execução não falha: só a que passa guarda a âncora nova).
#   scripts/backup/ancora-anterior.sh <arquivo.csv>   (usa $URL)
set -euo pipefail
arq="$1"
dir="$(cd "$(dirname "$0")" && pwd)"
autorizados="$dir/../../.github/workflows/reinicios-ponto-autorizados.txt"
valores=""
while IFS= read -r linha; do
  # só aceita o formato que o próprio backup grava (nada do arquivo vai cru para o SQL)
  if ! [[ "$linha" =~ ^([0-9a-f-]{36}),([0-9]+),([0-9a-f]{64}),([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$ ]]; then
    echo "::error::Âncora anterior em formato inesperado"; exit 1
  fi
  valores+="${valores:+,}('${BASH_REMATCH[1]}'::uuid, ${BASH_REMATCH[2]}::bigint, '${BASH_REMATCH[3]}', '${BASH_REMATCH[4]}'::timestamptz)"
done < "$arq"
if [ -z "$valores" ]; then echo "Âncora anterior sem empresas (nada a conferir)"; exit 0; fi

janelas=""
if [ -f "$autorizados" ]; then
  while IFS= read -r linha; do
    [[ -z "$linha" || "$linha" == \#* ]] && continue
    if ! [[ "$linha" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
      echo "::error::Linha fora do formato em reinicios-ponto-autorizados.txt"; exit 1
    fi
    janelas+="${janelas:+,}('${BASH_REMATCH[1]}'::date, '${BASH_REMATCH[2]}'::date)"
  done < "$autorizados"
fi

saida=$(psql "$URL" -X -A -t -v ON_ERROR_STOP=1 -v VERBOSITY=terse \
  -v tipos="$dir/tipos-ponto.sql" -v valores="$valores" -v janelas="$janelas" <<'SQL'
begin transaction read only;
set local search_path = pg_catalog, pg_temp;
\i :tipos
select pg_catalog.set_config('ancora.valores', :'valores', true);
select pg_catalog.set_config('ancora.janelas', :'janelas', true);
do $$
declare
  v_esq text := pg_catalog.current_setting('ancora.esq');
  v_jan text := pg_catalog.current_setting('ancora.janelas');
  v_tem boolean := pg_catalog.to_regclass(v_esq || '.ponto_reinicios') is not null;
  v_falt bigint; v_aceitas bigint := 0; v_fora bigint; v_qtd bigint;
begin
  if v_tem then
    if (select c.relkind from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
         where n.nspname = v_esq and c.relname = 'ponto_reinicios') is distinct from 'r' then
      raise exception 'âncora: %.ponto_reinicios não é uma tabela comum', v_esq;
    end if;
    -- tipos das colunas usadas (ninguém troca a tabela por uma com "=" que sempre concorda)
    if (select pg_catalog.count(*) from pg_catalog.pg_attribute a
         where a.attrelid = pg_catalog.to_regclass(v_esq || '.ponto_reinicios') and not a.attisdropped
           and (a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod)) in
               (('feito_em', 'timestamp with time zone'), ('empresas', 'jsonb'))) <> 2 then
      raise exception 'âncora: colunas de ponto_reinicios fora do esperado';
    end if;
    execute pg_catalog.format('select pg_catalog.count(*) from %I.ponto_reinicios', v_esq) into v_qtd;
    if v_qtd > 0 then
      if v_jan = '' then raise exception 'âncora: há reinício do ponto na produção e nenhum autorizado no repositório'; end if;
      execute pg_catalog.format('select pg_catalog.count(*) from (values %s) j(ini, fim)', v_jan) into v_fora;
      if v_qtd > v_fora then raise exception 'âncora: % reinício(s) do ponto na produção e só % autorizado(s)', v_qtd, v_fora; end if;
      execute pg_catalog.format('select pg_catalog.count(*) from %I.ponto_reinicios r
          where not exists (select 1 from (values %s) j(ini, fim)
                             where (r.feito_em at time zone ''UTC'')::date between j.ini and j.fim)', v_esq, v_jan) into v_fora;
      if v_fora > 0 then raise exception 'âncora: reinício do ponto fora da janela autorizada'; end if;
    end if;
  end if;

  execute pg_catalog.format($q$
    select pg_catalog.count(*) filter (where not a.reiniciada), pg_catalog.count(*) filter (where a.reiniciada)
      from (select x.*, %2$s as reiniciada
              from (values %1$s) x(empresa_id, nsr, hash, gerada)
             where x.nsr > 0 and not exists (select 1 from %3$I.ponto_marcacoes m
                     where m.empresa_id = x.empresa_id and m.nsr = x.nsr and m.hash = x.hash)) a$q$,
    pg_catalog.current_setting('ancora.valores'),
    case when v_tem then pg_catalog.format($r$exists (select 1 from %1$I.ponto_reinicios r
         cross join lateral pg_catalog.jsonb_to_recordset(r.empresas) e(empresa_id uuid, ultimo_nsr bigint, ultimo_hash text)
         where r.feito_em > x.gerada and e.empresa_id = x.empresa_id
           and (e.ultimo_nsr > x.nsr or (e.ultimo_nsr = x.nsr and e.ultimo_hash = x.hash))
           and coalesce((select pg_catalog.min(m.nsr) from %1$I.ponto_marcacoes m where m.empresa_id = x.empresa_id), 1) = 1
           and not exists (select 1 from %1$I.ponto_marcacoes m where m.empresa_id = x.empresa_id and m.momento <= r.feito_em))$r$, v_esq)
         else 'false' end,
    v_esq) into v_falt, v_aceitas;
  perform pg_catalog.set_config('ancora.faltando', v_falt::text, true);
  perform pg_catalog.set_config('ancora.reiniciadas', v_aceitas::text, true);
end $$;
select 'FALTANDO=' || pg_catalog.current_setting('ancora.faltando') || ' REINICIADAS=' || pg_catalog.current_setting('ancora.reiniciadas');
rollback;
SQL
)
faltando=$(echo "$saida" | sed -n 's/^FALTANDO=\([0-9]*\) REINICIADAS=.*/\1/p' | head -1)
reiniciadas=$(echo "$saida" | sed -n 's/^FALTANDO=[0-9]* REINICIADAS=\([0-9]*\)$/\1/p' | head -1)
if [ "$faltando" != "0" ]; then
  echo "::error::Âncora do backup anterior não confere na produção (${faltando:-?} empresa(s)): cadeia do ponto alterada. Tratar como incidente (docs/operacao.md, Backup)."
  exit 1
fi
if [ "${reiniciadas:-0}" != "0" ]; then
  echo "::warning::Âncora anterior de $reiniciadas empresa(s) aceita pelo reinício autorizado do módulo de ponto (decisão 138). Conferir que é o reinício esperado."
fi
echo "Âncora do backup anterior confere na produção"
