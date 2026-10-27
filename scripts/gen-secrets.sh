#!/usr/bin/env bash
# Prints every secret of .env.example with a fresh random value.
# Usage: ./scripts/gen-secrets.sh --apply   → fills the empty values of .env (created from
#        .env.example if missing), never overwrites an existing secret.
#        ./scripts/gen-secrets.sh           → prints fresh values on stdout only.
set -euo pipefail
# Every file this script creates (.env, temp file) is private to the owner.
umask 077
cd "$(dirname "$0")/.."

hex() { openssl rand -hex 32; }

declare -A SECRETS=(
  [POSTGRES_PASSWORD]="$(hex)"
  [OPENWEBUI_DB_PASSWORD]="$(hex)"
  [LITELLM_DB_PASSWORD]="$(hex)"
  [LITELLM_MASTER_KEY]="sk-$(hex)"
  [LITELLM_SALT_KEY]="sk-$(hex)"
  [LITELLM_UI_PASSWORD]="$(openssl rand -base64 18 | tr -d '/+=')"
  [WEBUI_SECRET_KEY]="$(hex)"
  [OPENWEBUI_ADMIN_PASSWORD]="$(openssl rand -base64 18 | tr -d '/+=')"
  [DEMO_USERS_PASSWORD]="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  [LITELLM_KEY_OPENWEBUI]="sk-$(hex)"
  [LITELLM_KEY_OPENCODE]="sk-$(hex)"
  [LITELLM_KEY_CLAUDECODE]="sk-$(hex)"
  [LITELLM_KEY_AUTOMATION]="sk-$(hex)"
  [BACKUP_PASSPHRASE]="$(hex)"
)

# fill_env — rewrites .env, filling only empty values (an existing secret is never rotated).
# Pure bash: secrets never appear as arguments of another process (sed, awk…).
fill_env() {
  local tmp line key
  tmp="$(mktemp .env.XXXXXX)"
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    if [ "$line" = "${key}=" ] && [ -n "${SECRETS[$key]:-}" ]; then
      printf '%s=%s\n' "$key" "${SECRETS[$key]}"
      echo "généré : $key" >&2
    else
      printf '%s\n' "$line"
    fi
  done < .env > "$tmp"
  mv "$tmp" .env
}

if [ "${1:-}" = "--apply" ]; then
  [ -f .env ] || cp .env.example .env
  chmod 600 .env
  fill_env
else
  for k in "${!SECRETS[@]}"; do echo "${k}=${SECRETS[$k]}"; done
fi
