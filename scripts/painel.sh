#!/usr/bin/env bash
# Painel local em segundo plano: continua no ar depois que a janela do terminal é fechada.
#
#   ./scripts/painel.sh iniciar            # homologação, em http://localhost:5173
#   ./scripts/painel.sh iniciar producao   # produção,    em http://localhost:5174
#   ./scripts/painel.sh parar [modo]
#   ./scripts/painel.sh status
#   ./scripts/painel.sh log [modo]         # acompanha a saída (Ctrl+C sai do log, não para o painel)
#
# O painel só para com "parar", ao desligar a máquina Linux ou ao fechar o OrbStack.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$RAIZ/web"
ESTADO="$HOME/.infoxtec-painel"
mkdir -p "$ESTADO"

acao="${1:-status}"
modo="${2:-homologacao}"

case "$modo" in
  homologacao) porta=5173 ;;
  producao)    porta=5174 ;;
  *) echo "Modo desconhecido: $modo (use homologacao ou producao)"; exit 1 ;;
esac

pidfile="$ESTADO/$modo.pid"
logfile="$ESTADO/$modo.log"

rodando() { [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

case "$acao" in
  iniciar)
    if rodando; then
      echo "Painel de $modo já está no ar: http://localhost:$porta"; exit 0
    fi
    cd "$WEB"
    # dependências novas (depois de um git pull): instala antes de subir
    if [[ ! -d node_modules || package-lock.json -nt node_modules ]]; then
      echo "Instalando dependências..."
      npm install --no-audit --no-fund
      touch node_modules
    fi
    if ! grep -q "\"dev:$modo\"" package.json; then
      echo "Este checkout não tem o script dev:$modo. Rode: git fetch && git checkout main && git pull"; exit 1
    fi
    # setsid + nohup: o processo sai da sessão do terminal e não morre quando a janela fecha
    setsid nohup npx vite --mode "$modo" --host --port "$porta" --strictPort >"$logfile" 2>&1 < /dev/null &
    echo $! > "$pidfile"
    sleep 4
    if rodando; then
      if [[ "$modo" == producao ]]; then
        echo "ATENÇÃO: painel local ligado na PRODUÇÃO (dados reais, WhatsApp real)."
      fi
      echo "Painel de $modo no ar: http://localhost:$porta"
      echo "Pode fechar o terminal. Para parar: ./scripts/painel.sh parar $modo"
    else
      echo "O painel não subiu. Últimas linhas do log:"; tail -n 20 "$logfile"; rm -f "$pidfile"; exit 1
    fi
    ;;
  parar)
    if rodando; then
      # encerra o grupo inteiro (npx e vite)
      kill -- -"$(cat "$pidfile")" 2>/dev/null || kill "$(cat "$pidfile")"
      echo "Painel de $modo parado."
    else
      echo "Painel de $modo não estava no ar."
    fi
    rm -f "$pidfile"
    ;;
  status)
    for m in homologacao producao; do
      p="$ESTADO/$m.pid"; porta_m=$([[ $m == producao ]] && echo 5174 || echo 5173)
      if [[ -f "$p" ]] && kill -0 "$(cat "$p")" 2>/dev/null; then
        echo "$m: no ar em http://localhost:$porta_m"
      else
        echo "$m: parado"
      fi
    done
    ;;
  log)
    tail -n 40 -f "$logfile"
    ;;
  *)
    echo "Uso: $0 iniciar|parar|status|log [homologacao|producao]"; exit 1 ;;
esac
