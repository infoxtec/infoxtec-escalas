#!/usr/bin/env bash
# Pacote de desastre do banco da Evolution (decisão 116), no servidor da Oracle, uma vez por dia pelo cron do servidor.
# Vai SEM a sessão do WhatsApp (tabela "Session" e a pasta de instâncias): a sessão é uma credencial do número da
# empresa; na volta, lê-se o QR de novo. Cifrado (AES-256) aqui mesmo e enviado ao Google Drive e ao OneDrive com um
# rclone próprio deste servidor (token separado do GitHub, contas dedicadas ao backup).
# Arquivos deste servidor, fora do repositório e com permissão 600:
#   /etc/trilha/desastre.senha   a mesma DESASTRE_SENHA do GitHub
#   /etc/trilha/rclone.conf      remotos gdrive e onedrive
# Agendar (como root):  echo '47 7 * * * root /opt/trilha/backup-desastre.sh' > /etc/cron.d/trilha-desastre
set -euo pipefail

BANCO="${EVOLUTION_BANCO:-evolution24}"
SENHA_ARQ=/etc/trilha/desastre.senha
export RCLONE_CONFIG=/etc/trilha/rclone.conf
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
umask 077

pg=$(docker ps --format '{{.Names}}' | grep -m1 postgres)
nome="evolution-$(date -u +%Y%m%d-%H%M)"
docker exec "$pg" pg_dump -U evolution -d "$BANCO" --format=custom --no-owner \
  --exclude-table-data='public."Session"' > "$DIR/$nome.dump"
gpg --batch --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 --passphrase-file "$SENHA_ARQ" \
    --output "$DIR/$nome.dump.gpg" "$DIR/$nome.dump"
rm "$DIR/$nome.dump"

for destino in gdrive onedrive; do
  rclone copy "$DIR/$nome.dump.gpg" "$destino:Trilha-Backup/evolution" --log-level ERROR
  rclone delete "$destino:Trilha-Backup/evolution" --min-age 31d --drive-use-trash=false --onedrive-hard-delete --log-level ERROR
done
echo "ok: $nome.dump.gpg $(sha256sum "$DIR/$nome.dump.gpg" | cut -d' ' -f1)"
