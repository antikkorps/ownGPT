#!/usr/bin/env bash
# Checks that restore.sh refuses a tampered or unauthenticated archive BEFORE touching
# anything (services keep running). Needs the stack up; makes one real backup.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

./scripts/backup.sh >/dev/null
ARCHIVE="$(ls -t "${BACKUP_DIR:-./backups}"/ownGPT-*.tar.enc | head -1)"
WORK="$(mktemp -d "${BACKUP_DIR:-./backups}/.test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# expect_refused <label> <archive> — restore must fail and leave LiteLLM running.
expect_refused() {
  if ./scripts/restore.sh "$2" >/dev/null 2>&1; then fail "$1 : restauration acceptée"; return; fi
  [ "$(docker compose ps --status running --services | grep -cx litellm)" = 1 ] \
    && pass "$1 : refusée, services intacts" || fail "$1 : refusée mais LiteLLM arrêté"
}

# The archive must contain one dump per database listed by lib.sh, and nothing empty.
mapfile -t expected < <(databases | cut -d: -f2 | sort)
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:BACKUP_PASSPHRASE -in "$ARCHIVE" \
  | tar -tvf - > "$WORK/contenu.txt"
for db in "${expected[@]}"; do
  size="$(awk -v f="./db-$db.sql.gz" '$NF == f { print $3 }' "$WORK/contenu.txt")"
  [ -n "$size" ] && [ "$size" -gt 1000 ] && pass "dump $db présent ($size octets)" || fail "dump $db absent ou vide"
done

cp "$ARCHIVE" "$WORK/altere.tar.enc"
cp "$ARCHIVE.mac" "$WORK/altere.tar.enc.mac" 2>/dev/null || true
# Flip one byte in the middle of the ciphertext.
python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[len(b)//2]^=1; open(p,"wb").write(b)' "$WORK/altere.tar.enc"
expect_refused "archive modifiée d'un octet" "$WORK/altere.tar.enc"

cp "$ARCHIVE" "$WORK/sans-mac.tar.enc"
expect_refused "archive sans fichier .mac" "$WORK/sans-mac.tar.enc"

# An authentic archive holding a database this stack no longer has (e.g. made when an
# Authentik profile existed) must be refused before anything is stopped.
mkdir -p "$WORK/ancien"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:BACKUP_PASSPHRASE -in "$ARCHIVE" | tar -C "$WORK/ancien" -xf -
gzip -c /dev/null > "$WORK/ancien/db-authentik.sql.gz"
tar -C "$WORK/ancien" -cf - . | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:BACKUP_PASSPHRASE \
  -out "$WORK/ancien.tar.enc"
archive_mac "$WORK/ancien.tar.enc" > "$WORK/ancien.tar.enc.mac"
expect_refused "archive avec une base inconnue (authentik)" "$WORK/ancien.tar.enc"

echo "Restauration d'une archive valide (relance les mêmes services)…"
before="$(docker compose ps --status running --services | sort | tr '\n' ' ')"
if ./scripts/restore.sh "$ARCHIVE" >/dev/null 2>&1; then
  after="$(docker compose ps --status running --services | sort | tr '\n' ' ')"
  [ "$before" = "$after" ] && pass "restaurée, services relancés : $after" || fail "services avant [$before] / après [$after]"
else
  fail "restauration d'une archive valide en échec"
fi

finish
