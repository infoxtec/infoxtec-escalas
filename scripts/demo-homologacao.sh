#!/usr/bin/env bash
# Demonstração com dados fictícios na HOMOLOGAÇÃO (backlog 101, decisão 80).
# Uso, de qualquer pasta dentro do repositório:
#   ./scripts/demo-homologacao.sh criar    # empresa fictícia, 10 técnicos, 5 locais, uma semana de escalas
#   ./scripts/demo-homologacao.sh apagar   # remove tudo o que o "criar" fez
# Roda só no projeto de homologação; o SQL também se recusa a rodar num banco com tarefas no pg_cron.
set -euo pipefail

DEV=oruwnlxyvznpigbpjjbx

acao=${1:-}
case "$acao" in
  criar|apagar) ;;
  *) echo "Uso: $0 criar | apagar"; exit 1 ;;
esac

raiz=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Rode dentro da pasta do repositorio (~/infoxtec-escalas)."; exit 1; }
cd "$raiz"
arquivo="supabase/demo/$acao.sql"
[ -f "$arquivo" ] || { echo "Arquivo $arquivo nao encontrado."; exit 1; }

echo "== Demonstracao: $acao na HOMOLOGACAO ($DEV)"
npx --yes supabase@2.118.0 link --project-ref "$DEV"
[ "$(cat supabase/.temp/project-ref)" = "$DEV" ] || { echo "O link nao ficou na homologacao. Nada foi feito."; exit 1; }
npx --yes supabase@2.118.0 db query --linked --file "$arquivo"
echo
if [ "$acao" = criar ]; then
  echo "Pronto. No painel da homologacao: Escalas (semana atual), Indicadores (ultimos dias) e Locais > Dossie"
  echo "(Torre Comercial Vento Leste, data de hoje se nao for domingo: dois funcionarios pendentes). Para remover: $0 apagar"
else
  echo "Pronto. Demonstracao removida."
fi
