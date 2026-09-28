#!/bin/bash
# Evolution própria da Infoxtec — script de inicialização da VM Oracle (cloud-init).
# Colar em: Create instance -> Show advanced options -> Management -> "Paste cloud-init script".
# Faz sozinho as partes B e C do docs/evolution-propria.md. Leva ~5 min depois que a VM liga.
# Acompanhar/conferir (via SSH):  sudo tail -f /var/log/evolution-instalacao.log
# Chave-mestra gerada:            sudo grep AUTHENTICATION_API_KEY /home/ubuntu/evolution/.env
set -euo pipefail
exec > /var/log/evolution-instalacao.log 2>&1
echo "== início $(date)"

# 1. portas 80 e 443 no firewall interno da imagem Ubuntu da Oracle
iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
netfilter-persistent save || true

# 2. Docker
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# 3. endereço sslip.io a partir do IP público
IP=""
for i in $(seq 1 30); do
  IP=$(curl -fsS --max-time 5 https://api.ipify.org || true)
  [[ "$IP" =~ ^[0-9.]+$ ]] && break
  sleep 5
done
[[ "$IP" =~ ^[0-9.]+$ ]] || { echo "ERRO: não obtive o IP público"; exit 1; }
DOMINIO="${IP//./-}.sslip.io"
echo "== endereço: https://$DOMINIO"

# 4. arquivos
D=/home/ubuntu/evolution
mkdir -p "$D" && cd "$D"

cat > .env <<EOF
DOMINIO=$DOMINIO
EVOLUTION_IMAGEM=evoapicloud/evolution-api:v2.3.7
AUTHENTICATION_API_KEY=$(openssl rand -hex 32)
POSTGRES_SENHA=$(openssl rand -hex 24)
CONFIG_SESSION_PHONE_VERSION=2.3000.1033773198
EOF
chmod 600 .env

cat > Caddyfile <<'EOF'
{$DOMINIO} {
	encode gzip
	reverse_proxy evolution:8080
}
EOF

cat > docker-compose.yml <<'EOF'
# Cópia de infra/evolution/docker-compose.yml do repositório infoxtec-escalas.
services:
  evolution:
    image: ${EVOLUTION_IMAGEM}
    restart: unless-stopped
    depends_on: [postgres, redis]
    env_file: .env
    environment:
      SERVER_URL: https://${DOMINIO}
      DATABASE_ENABLED: "true"
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://evolution:${POSTGRES_SENHA}@postgres:5432/evolution?schema=public
      DATABASE_CONNECTION_CLIENT_NAME: infoxtec
      DATABASE_SAVE_DATA_INSTANCE: "true"
      DATABASE_SAVE_DATA_NEW_MESSAGE: "false"
      DATABASE_SAVE_MESSAGE_UPDATE: "false"
      DATABASE_SAVE_DATA_CONTACTS: "false"
      DATABASE_SAVE_DATA_CHATS: "false"
      DATABASE_SAVE_DATA_LABELS: "false"
      DATABASE_SAVE_DATA_HISTORIC: "false"
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: redis://redis:6379/6
      CACHE_REDIS_PREFIX_KEY: evolution
      CACHE_LOCAL_ENABLED: "false"
      DEL_INSTANCE: "false"
      WEBHOOK_GLOBAL_ENABLED: "false"
      LOG_LEVEL: ERROR,WARN
      LANGUAGE: pt-BR
      CONFIG_SESSION_PHONE_CLIENT: Infoxtec Escalas
      CONFIG_SESSION_PHONE_NAME: Chrome
    volumes:
      - evolution_instancias:/evolution/instances

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: evolution
      POSTGRES_PASSWORD: ${POSTGRES_SENHA}
      POSTGRES_DB: evolution
    volumes:
      - postgres_dados:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis_dados:/data

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
  evolution_instancias:
  postgres_dados:
  redis_dados:
  caddy_dados:
EOF

chown -R ubuntu:ubuntu "$D"

# 5. subir
docker compose up -d
docker compose ps
echo "== PRONTO $(date). Manager: https://$DOMINIO/manager"
