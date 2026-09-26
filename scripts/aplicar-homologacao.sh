#!/usr/bin/env bash
# Aplica as migrations do repositorio no banco de HOMOLOGACAO (infoxtec-escalas-dev).
# Uso, de qualquer pasta dentro do repositorio:  ./scripts/aplicar-homologacao.sh
set -euo pipefail

DEV=oruwnlxyvznpigbpjjbx

raiz=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Rode dentro da pasta do repositorio (~/infoxtec-escalas)."; exit 1; }
cd "$raiz"
[ -d supabase/migrations ] || { echo "Pasta supabase/migrations nao encontrada em $raiz."; exit 1; }

echo "== Repositorio: $raiz"
echo "== Branch: $(git branch --show-current)"
echo "== Migrations no repositorio: $(ls supabase/migrations/*.sql | wc -l)"
echo

npx supabase link --project-ref "$DEV"
[ "$(cat supabase/.temp/project-ref)" = "$DEV" ] || { echo "O link nao ficou na homologacao. Nada foi aplicado."; exit 1; }

echo
echo "== Situacao das migrations (Local = repositorio, Remote = homologacao)"
npx supabase migration list
echo
npx supabase db push

echo
echo "Pronto. Teste no painel local:  cd web && npm run dev -- --host"
