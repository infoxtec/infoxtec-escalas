#!/usr/bin/env bash
# Aplica as migrations do repositorio no banco de PRODUCAO (infoxtec-escalas).
# So roda a partir da main atualizada, mostra o que vai ser aplicado, pede confirmacao escrita
# e, ao terminar (com sucesso ou nao), volta o link para a homologacao.
# Uso:  ./scripts/aplicar-producao.sh
set -euo pipefail

DEV=oruwnlxyvznpigbpjjbx
PROD=zpckrxydqqmmcrphrkxz

raiz=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Rode dentro da pasta do repositorio (~/infoxtec-escalas)."; exit 1; }
cd "$raiz"
[ -d supabase/migrations ] || { echo "Pasta supabase/migrations nao encontrada em $raiz."; exit 1; }

# 1. Producao so recebe o que ja esta na main
git fetch --quiet origin main
if [ "$(git branch --show-current)" != "main" ]; then
  echo "Voce esta na branch '$(git branch --show-current)'. Producao so a partir da main:"
  echo "  git checkout main && git pull"
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Ha arquivos alterados e nao commitados. Resolva antes de aplicar em producao."
  exit 1
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Sua main esta diferente da main do GitHub. Rode: git pull"
  exit 1
fi

# 2. Ao sair, por qualquer motivo, volta para a homologacao
voltar_para_dev() {
  echo
  echo "== Voltando o link para a homologacao"
  npx supabase link --project-ref "$DEV" || echo "ATENCAO: rode 'npx supabase link --project-ref $DEV' antes de continuar."
}
trap voltar_para_dev EXIT

npx supabase link --project-ref "$PROD"
[ "$(cat supabase/.temp/project-ref)" = "$PROD" ] || { echo "O link nao ficou na producao. Nada foi aplicado."; exit 1; }

# 3. Mostra o que vai acontecer
echo
echo "== Situacao das migrations (Local = repositorio, Remote = PRODUCAO)"
npx supabase migration list
echo
echo "Confira: as versoes que aparecem so em Local sao as que serao aplicadas agora."
read -r -p "Para aplicar na PRODUCAO, digite PRODUCAO: " resposta
[ "$resposta" = "PRODUCAO" ] || { echo "Cancelado. Nada foi aplicado."; exit 1; }

npx supabase db push

echo
echo "Aplicado em producao. Faca o teste da etapa no painel: https://infoxtec-escalas.vercel.app"
