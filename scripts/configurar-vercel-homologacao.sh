#!/usr/bin/env bash
# Faz os deploys de teste (Preview) e o ambiente Development da Vercel usarem o banco de
# HOMOLOGACAO. As variaveis de Production nao sao tocadas.
# Pre-requisito, uma vez: cd web && npx vercel login && npx vercel link  (equipe infoxtec-escalas, projeto web)
# Uso:  ./scripts/configurar-vercel-homologacao.sh
set -euo pipefail

raiz=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Rode dentro da pasta do repositorio."; exit 1; }
cd "$raiz/web"
[ -f .vercel/project.json ] || { echo "Pasta web ainda nao ligada a Vercel. Rode: cd web && npx vercel link"; exit 1; }

URL_DEV="https://oruwnlxyvznpigbpjjbx.supabase.co"
CHAVE_DEV="sb_publishable_aMlvBNYhUoGGsohsEfiFTA_6So6G1p_"

for ambiente in preview development; do
  npx vercel env add VITE_SUPABASE_URL      "$ambiente" --value "$URL_DEV"   --no-sensitive --yes --force
  npx vercel env add VITE_SUPABASE_ANON_KEY "$ambiente" --value "$CHAVE_DEV" --no-sensitive --yes --force
done

echo
echo "== Como ficou (esperado: cada variavel em Production, Preview e Development)"
npx vercel env ls
