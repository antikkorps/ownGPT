# Shared helpers for the scripts/ directory (sourced, not executed).
# shellcheck shell=bash

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# load_env <file> — exports KEY=VALUE lines without executing them as shell code
# (`source .env` would run any $(…) or backquote that ends up in a value).
load_env() {
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
    export "$key=$value"
  done < "$1"
}
load_env .env

COMPOSE_PROJECT="$(docker compose config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"

# Test reporting shared by test-presidio.sh and test-models.sh.
FAIL=0
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; FAIL=1; }
finish() {
  [ "$FAIL" = 0 ] && echo "RÉSULTAT : OK" || echo "RÉSULTAT : ÉCHEC"
  exit "$FAIL"
}

# Databases saved by backup.sh / restored by restore.sh, one "service:database:user" per line.
# Authentik's database is included only while the sso profile is running.
databases() {
  printf '%s\n' "postgres:openwebui:${POSTGRES_USER}" "postgres:litellm:${POSTGRES_USER}"
  if docker compose ps --status running --services 2>/dev/null | grep -qx authentik-postgres; then
    echo "authentik-postgres:authentik:authentik"
  fi
}

# archive_mac <file> — HMAC-SHA256 of a backup archive, keyed from BACKUP_PASSPHRASE.
# Authenticates the archive (CBC encryption alone is malleable); the key is read from
# the environment, never passed on a command line.
archive_mac() {
  python3 -c 'import hashlib,hmac,os,sys
key = hashlib.sha256(b"ownGPT-backup-mac:" + os.environ["BACKUP_PASSPHRASE"].encode()).digest()
mac = hmac.new(key, digestmod="sha256")
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        mac.update(chunk)
print(mac.hexdigest())' "$1"
}

# litellm_api <METHOD> <PATH> [JSON] — LiteLLM admin API with the master key, from inside
# the container. The JSON body (it may contain virtual keys) goes through stdin, so it
# never shows up in the host process list.
LITELLM_API_PY='import json, os, sys, urllib.request, urllib.error
body = sys.stdin.read()
req = urllib.request.Request("http://localhost:4000" + sys.argv[2], method=sys.argv[1],
    data=body.encode() if body else None,
    headers={"Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"],
             "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        print(r.read().decode())
except urllib.error.HTTPError as e:
    print(e.read().decode(), file=sys.stderr)
    sys.exit(22)'
litellm_api() {
  printf '%s' "${3:-}" | docker compose exec -T litellm python3 -c "$LITELLM_API_PY" "$1" "$2"
}

# Models exposed to the "avancé" group: Scaleway ones only when that config is active.
advanced_models_json() {
  if [ "${LITELLM_CONFIG:-config.yaml}" = "config.scaleway.yaml" ]; then
    echo '["mistral-small","mistral-medium","glm","devstral","deepseek","qwen"]'
  else
    echo '["mistral-small","mistral-medium","glm","devstral"]'
  fi
}

# Public API base URL, reached through Caddy like any client would.
# In http:// (home) mode the hostname is pinned to the local Caddy port, so the
# test works without DNS; in VPS mode the real HTTPS endpoint is used.
api_base_url() {
  local host="${LITELLM_SITE#http://}"
  if [ "$host" != "$LITELLM_SITE" ]; then echo "http://${host}"; else echo "https://${LITELLM_SITE}"; fi
}

# api_curl <key> <path> <json> [extra curl args...] — prints body, then the HTTP code on the
# last line. The key and the body are handed to curl through a file descriptor and stdin,
# not as arguments (visible to every user of the host with `ps`).
api_curl() {
  local key="$1" path="$2" body="$3"; shift 3
  local pin=()
  if [[ "$LITELLM_SITE" == http://* ]]; then
    pin=(--connect-to "::127.0.0.1:${HTTP_PORT:-80}")
  fi
  printf '%s' "$body" | curl -sS "${pin[@]}" -w '\n%{http_code}' "$(api_base_url)${path}" \
    -H @<(printf 'Authorization: Bearer %s\n' "$key") -H 'Content-Type: application/json' \
    "$@" --data-binary @-
}

# chat_body <model> <message> — JSON body for /v1/chat/completions.
chat_body() {
  python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 200,
    "messages": [{"role": "user", "content": sys.argv[2]}]}))' "$1" "$2"
}

# masked_entities <response-id> — guardrail entity counts recorded in LiteLLM's spend log
# (written asynchronously, hence the polling).
masked_entities() {
  [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]] || { echo "ID_INVALIDE"; return; }
  local sql="select metadata->'guardrail_information' from \"LiteLLM_SpendLogs\" where request_id='$1'" out=""
  for _ in $(seq 1 30); do
    out="$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d litellm -tAc "$sql")"
    [ -n "$out" ] && break
    sleep 3
  done
  [ -n "$out" ] || { echo "JOURNAL_ABSENT"; return; }
  python3 -c 'import json,sys
d=json.loads(sys.argv[1] or "[]")
print(" ".join(sorted({k for g in d for k in (g.get("masked_entity_count") or {})})))' "$out"
}
