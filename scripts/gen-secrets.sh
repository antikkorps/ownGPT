#!/usr/bin/env bash
# Prints every secret of .env.example with a fresh random value.
# Usage: ./scripts/gen-secrets.sh --apply   → fills the empty values of .env (created from
#        .env.example if missing), never overwrites an existing secret.
#        ./scripts/gen-secrets.sh           → prints fresh values on stdout only.
set -euo pipefail
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
  [DEMO_USERS_PASSWORD]="Demo-$(openssl rand -hex 4)"
  [LITELLM_KEY_OPENWEBUI]="sk-$(hex)"
  [LITELLM_KEY_OPENCODE]="sk-$(hex)"
  [LITELLM_KEY_CLAUDECODE]="sk-$(hex)"
  [LITELLM_KEY_AUTOMATION]="sk-$(hex)"
  [BACKUP_PASSPHRASE]="$(hex)"
  [AUTHENTIK_SECRET_KEY]="$(openssl rand -base64 60 | tr -d '\n')"
  [AUTHENTIK_DB_PASSWORD]="$(hex)"
)

if [ "${1:-}" = "--apply" ]; then
  [ -f .env ] || cp .env.example .env
  for k in "${!SECRETS[@]}"; do
    # Only fill empty values: never rotate an existing secret by accident.
    if grep -q "^${k}=$" .env; then
      sed -i "s|^${k}=$|${k}=${SECRETS[$k]}|" .env
      echo "généré : $k"
    fi
  done
  chmod 600 .env
else
  for k in "${!SECRETS[@]}"; do echo "${k}=${SECRETS[$k]}"; done
fi
