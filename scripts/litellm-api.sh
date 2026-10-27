#!/usr/bin/env bash
# Calls the LiteLLM admin API with the master key, from inside the container
# (the key never appears in the shell history or the process list).
# Usage: ./scripts/litellm-api.sh POST /key/update '{"key":"sk-…","max_budget":10}'
#        ./scripts/litellm-api.sh GET /key/list
set -euo pipefail
source "$(dirname "$0")/lib.sh"
litellm_api "$@"
