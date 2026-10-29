#!/usr/bin/env bash
# Pre-push checks: the "Before pushing" command of CLAUDE.md, also run by the git
# pre-push hook and by CI.
# Usage: ./scripts/check.sh   (offline; only small images: caddy, python)
set -euo pipefail
cd "$(dirname "$0")/.."

SHELL_FILES=(scripts/*.sh caddy/*.sh postgres/init/*.sh integrations/automation/*.sh)
PY_FILES=(scripts/*.py seed/*.py seed/tools/*.py integrations/automation/*.py caddy/test/*.py)
JSON_FILES=(seed/*.json seed/*/*.json integrations/*/*.json)

echo "== Syntaxe Bash"
for f in "${SHELL_FILES[@]}"; do bash -n "$f"; done

echo "== Syntaxe Python"
# ast.parse instead of py_compile: no __pycache__ left in the working tree.
python3 -c 'import ast,sys; [ast.parse(open(f, encoding="utf-8").read(), f) for f in sys.argv[1:]]' "${PY_FILES[@]}"

echo "== JSON"
for f in "${JSON_FILES[@]}"; do python3 -m json.tool "$f" >/dev/null; done

echo "== Compose (profil tunnel inclus)"
compose=(docker compose --profile tunnel)
if [ ! -f .env ]; then
  # CI / fresh clone: validate against .env.example filled with throwaway values.
  env_file="$(mktemp)"
  trap 'rm -f "$env_file"' EXIT
  { cat .env.example; ./scripts/gen-secrets.sh; echo "MISTRAL_API_KEY=ci-dummy"; } > "$env_file"
  compose+=(--env-file "$env_file")
fi
"${compose[@]}" config -q

echo "== Montages (dossiers uniquement)"
"${compose[@]}" config --format json | python3 scripts/check_bind_mounts.py

echo "== Caddy (exposition des routes)"
./caddy/test-caddy.sh

echo "OK"
