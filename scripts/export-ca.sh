#!/usr/bin/env bash
# LAN mode with CADDY_TLS=internal: copies the root certificate of Caddy's local CA so it
# can be installed on the client machines (browsers, OpenCode, Claude Code, scripts).
# Usage: ./scripts/export-ca.sh [destination]   (default: ./owngpt-root-ca.crt)
set -euo pipefail
# Resolved before lib.sh changes directory: a relative path is relative to the caller.
DEST="$(realpath -m "${1:-./owngpt-root-ca.crt}")"
source "$(dirname "$0")/lib.sh"

docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$DEST" >/dev/null 2>&1 \
  || { echo "Autorité absente : CADDY_TLS=internal et sites sans http:// ? (docker compose up -d caddy)" >&2; exit 1; }
chmod 644 "$DEST"
echo "Certificat racine : $DEST"
# The fingerprint lets users check, out of band, that they install the right root.
openssl x509 -in "$DEST" -noout -subject -enddate -fingerprint -sha256
