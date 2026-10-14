#!/usr/bin/env bash
# Aplica as migrations do repositorio no banco de PRODUCAO (infoxtec-escalas).
# So roda a partir da main atualizada, mostra o que vai ser aplicado, pede confirmacao escrita
# e, ao terminar (com sucesso ou nao), volta o link para a homologacao.
# Uso:  ./scripts/aplicar-producao.sh                       aplica todas as pendentes
#       ./scripts/aplicar-producao.sh --ate 20261014130000   aplica só até essa versão (inclusive); as
#                                                            seguintes ficam para outro dia (decisão 77)
set -euo pipefail

ATE=""
if [ "${1:-}" = "--ate" ]; then
  ATE="${2:-}"
  [[ "$ATE" =~ ^[0-9]{14}$ ]] || { echo "Use --ate com a versão de 14 dígitos, ex.: --ate 20261014130000"; exit 1; }
elif [ -n "${1:-}" ]; then
  echo "Opção desconhecida: $1. Uso: ./scripts/aplicar-producao.sh [--ate VERSAO]"; exit 1
fi

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

# 2. Ao sair, por qualquer motivo, volta para a homologacao (e devolve as migrations guardadas pelo --ate)
GUARDADAS=""
voltar_para_dev() {
  if [ -n "$GUARDADAS" ] && [ -d "$GUARDADAS" ]; then
    mv "$GUARDADAS"/*.sql supabase/migrations/ 2>/dev/null || true
    rmdir "$GUARDADAS" 2>/dev/null || true
    echo "Migrations depois de $ATE devolvidas à pasta (nada delas foi aplicado)."
  fi
  echo
  echo "== Voltando o link para a homologacao"
  npx --yes supabase@2.118.0 link --project-ref "$DEV" || echo "ATENCAO: rode 'npx --yes supabase@2.118.0 link --project-ref $DEV' antes de continuar."
}
trap voltar_para_dev EXIT

npx --yes supabase@2.118.0 link --project-ref "$PROD"

# --ate: as migrations depois da versão saem da pasta só durante o push (voltam na saída, por qualquer motivo)
if [ -n "$ATE" ]; then
  [ -n "$(ls supabase/migrations/"${ATE}"_*.sql 2>/dev/null)" ] || { echo "Não existe migration com a versão $ATE. Nada foi aplicado."; exit 1; }
  GUARDADAS=$(mktemp -d)
  for f in supabase/migrations/*.sql; do
    v=$(basename "$f" | cut -d_ -f1)
    if [ "$v" \> "$ATE" ]; then mv "$f" "$GUARDADAS/"; fi
  done
  echo "Aplicando só até $ATE. Ficam para outro dia: $(ls "$GUARDADAS" | tr '\n' ' ')"
fi
[ "$(cat supabase/.temp/project-ref)" = "$PROD" ] || { echo "O link nao ficou na producao. Nada foi aplicado."; exit 1; }

# 3. Mostra o que vai acontecer
echo
echo "== Situacao das migrations (Local = repositorio, Remote = PRODUCAO)"
npx --yes supabase@2.118.0 migration list
echo
echo "Confira: as versoes que aparecem so em Local sao as que serao aplicadas agora."
read -r -p "Para aplicar na PRODUCAO, digite PRODUCAO: " resposta
[ "$resposta" = "PRODUCAO" ] || { echo "Cancelado. Nada foi aplicado."; exit 1; }

npx --yes supabase@2.118.0 db push

echo
echo "Aplicado em producao. Faca o teste da etapa no painel: https://infoxtec-escalas.vercel.app"
