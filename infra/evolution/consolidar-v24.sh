#!/bin/bash
# Backlog 073: deixa o servidor com UMA Evolution (a 2.4 que ja atende a producao) e desliga a 2.3.7.
# Roda NO SERVIDOR, em ~/evolution.
#
#   bash consolidar-v24.sh aplicar   para a 2.3.7, a 2.4 passa a ser o servico "evolution" (mesma sessao,
#                                    mesmo banco evolution24), Caddy volta ao Caddyfile original
#   bash consolidar-v24.sh voltar    desfaz o "aplicar" (usa as copias .bak-237)
#   bash consolidar-v24.sh limpar    depois de 1 dia estavel: apaga banco, volume e arquivos da 2.3.7
#
# A sessao do WhatsApp e a licenca ficam no volume evolution24_instancias e no banco evolution24,
# que sao reaproveitados: nao precisa ler QR de novo nem reativar.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && [ -f docker-compose.yml ] || { echo "Rode dentro de ~/evolution no servidor."; exit 1; }
DOMINIO=$(grep -oP '^DOMINIO=\K.*' .env)
CHAVE=$(grep -oP '^AUTHENTICATION_API_KEY=\K.*' .env)
IMAGEM="evoapicloud/evolution-api:2.4.0-rc2"
estado() { curl -s "https://$DOMINIO/instance/fetchInstances" -H "apikey: $CHAVE" \
  | grep -o '"name":"[^"]*"\|"connectionStatus":"[^"]*"\|"integration":"[^"]*"' | tr '\n' ' '; echo; }

case "${1:-}" in
aplicar)
  echo "== antes:"; estado
  [ -f docker-compose.yml.bak-237 ] || cp docker-compose.yml docker-compose.yml.bak-237
  cp .env .env.bak-237
  sudo sed -i "s|^EVOLUTION_IMAGEM=.*|EVOLUTION_IMAGEM=$IMAGEM|" .env
  sudo sed -i '/^CONFIG_SESSION_PHONE_VERSION=/d' .env          # contorno da 2.3.7; a 2.4 nao precisa

  echo "== copia de seguranca do banco da 2.4 (sessao e licenca), so para o dono"
  sudo docker compose exec -T postgres pg_dump -U evolution evolution24 > ~/evolution24-$(date +%F).sql
  chmod 600 ~/evolution24-*.sql

  cat > docker-compose.yml <<'EOF'
# Evolution API propria da Infoxtec (docs/evolution-propria.md), versao 2.4 unica (backlog 073).
# VM de 1 GB: sem Redis (cache local). Banco evolution24 e volume evolution24_instancias sao os da
# instancia que ja atende a producao desde 28/09.
services:
  evolution:
    image: ${EVOLUTION_IMAGEM}
    restart: unless-stopped
    depends_on: [postgres]
    environment:
      SERVER_URL: https://${DOMINIO}
      AUTHENTICATION_API_KEY: ${AUTHENTICATION_API_KEY}
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://evolution:${POSTGRES_SENHA}@postgres:5432/evolution24?schema=public
      DATABASE_CONNECTION_CLIENT_NAME: infoxtec
      # minimizacao (LGPD): guarda a sessao, nao guarda conversa, contato nem chat
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
      CONFIG_SESSION_PHONE_CLIENT: Infoxtec Escalas
      CONFIG_SESSION_PHONE_NAME: Chrome
    volumes:
      - evolution24_instancias:/evolution/instances

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: evolution
      POSTGRES_PASSWORD: ${POSTGRES_SENHA}
      POSTGRES_DB: evolution
    command: ["postgres", "-c", "shared_buffers=32MB", "-c", "max_connections=30"]
    volumes:
      - postgres_dados:/var/lib/postgresql/data

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    depends_on: [evolution]
    ports: ["80:80", "443:443"]
    environment:
      DOMINIO: ${DOMINIO}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_dados:/data

volumes:
  evolution24_instancias:
  postgres_dados:
  caddy_dados:
EOF

  echo "== trocando (cerca de 1 min sem envio; o motor reenvia sozinho o que falhar)"
  sudo docker stop evolution-evolution24-1 evolution-evolution-1 >/dev/null
  sudo docker compose up -d --remove-orphans
  for i in $(seq 1 24); do
    estado | grep -q '"connectionStatus":"open"' && break; sleep 5
  done
  echo "== depois:"; estado
  sudo docker compose ps --format '{{.Service}}: {{.Image}} {{.State}}'
  free -h | head -2
  echo "Esperado: connectionStatus open, 3 servicos (evolution 2.4.0-rc2, postgres, caddy)."
  echo "Se nao abrir em 2 min: bash consolidar-v24.sh voltar"
  ;;
voltar)
  [ -f docker-compose.yml.bak-237 ] || { echo "Sem copia .bak-237."; exit 1; }
  sudo docker compose down
  cp docker-compose.yml.bak-237 docker-compose.yml; sudo cp .env.bak-237 .env
  sudo IMAGEM_TESTE=$IMAGEM TESTE="teste.$DOMINIO" docker compose -f docker-compose.yml -f docker-compose.teste.yml up -d
  sleep 30; estado
  echo "Voltou ao estado anterior (2.3.7 + 2.4 lado a lado, endereco principal na 2.4)."
  ;;
limpar)
  estado | grep -q '"connectionStatus":"open"' || { echo "A 2.4 nao esta open. Nao limpo nada."; exit 1; }
  sudo docker compose exec -T postgres psql -U evolution -d evolution24 -c "select 1" >/dev/null
  sudo docker compose exec -T postgres psql -U evolution -d postgres -c "drop database if exists evolution"
  sudo docker volume rm evolution_evolution_instancias evolution_redis_dados 2>/dev/null || true
  rm -f docker-compose.yml.bak-237 .env.bak-237 docker-compose.teste.yml Caddyfile.teste teste-v24.sh
  sudo docker image prune -af >/dev/null
  echo "Limpo. Restam: evolution (2.4), postgres, caddy."; df -h / | tail -1
  ;;
*) sed -n 2,11p "$0"; exit 1 ;;
esac
