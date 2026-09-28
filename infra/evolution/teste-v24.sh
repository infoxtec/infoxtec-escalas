#!/bin/bash
# Teste da Evolution 2.4 LADO A LADO com a de producao, no mesmo servidor, sem tocar nela.
# Roda NO SERVIDOR (ubuntu@vcn-evolution), dentro de ~/evolution.
#
#   bash teste-v24.sh subir      sobe a 2.4 em https://teste.<ip>.sslip.io (banco e volume proprios)
#   bash teste-v24.sh botoes N   manda uma mensagem com botoes (mesmo formato do sistema) para o numero N
#   bash teste-v24.sh remover    apaga o teste (container, banco e volume); producao intacta
#
# Por que: a v2.3.7 entrega botoes como "visualizacao unica" (decisao 4, issue #2390). A 2.4 removeu
# o wrapper que causava isso, mas passou a exigir ativacao de licenca (release 2.4.0-rc1). O teste
# responde as duas perguntas antes de mexer na producao: a ativacao e gratuita? os botoes chegam?
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && [ -f docker-compose.yml ] || { echo "Rode dentro de ~/evolution no servidor."; exit 1; }

IMAGEM_TESTE="evoapicloud/evolution-api:2.4.0-rc2"   # mais recente publicada em 28/09/2026
DOMINIO=$(grep -oP '^DOMINIO=\K.*' .env)
TESTE="teste.$DOMINIO"                                 # o sslip.io resolve subdominios para o mesmo IP
INST="teste24"
dc() { sudo IMAGEM_TESTE="$IMAGEM_TESTE" TESTE="$TESTE" docker compose -f docker-compose.yml -f docker-compose.teste.yml "$@"; }

case "${1:-}" in
subir)
  # 1. banco proprio dentro do Postgres existente (a producao usa o banco "evolution")
  sudo docker compose exec -T postgres psql -U evolution -d evolution -tc \
    "select 1 from pg_database where datname='evolution24'" | grep -q 1 || \
    sudo docker compose exec -T postgres psql -U evolution -d evolution -c "create database evolution24"

  # 2. servico de teste: variaveis explicitas, sem herdar o .env da producao
  cat > docker-compose.teste.yml <<'EOF'
services:
  evolution24:
    image: ${IMAGEM_TESTE}
    restart: "no"
    depends_on: [postgres]
    environment:
      SERVER_URL: https://${TESTE}
      AUTHENTICATION_API_KEY: ${AUTHENTICATION_API_KEY}
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://evolution:${POSTGRES_SENHA}@postgres:5432/evolution24?schema=public
      DATABASE_CONNECTION_CLIENT_NAME: teste24
      DATABASE_SAVE_DATA_INSTANCE: "true"
      DATABASE_SAVE_DATA_NEW_MESSAGE: "false"
      DATABASE_SAVE_MESSAGE_UPDATE: "false"
      DATABASE_SAVE_DATA_CONTACTS: "false"
      DATABASE_SAVE_DATA_CHATS: "false"
      DATABASE_SAVE_DATA_LABELS: "false"
      DATABASE_SAVE_DATA_HISTORIC: "false"
      CACHE_REDIS_ENABLED: "false"
      CACHE_LOCAL_ENABLED: "true"
      DEL_INSTANCE: "false"
      WEBHOOK_GLOBAL_ENABLED: "false"
      LOG_LEVEL: ERROR,WARN
      LANGUAGE: pt-BR
      CONFIG_SESSION_PHONE_CLIENT: Infoxtec Teste
      CONFIG_SESSION_PHONE_NAME: Chrome
    volumes:
      - evolution24_instancias:/evolution/instances
  caddy:
    volumes:
      - ./Caddyfile.teste:/etc/caddy/Caddyfile:ro
volumes:
  evolution24_instancias:
EOF

  # 3. Caddy passa a atender tambem o endereco de teste (o da producao continua igual)
  { cat Caddyfile; printf '\n%s {\n\tencode gzip\n\treverse_proxy evolution24:8080\n}\n' "$TESTE"; } > Caddyfile.teste

  export IMAGEM_TESTE TESTE
  dc pull evolution24
  dc up -d evolution24 caddy
  echo "== aguardando a 2.4 iniciar (migracao do banco na primeira vez, ate 2 min)"
  for i in $(seq 1 24); do
    curl -fsS -o /dev/null "https://$TESTE/health" 2>/dev/null && break; sleep 5
  done
  echo "== licenca:"; curl -s "https://$TESTE/license/status"; echo
  echo "== producao (deve continuar open):"
  CHAVE=$(grep -oP '^AUTHENTICATION_API_KEY=\K.*' .env)
  curl -s "https://$DOMINIO/instance/connectionState/infoxtec" -H "apikey: $CHAVE"; echo
  free -h | head -2
  cat <<FIM

PROXIMOS PASSOS
 1. Abra https://$TESTE/manager/login
    - Se pedir ATIVACAO: veja o formulario. Anote se e gratis e que dados pede. Se pedir cartao
      ou plano pago, PARE e rode: bash teste-v24.sh remover
 2. Ativado: Create Instance, nome "$INST", canal/integracao BAILEYS, Connect, leia o QR no
    celular da empresa (ele fica com 3 aparelhos; o limite e 4).
 3. bash teste-v24.sh botoes 5571981776307
FIM
  ;;
botoes)
  N="${2:?informe o numero, ex. 5571981776307}"
  CHAVE=$(grep -oP '^AUTHENTICATION_API_KEY=\K.*' .env)
  curl -s "https://$TESTE/instance/connectionState/$INST" -H "apikey: $CHAVE"; echo
  curl -s -X POST "https://$TESTE/message/sendButtons/$INST" -H "apikey: $CHAVE" \
    -H "Content-Type: application/json" -d "{
      \"number\": \"$N\",
      \"title\": \"ESCALA DE TESTE (Evolution 2.4)\",
      \"description\": \"Teste de botoes. Confirme pelos botoes abaixo ou responda *1* (confirmado) ou *2* (problema).\",
      \"footer\": \"Infoxtec Escalas\",
      \"buttons\": [
        {\"type\": \"reply\", \"displayText\": \"Ciente, confirmado\", \"id\": \"conf:teste\"},
        {\"type\": \"reply\", \"displayText\": \"Tenho um problema\", \"id\": \"prob:teste\"}
      ]}" | head -c 250; echo
  echo "Confira no CELULAR e no Mac: botoes visiveis e clicaveis, sem 'visualizacao unica'."
  ;;
remover)
  export IMAGEM_TESTE TESTE
  dc rm -sf evolution24 || true
  sudo docker compose up -d caddy          # volta o Caddy so com a producao
  sudo docker volume rm "$(basename "$PWD")_evolution24_instancias" 2>/dev/null || true
  sudo docker compose exec -T postgres psql -U evolution -d evolution -c "drop database if exists evolution24"
  rm -f docker-compose.teste.yml Caddyfile.teste
  echo "Teste removido. No celular, desconecte o aparelho 'Infoxtec Teste' em Aparelhos conectados."
  ;;
*) sed -n 2,9p "$0"; exit 1 ;;
esac
