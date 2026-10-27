#!/usr/bin/env bash
# Encrypted, authenticated backup: one dump per PostgreSQL database + application volumes.
# Usage : ./scripts/backup.sh            (from the project root)
# Cron  : 0 3 * * * cd /opt/ownGPT && ./scripts/backup.sh >> /var/log/ownGPT-backup.log 2>&1
set -euo pipefail
umask 077
source "$(dirname "$0")/lib.sh"

: "${BACKUP_PASSPHRASE:?BACKUP_PASSPHRASE manquant dans .env}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
# Leftovers of a killed backup hold plain dumps: remove them (only old ones, and only
# backup ones, so a concurrent run is never touched).
find "$BACKUP_DIR" -maxdepth 1 -name '.work-backup-*' -mmin +120 -exec rm -rf {} +
# Plain dumps (password hashes, TLS keys) only ever live inside the 700 backup dir.
WORK="$(mktemp -d "$BACKUP_DIR/.work-backup-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mapfile -t DATABASES < <(databases)
for entry in "${DATABASES[@]}"; do
  IFS=: read -r service db user <<<"$entry"
  echo "[$(date -Is)] Dump de la base $db…"
  # </dev/null: `compose exec` would otherwise swallow the caller's stdin.
  docker compose exec -T "$service" pg_dump -U "$user" -d "$db" --clean --if-exists </dev/null \
    | gzip -9 > "$WORK/db-$db.sql.gz"
done
dumps=("$WORK"/db-*.sql.gz)
[ "${#dumps[@]}" = "${#DATABASES[@]}" ] || { echo "ERREUR : ${#dumps[@]} dumps pour ${#DATABASES[@]} bases." >&2; exit 1; }

# Volumes holding files that are not in PostgreSQL (uploads, vector DB, TLS certs).
# ./cache (embedding/whisper models, ~4 GB) is excluded: Open WebUI re-downloads it on start.
VOLUMES=(openwebui_data caddy_data)
docker volume inspect "${COMPOSE_PROJECT}_authentik_data" >/dev/null 2>&1 && VOLUMES+=(authentik_data)
for v in "${VOLUMES[@]}"; do
  echo "[$(date -Is)] Archive du volume $v…"
  docker run --rm -v "${COMPOSE_PROJECT}_${v}:/data:ro" -v "$(realpath "$WORK"):/out" alpine:3.22.7@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f \
    tar -czf "/out/vol-${v}.tar.gz" --exclude=./cache -C /data .
done

echo "[$(date -Is)] Chiffrement…"
OUT="$BACKUP_DIR/ownGPT-$STAMP.tar.enc"
tar -C "$WORK" -cf - . \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:BACKUP_PASSPHRASE -out "$OUT"
# Encrypt-then-MAC: restore.sh refuses any archive whose MAC does not match.
archive_mac "$OUT" > "$OUT.mac"

echo "[$(date -Is)] Rotation (> ${BACKUP_KEEP_DAYS} jours)…"
find "$BACKUP_DIR" -maxdepth 1 -name 'ownGPT-*.tar.enc*' -mtime +"$BACKUP_KEEP_DAYS" -print -delete

echo "[$(date -Is)] OK : $OUT ($(du -h "$OUT" | cut -f1))"
