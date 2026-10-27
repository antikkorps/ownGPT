#!/usr/bin/env bash
# Restores an archive produced by backup.sh (same machine or a new server with the same .env).
# The archive is authenticated and decrypted BEFORE any service is stopped; the services
# that were running are started again at the end (with their profiles).
# Usage : ./scripts/restore.sh backups/ownGPT-YYYYMMDD-HHMMSS.tar.enc
set -euo pipefail
umask 077
ARCHIVE="$(realpath "${1:?Usage: $0 <archive.tar.enc>}")"
source "$(dirname "$0")/lib.sh"

: "${BACKUP_PASSPHRASE:?BACKUP_PASSPHRASE manquant dans .env}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
WORK="$(mktemp -d "$BACKUP_DIR/.work-restore-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -f "$ARCHIVE.mac" ] || { echo "ERREUR : $ARCHIVE.mac absent, archive non authentifiable." >&2; exit 1; }
read -r salt _ < "$ARCHIVE.mac"
if [ "$(archive_mac "$ARCHIVE" "$salt")" != "$(cat "$ARCHIVE.mac")" ]; then
  echo "ERREUR : authentification de l'archive échouée (modifiée, ou autre BACKUP_PASSPHRASE)." >&2
  exit 1
fi
echo "Archive authentifiée."
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:BACKUP_PASSPHRASE -in "$ARCHIVE" | tar -C "$WORK" -xf -

mapfile -t RUNNING < <(running_services)
PROFILES=()
printf '%s\n' "${RUNNING[@]}" | grep -q '^authentik-' && PROFILES+=(--profile sso)
printf '%s\n' "${RUNNING[@]}" | grep -qx cloudflared && PROFILES+=(--profile tunnel)
APPS=()
for s in "${RUNNING[@]}"; do [[ "$s" == postgres || "$s" == authentik-postgres ]] || APPS+=("$s"); done
echo "Arrêt des applications (les bases restent démarrées)…"
[ "${#APPS[@]}" = 0 ] || docker compose "${PROFILES[@]}" stop "${APPS[@]}"
docker compose up -d --wait postgres

for dump in "$WORK"/db-*.sql.gz; do
  db="$(basename "$dump" .sql.gz)"; db="${db#db-}"
  if [ "$db" = authentik ]; then service=authentik-postgres user=authentik; else service=postgres user="$POSTGRES_USER"; fi
  echo "Restauration de la base $db…"
  docker compose --profile sso up -d --wait "$service" >/dev/null
  # One transaction per database: on the first SQL error nothing of it is applied.
  gunzip -c "$dump" | docker compose exec -T "$service" psql -q -1 -v ON_ERROR_STOP=1 -U "$user" -d "$db" >/dev/null
done

for f in "$WORK"/vol-*.tar.gz; do
  v="$(basename "$f" .tar.gz)"; v="${v#vol-}"
  echo "Restauration du volume $v…"
  docker volume create "${COMPOSE_PROJECT}_${v}" >/dev/null
  # The model cache is kept: it is not in the archive and is slow to re-download.
  # The volume name is passed as an argument, never spliced into the shell code.
  docker run --rm -v "${COMPOSE_PROJECT}_${v}:/data" -v "$(realpath "$WORK"):/in:ro" alpine:3.22.7@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f \
    sh -c 'find /data -mindepth 1 -maxdepth 1 ! -name cache -exec rm -rf {} +; tar -xzf "/in/vol-$1.tar.gz" -C /data' _ "$v"
done

[ "${#RUNNING[@]}" = 0 ] || docker compose "${PROFILES[@]}" up -d "${RUNNING[@]}"
echo "Restauration terminée."
