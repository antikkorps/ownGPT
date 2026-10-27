#!/usr/bin/env bash
# Minimal gateway call: summary of a short text with the "automatisation" key.
#   export OWNGPT_API_URL=https://api.exemple.fr OWNGPT_AUTOMATION_KEY=sk-...
set -euo pipefail

curl -sS "${OWNGPT_API_URL:?}/v1/chat/completions" \
  -H "Authorization: Bearer ${OWNGPT_AUTOMATION_KEY:?}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-small",
    "max_tokens": 300,
    "messages": [{"role": "user", "content": "Résume en 3 puces : La charte télétravail autorise 2 jours par semaine, avec présence obligatoire le mardi. Une indemnité de 2,50 € par jour est versée, plafonnée à 50 € par mois. La connexion se fait uniquement via le VPN."}]
  }' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"]) if "choices" in d else print(d)'
