#!/usr/bin/env bash
# Registers in LiteLLM: the per-user budget, the "demo" team and one virtual key
# per usage (values taken from .env so that a reinstall is reproducible).
# Idempotent: re-running updates existing objects instead of failing.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ADVANCED="$(advanced_models_json)"
DEV_MODELS='["glm","devstral","mistral-medium"]'

upsert_budget() {
  local body='{"budget_id":"budget-utilisateur","max_budget":2,"budget_duration":"30d"}'
  litellm_api POST /budget/new "$body" >/dev/null 2>&1 \
    || litellm_api POST /budget/update "$body" >/dev/null
  echo "budget   budget-utilisateur : 2 \$ / 30 j par utilisateur Open WebUI"
}

upsert_team() {
  local body
  body="$(printf '{"team_id":"demo","team_alias":"demo","max_budget":9,"budget_duration":"30d","models":%s,"metadata":{}}' "$ADVANCED")"
  litellm_api POST /team/new "$body" >/dev/null 2>&1 \
    || litellm_api POST /team/update "$body" >/dev/null
  echo "équipe   demo : 9 \$ / 30 j"
}

# upsert_key <alias> <key> <models-json> <max_budget> <metadata-json>
upsert_key() {
  local alias="$1" key="$2" models="$3" budget="$4" metadata="$5" body
  [ -n "$key" ] || { echo "ERREUR : clé vide pour $alias (voir .env)" >&2; exit 1; }
  body="$(printf '{"key":"%s","key_alias":"%s","team_id":"demo","models":%s,"max_budget":%s,"budget_duration":"30d","rpm_limit":60,"metadata":%s}' \
    "$key" "$alias" "$models" "$budget" "$metadata")"
  if litellm_api POST /key/generate "$body" >/dev/null 2>&1; then
    echo "clé      $alias : créée ($budget \$ / 30 j)"
  else
    litellm_api POST /key/update "$body" >/dev/null
    echo "clé      $alias : mise à jour ($budget \$ / 30 j)"
  fi
}

upsert_budget
upsert_team
# Chat: every active model; per-group restriction is enforced by Open WebUI.
upsert_key openwebui   "$LITELLM_KEY_OPENWEBUI"   "$ADVANCED"   5 '{"usage":"chat"}'
# Coding agents: their own keys and budgets, limited to the code models.
upsert_key opencode    "$LITELLM_KEY_OPENCODE"    "$DEV_MODELS" 2 '{"usage":"dev"}'
upsert_key claude-code "$LITELLM_KEY_CLAUDECODE"  "$DEV_MODELS" 2 '{"usage":"dev"}'
upsert_key automatisation "$LITELLM_KEY_AUTOMATION" '["mistral-small"]' 1 '{"usage":"automatisation"}'
