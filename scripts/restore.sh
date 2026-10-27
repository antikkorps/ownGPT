#!/usr/bin/env bash
# Restores an archive produced by backup.sh (same machine or a new server with the same .env).
# The archive is authenticated and decrypted BEFORE any service is stopped.
# Usage : ./scripts/restore.sh backups/ownGPT-YYYYMMDD-HHMMSS.tar.enc
set -euo pipefail
umask 077
ARCHIVE="$(realpath "${1:?Usage: $0 <archive.tar.enc>}")"
source "$(dirname "$0")/lib.sh"

: "${BACKUP_PASSPHRASE:?BACKUP_PASSPHRASE manquant dans .env}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
WORK="$(mktemp -d "$BACKUP_DIR/.work-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -f "$ARCHIVE.mac" ] || { echo "ERREUR : $ARCHIVE.mac absent, archive non authentifiable." >&2; exit 1; }
if [ "$(archive_mac "$ARCHIVE")" != "$(cat "$ARCHIVE.mac")" ]; then
  echo "ERREUR : authentification de l'archive échouée (modifiée, ou autre BACKUP_PASSPHRASE)." >&2
  exit 1
fi
echo "Archive authentifiée."
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:BACKUP_PASSPHRASE -in "$ARCHIVE" | tar -C "$WORK" -xf -

echo "Arrêt des applications (les bases restent démarrées)…"
docker compose stop caddy openwebui litellm authentik-server authentik-worker 2>/dev/null || true
docker compose up -d --wait postgres

for dump in "$WORK"/db-*.sql.gz; do
  db="$(basename "$dump" .sql.gz)"; db="${db#db-}"
  if [ "$db" = authentik ]; then service=authentik-postgres user=authentik; else service=postgres user="$POSTGRES_USER"; fi
  echo "Restauration de la base $db…"
  docker compose --profile sso up -d --wait "$service" >/dev/null
  # Stop at the first SQL error so a failed restore never reports success.
  gunzip -c "$dump" | docker compose exec -T "$service" psql -q -v ON_ERROR_STOP=1 -U "$user" -d "$db" >/dev/null
done

for f in "$WORK"/vol-*.tar.gz; do
  v="$(basename "$f" .tar.gz)"; v="${v#vol-}"
  echo "Restauration du volume $v…"
  docker volume create "${COMPOSE_PROJECT}_${v}" >/dev/null
  # The model cache is kept: it is not in the archive and is slow to re-download.
  # The volume name is passed as an argument, never spliced into the shell code.
  docker run --rm -v "${COMPOSE_PROJECT}_${v}:/data" -v "$(realpath "$WORK"):/in:ro" alpine:3.22.7 \
    sh -c 'find /data -mindepth 1 -maxdepth 1 ! -name cache -exec rm -rf {} +; tar -xzf "/in/vol-$1.tar.gz" -C /data' _ "$v"
done

docker compose up -d
echo "Restauration terminée."
