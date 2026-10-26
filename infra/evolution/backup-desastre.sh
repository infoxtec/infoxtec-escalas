#!/usr/bin/env bash
# Pacote de desastre do banco da Evolution (decisão 116), no servidor da Oracle, uma vez por dia pelo cron do servidor.
# Vai SEM a sessão do WhatsApp (tabela "Session" e a pasta de instâncias), que é credencial do número da empresa, e SEM
# o histórico de conversas (Message, MessageUpdate, Chat, Contact, Media), por minimização. Na volta: ler o QR de novo
# e trocar o token da instância e o do webhook antes de ligar. Cifrado aqui mesmo com a CHAVE PÚBLICA (a privada fica
# só no cofre do responsável: invadir este servidor não abre nenhum pacote) e enviado com um rclone próprio.
# Risco registrado: o token deste servidor também enxerga a pasta dos pacotes do GitHub (decisão 116).
# Arquivos deste servidor, fora do repositório:
#   /etc/trilha/desastre-publica.asc   a mesma chave pública de infra/backup/desastre-publica.asc
#   /etc/trilha/rclone.conf (600)      remotos gdrive e onedrive
#   EVOLUTION_PG                       nome do contêiner do PostgreSQL (docker ps), no /etc/cron.d
# Agendar (como root):  echo '47 7 * * * root EVOLUTION_PG=<contêiner> /opt/trilha/backup-desastre.sh' > /etc/cron.d/trilha-desastre
set -euo pipefail

BANCO="${EVOLUTION_BANCO:-evolution24}"
CHAVE=/etc/trilha/desastre-publica.asc
pg="${EVOLUTION_PG:?informe o contêiner do PostgreSQL em EVOLUTION_PG}"
export RCLONE_CONFIG=/etc/trilha/rclone.conf
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
umask 077

nome="evolution-$(date -u +%Y%m%d-%H%M)"
# a exclusão por nome não avisa se a tabela não existir: confere antes e depois
if [ -z "$(docker exec "$pg" psql -U evolution -d "$BANCO" -Atc "select to_regclass('public.\"Session\"')")" ]; then
  echo "tabela Session não encontrada: a sessão entraria no pacote; abortado" >&2; exit 1
fi
docker exec "$pg" pg_dump -U evolution -d "$BANCO" --format=custom --no-owner \
  --exclude-table-data='public."Session"' --exclude-table-data='public."Message"' \
  --exclude-table-data='public."MessageUpdate"' --exclude-table-data='public."Chat"' \
  --exclude-table-data='public."Contact"' --exclude-table-data='public."Media"' > "$DIR/$nome.dump"
if docker exec -i "$pg" pg_restore -l < "$DIR/$nome.dump" | grep -q 'TABLE DATA public Session'; then
  echo "a sessão entrou no dump; abortado" >&2; exit 1
fi
gpg --batch --yes --trust-model always --cipher-algo AES256 --recipient-file "$CHAVE" --encrypt \
    --output "$DIR/$nome.dump.gpg" "$DIR/$nome.dump"
rm "$DIR/$nome.dump"

for destino in gdrive onedrive; do
  rclone copy "$DIR/$nome.dump.gpg" "$destino:Trilha-Backup/evolution" --log-level ERROR
  rclone delete "$destino:Trilha-Backup/evolution" --min-age 31d --drive-use-trash=false --onedrive-hard-delete --log-level ERROR
done
echo "ok: $nome.dump.gpg $(sha256sum "$DIR/$nome.dump.gpg" | cut -d' ' -f1)"
