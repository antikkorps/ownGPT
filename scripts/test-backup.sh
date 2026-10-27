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

cp "$ARCHIVE" "$WORK/altere.tar.enc"
cp "$ARCHIVE.mac" "$WORK/altere.tar.enc.mac" 2>/dev/null || true
# Flip one byte in the middle of the ciphertext.
python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[len(b)//2]^=1; open(p,"wb").write(b)' "$WORK/altere.tar.enc"
expect_refused "archive modifiée d'un octet" "$WORK/altere.tar.enc"

cp "$ARCHIVE" "$WORK/sans-mac.tar.enc"
expect_refused "archive sans fichier .mac" "$WORK/sans-mac.tar.enc"

finish
