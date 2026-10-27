#!/usr/bin/env bash
# Checks that every active model answers through the gateway (via Caddy):
#   - OpenAI format (/v1/chat/completions) WITH a forced tool call (function calling)
#   - Anthropic format (/v1/messages), as used by Claude Code
# Then, if Scaleway is configured, simulates a Mistral outage and checks that
# mistral-small falls back to Scaleway (LiteLLM restarts twice, ~1 min).
# Usage: ./scripts/test-models.sh [--sans-panne]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

KEY="${KEY:-$LITELLM_KEY_OPENWEBUI}"

TOOLS='[{"type":"function","function":{"name":"meteo","description":"Donne la météo d une ville",
  "parameters":{"type":"object","properties":{"ville":{"type":"string"}},"required":["ville"]}}}]'

# json_get <python-expr> — evaluates the expression on the JSON read from stdin (as d).
json_get() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1" 2>/dev/null || true; }

test_tool_call() {
  local model="$1" body out
  body="$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 200,
    "disable_fallbacks": True, "tool_choice": "required", "tools": json.loads(sys.argv[2]),
    "messages": [{"role": "user", "content": "Quel temps fait-il à Lyon ?"}]}))' "$model" "$TOOLS")"
  out="$(api_curl "$KEY" /v1/chat/completions "$body")"
  local fn
  fn="$(sed '$d' <<<"$out" | json_get 'd["choices"][0]["message"]["tool_calls"][0]["function"]["name"]')"
  [ "$fn" = meteo ] && pass "$model · OpenAI + appel d'outil" \
    || fail "$model · OpenAI + outil (HTTP $(tail -n1 <<<"$out")) $(sed '$d' <<<"$out" | head -c 300)"
}

test_anthropic() {
  local model="$1" body out text
  body="$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 50,
    "disable_fallbacks": True, "messages": [{"role": "user", "content": "Réponds uniquement : OK"}]}))' "$model")"
  out="$(api_curl "$KEY" /v1/messages "$body" -H 'anthropic-version: 2023-06-01')"
  text="$(sed '$d' <<<"$out" | json_get '[b["text"] for b in d["content"] if b["type"]=="text"][0]')"
  [ -n "$text" ] && pass "$model · Anthropic /v1/messages → « ${text:0:40} »" \
    || fail "$model · Anthropic (HTTP $(tail -n1 <<<"$out")) $(sed '$d' <<<"$out" | head -c 300)"
}

# test_fallback — mistral-small under a simulated Mistral outage must be served by Scaleway.
test_fallback() {
  local files="${COMPOSE_FILE:-docker-compose.yml}" headers out
  echo "Fallback Mistral → Scaleway (panne simulée, redémarrage de LiteLLM)…"
  # Always leave LiteLLM in its normal state, even if a check below aborts the script.
  # shellcheck disable=SC2064  # $files is expanded now: it is local and gone when the trap fires.
  trap "echo 'Retour à la normale…'; COMPOSE_FILE='$files' docker compose up -d --wait litellm >/dev/null 2>&1" EXIT
  COMPOSE_FILE="$files:scripts/panne-mistral.yml" docker compose up -d --wait litellm >/dev/null 2>&1
  headers="$(mktemp)"
  out="$(api_curl "$KEY" /v1/chat/completions "$(chat_body mistral-small 'Réponds uniquement : OK')" -D "$headers" || true)"
  if [ "$(tail -n1 <<<"$out")" = 200 ] && grep -qi '^x-litellm-model-group: mistral-small-secours' "$headers"; then
    pass "mistral-small servi par $(grep -i '^x-litellm-model-name:' "$headers" | cut -d' ' -f2- | tr -d '\r')"
  else
    fail "pas de bascule (HTTP $(tail -n1 <<<"$out")) $(sed '$d' <<<"$out" | head -c 300)"
  fi
  rm -f "$headers"
}

echo "Passerelle : $(api_base_url)"
MODELS="$(api_curl "$KEY" /v1/models '' -X GET | sed '$d' | json_get '" ".join(sorted(m["id"] for m in d["data"]))')"
[ -n "$MODELS" ] || { echo "❌ impossible de lister les modèles (clé openwebui enregistrée ? ./scripts/create-keys.sh)"; exit 1; }
echo "Modèles actifs : $MODELS"
for m in $MODELS; do
  test_tool_call "$m"
  test_anthropic "$m"
done

if { [ "${LITELLM_CONFIG:-config.yaml}" = config.scaleway.yaml ] || [ -n "${FORCE_FALLBACK:-}" ]; } && [ "${1:-}" != --sans-panne ]; then
  test_fallback
else
  echo "Fallback : non testé (Scaleway non configuré ou --sans-panne)"
fi

finish
