# Shared helpers for the scripts/ directory (sourced, not executed).
# shellcheck shell=bash

cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a
# shellcheck disable=SC1091
source .env
set +a

COMPOSE_PROJECT="$(docker compose config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"

# Test reporting shared by test-presidio.sh and test-models.sh.
FAIL=0
pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; FAIL=1; }
finish() {
  [ "$FAIL" = 0 ] && echo "RÉSULTAT : OK" || echo "RÉSULTAT : ÉCHEC"
  exit "$FAIL"
}

# Databases saved by backup.sh / restored by restore.sh, as "service:database:user".
# Authentik's database is included only while the sso profile is running.
databases() {
  echo "postgres:openwebui:${POSTGRES_USER}" "postgres:litellm:${POSTGRES_USER}"
  if docker compose ps --status running --services 2>/dev/null | grep -qx authentik-postgres; then
    echo "authentik-postgres:authentik:authentik"
  fi
}

# LiteLLM is reached from inside the Docker network so the scripts work in every
# mode (VPS, tunnel, LAN) without depending on DNS or TLS.
LITELLM_INTERNAL="http://litellm:4000"

# litellm_api <METHOD> <PATH> [JSON]  — call the LiteLLM admin API with the master key.
litellm_api() {
  docker compose exec -T litellm python3 - "$1" "$2" "${3:-}" <<'PY'
import json, os, sys, urllib.request, urllib.error
method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request("http://localhost:4000" + path, method=method,
    data=body.encode() if body else None,
    headers={"Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"],
             "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        print(r.read().decode())
except urllib.error.HTTPError as e:
    print(e.read().decode(), file=sys.stderr)
    sys.exit(22)
PY
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

# api_curl <key> <path> <json> [extra curl args...] — prints body, then the HTTP code on the last line.
api_curl() {
  local key="$1" path="$2" body="$3"; shift 3
  local pin=()
  if [[ "$LITELLM_SITE" == http://* ]]; then
    pin=(--connect-to "::127.0.0.1:${HTTP_PORT:-80}")
  fi
  curl -sS "${pin[@]}" -w '\n%{http_code}' "$(api_base_url)${path}" \
    -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' "$@" -d "$body"
}

# chat_body <model> <message> — JSON body for /v1/chat/completions.
chat_body() {
  python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 200,
    "messages": [{"role": "user", "content": sys.argv[2]}]}))' "$1" "$2"
}

# masked_entities <response-id> — guardrail entity counts recorded in LiteLLM's spend log
# (written asynchronously, hence the polling).
masked_entities() {
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
