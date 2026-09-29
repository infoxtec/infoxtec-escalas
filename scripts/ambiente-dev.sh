#!/usr/bin/env bash
# Sobe o ambiente de desenvolvimento inteiro com um comando.
#
#   ./scripts/ambiente-dev.sh iniciar            painel (vite) + harness (dsh web)
#   ./scripts/ambiente-dev.sh iniciar producao   painel apontando para a produção (dados reais)
#   ./scripts/ambiente-dev.sh status             o que está no ar, em que porta
#   ./scripts/ambiente-dev.sh parar [painel|harness|tudo]
#   ./scripts/ambiente-dev.sh instalar           serviços de usuário: sobe sozinho, sem login
#   ./scripts/ambiente-dev.sh desinstalar
#
# O OrbStack roda no macOS, não aqui dentro: esta máquina é a convidada. Para o OrbStack e esta
# máquina subirem sem ninguém tocar, o ajuste é no Mac — ver docs/ambiente-dev-mac.md.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$RAIZ/web"
ESTADO="$HOME/.infoxtec-dev"

acao="${1:-status}"
alvo="${2:-tudo}"
modo="${2:-homologacao}"

# O painel é cuidado pelo scripts/painel.sh, que já sabe subir, parar e conferir.
painel() { "$RAIZ/scripts/painel.sh" "$@"; }

porta_aberta() { ss -tln 2>/dev/null | grep -q ":$1 "; }

# O harness roda de dentro desta pasta para carregar o AGENTS.md/CLAUDE.md do projeto.
pidfile_harness="$ESTADO/harness.pid"
log_harness="$ESTADO/harness.log"
rodando_harness() { [[ -f "$pidfile_harness" ]] && kill -0 "$(cat "$pidfile_harness")" 2>/dev/null; }

iniciar_painel() {
  echo "== Painel (vite) =="
  painel iniciar "$modo"
}

iniciar_harness() {
  echo
  echo "== Harness (dsh web) =="
  if porta_aberta 3080; then
    echo "Já está no ar em http://127.0.0.1:3080"
    return
  fi
  mkdir -p "$ESTADO"
  cd "$RAIZ"
  # setsid + nohup: sobrevive ao fechamento da janela do terminal, igual ao painel
  setsid nohup npm exec @deepseek-ai/dsh web >"$log_harness" 2>&1 < /dev/null &
  echo $! > "$pidfile_harness"
  for _ in $(seq 1 15); do
    porta_aberta 3080 && break
    sleep 1
  done
  if porta_aberta 3080; then
    echo "No ar em http://127.0.0.1:3080"
  else
    echo "O harness não subiu em 15 s. Últimas linhas do log ($log_harness):"
    tail -n 15 "$log_harness" || true
    rm -f "$pidfile_harness"
    exit 1
  fi
}

status() {
  echo "== O que está no ar =="
  if porta_aberta 5173; then echo "painel (homologação): http://localhost:5173"; else echo "painel (homologação): parado"; fi
  if porta_aberta 5174; then echo "painel (produção):    http://localhost:5174  ← dados reais"; else echo "painel (produção):    parado"; fi
  if porta_aberta 3080; then echo "harness:              http://127.0.0.1:3080"; else echo "harness:              parado"; fi
  echo
  echo "== Serviços de usuário (systemd) =="
  for u in painel-dev dsh-web; do
    if systemctl --user is-enabled "$u" >/dev/null 2>&1; then hab="habilitado"; else hab="não instalado"; fi
    ativo="$(systemctl --user is-active "$u" 2>/dev/null || true)"; [ -n "$ativo" ] || ativo="inativo"
    printf "%-12s %s, %s\n" "$u" "$hab" "$ativo"
  done
  echo
  echo "== Sem interação humana =="
  echo "linger (serviço de usuário sem login): $(loginctl show-user "$USER" -p Linger --value 2>/dev/null)"
  if pgrep -f "orbstack-agent" >/dev/null 2>&1; then
    echo "máquina Linux: no ar (agente do OrbStack rodando)"
  else
    echo "máquina Linux: agente do OrbStack não encontrado"
  fi
  echo
  echo "O OrbStack em si roda no macOS: se ele não subir sozinho no Mac, nada aqui aparece."
  echo "Como configurar: docs/ambiente-dev-mac.md, seção \"Sem interação humana\"."
}

parar() {
  case "$alvo" in
    painel)  painel parar homologacao; painel parar producao ;;
    harness)
      cat <<'FIM'
ATENÇÃO: parar o harness encerra a sessão que você está usando agora, se estiver falando por ele.
FIM
      read -r -p "Digite HARNESS para confirmar: " ok
      [ "$ok" = "HARNESS" ] || { echo "Cancelado."; exit 1; }
      if rodando_harness; then
        kill -- -"$(cat "$pidfile_harness")" 2>/dev/null || kill "$(cat "$pidfile_harness")" 2>/dev/null || true
        rm -f "$pidfile_harness"
        echo "harness parado."
      else
        echo "harness não estava no ar por este script."
      fi
      ;;
    tudo) parar_painel_silencioso=true; painel parar homologacao; painel parar producao; echo "painel parado. Para o harness: ./scripts/ambiente-dev.sh parar harness" ;;
    *) echo "Alvo desconhecido: $alvo (use painel, harness ou tudo)"; exit 1 ;;
  esac
}

instalar() {
  local destino="$HOME/.config/systemd/user"
  mkdir -p "$destino"
  for u in painel-dev dsh-web; do
    ln -sf "$RAIZ/infra/dev/$u.service" "$destino/$u.service"
  done
  systemctl --user daemon-reload
  systemctl --user enable --now painel-dev dsh-web
  echo "Serviços instalados e iniciados: painel-dev (5173) e dsh-web (3080)."
  echo "Eles sobem sozinhos quando a máquina Linux liga — inclusive sem login, porque o linger está ligado."
  echo "Conferir: systemctl --user status painel-dev dsh-web   ·   log: journalctl --user -u dsh-web -f"
  echo "Lembre: isto não faz o OrbStack subir no Mac. Ver docs/ambiente-dev-mac.md."
}

desinstalar() {
  systemctl --user disable --now painel-dev dsh-web 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/painel-dev.service" "$HOME/.config/systemd/user/dsh-web.service"
  systemctl --user daemon-reload
  echo "Serviços removidos. O que estava no ar por eles foi parado."
}

case "$acao" in
  iniciar)  iniciar_painel; iniciar_harness; echo; status ;;
  status)   status ;;
  parar)    parar ;;
  instalar) instalar ;;
  desinstalar) desinstalar ;;
  *) echo "Ação desconhecida: $acao (use iniciar, status, parar, instalar ou desinstalar)"; exit 1 ;;
esac
