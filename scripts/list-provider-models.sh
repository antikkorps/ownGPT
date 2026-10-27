#!/usr/bin/env bash
# Lists the model ids actually served by the providers, to confirm the ids used in
# litellm/config*.yaml (GLM, Devstral, Scaleway models) and their tool-calling support.
# Usage: ./scripts/list-provider-models.sh [mistral|scaleway] [filtre]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PROVIDER="${1:-mistral}"
FILTER="${2:-}"

# Runs inside the LiteLLM container: the provider keys never leave the server.
docker compose exec -T litellm python3 - "$PROVIDER" "$FILTER" <<'PY'
import json, os, sys, urllib.request
provider, flt = sys.argv[1], sys.argv[2].lower()
url, key = {
    "mistral": ("https://api.mistral.ai/v1/models", os.environ.get("MISTRAL_API_KEY")),
    "scaleway": ("https://api.scaleway.ai/v1/models", os.environ.get("SCALEWAY_API_KEY")),
}[provider]
if not key:
    sys.exit(f"Clé {provider} absente de .env")
req = urllib.request.Request(url, headers={"Authorization": "Bearer " + key})
models = json.load(urllib.request.urlopen(req, timeout=30))["data"]
print(f"{'identifiant':45} {'outils':7} retrait")
for m in sorted(models, key=lambda m: m["id"]):
    if flt and flt not in m["id"].lower():
        continue
    tools = m.get("capabilities", {}).get("function_calling")
    print(f"{m['id']:45} {'oui' if tools else ('non' if tools is False else '?'):7} {m.get('deprecation') or ''}")
PY
