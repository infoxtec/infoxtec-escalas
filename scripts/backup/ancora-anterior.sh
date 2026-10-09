#!/usr/bin/env bash
# Confere na produção, em transação só de leitura, que a âncora do backup anterior continua valendo:
# cada (empresa, NSR, hash) dela ainda existe igual. Quem reescrevesse a cadeia (mesmo de forma
# consistente) entre um backup e outro mudaria o hash ancorado, e o backup falha.
#   scripts/backup/ancora-anterior.sh <arquivo.csv>   (usa $URL)
set -euo pipefail
arq="$1"
valores=""
while IFS= read -r linha; do
  # só aceita o formato que o próprio backup grava (nada do arquivo vai cru para o SQL)
  if ! [[ "$linha" =~ ^([0-9a-f-]{36}),([0-9]+),([0-9a-f]{64}),[0-9TZ:-]+$ ]]; then
    echo "::error::Âncora anterior em formato inesperado"; exit 1
  fi
  valores+="${valores:+,}('${BASH_REMATCH[1]}'::uuid, ${BASH_REMATCH[2]}::bigint, '${BASH_REMATCH[3]}')"
done < "$arq"
if [ -z "$valores" ]; then echo "Âncora anterior sem empresas (nada a conferir)"; exit 0; fi
faltando=$(psql "$URL" -X -A -t -v ON_ERROR_STOP=1 -v VERBOSITY=terse <<SQL
begin transaction read only;
set local search_path = pg_catalog, pg_temp;
\\i $(dirname "$0")/tipos-ponto.sql
select count(*) from (values $valores) a(empresa_id, nsr, hash)
 where a.nsr > 0 and not exists (select 1 from public.ponto_marcacoes m
         where m.empresa_id = a.empresa_id and m.nsr = a.nsr and m.hash = a.hash);
rollback;
SQL
)
faltando=$(echo "$faltando" | grep -E '^[0-9]+$' | head -1)
if [ "$faltando" != "0" ]; then
  echo "::error::Âncora do backup anterior não confere na produção ($faltando empresa(s)): cadeia do ponto alterada. Tratar como incidente (docs/operacao.md, Backup)."
  exit 1
fi
echo "Âncora do backup anterior confere na produção"
