#!/usr/bin/env bash
# Pre-push checks: the "Before pushing" command of CLAUDE.md, also run by the git
# pre-push hook and by CI.
# Usage: ./scripts/check.sh            full (builds the Presidio image if needed, ~2.7 GB)
#        ./scripts/check.sh --light    no Presidio test (CI: too heavy for a hosted runner)
set -euo pipefail
cd "$(dirname "$0")/.."

SHELL_FILES=(scripts/*.sh presidio/*.sh caddy/*.sh postgres/init/*.sh integrations/automation/*.sh)
PY_FILES=(seed/*.py integrations/automation/*.py presidio/recognizers/*.py caddy/test/*.py)
JSON_FILES=(seed/*.json seed/*/*.json integrations/*/*.json)

echo "== Syntaxe Bash"
for f in "${SHELL_FILES[@]}"; do bash -n "$f"; done

echo "== Syntaxe Python"
# ast.parse instead of py_compile: no __pycache__ left in the working tree.
python3 -c 'import ast,sys; [ast.parse(open(f, encoding="utf-8").read(), f) for f in sys.argv[1:]]' "${PY_FILES[@]}"

echo "== JSON"
for f in "${JSON_FILES[@]}"; do python3 -m json.tool "$f" >/dev/null; done

echo "== Compose (profils sso + tunnel)"
if [ -f .env ]; then
  docker compose --profile sso --profile tunnel config -q
else
  # CI / fresh clone: validate against .env.example filled with throwaway values.
  env_file="$(mktemp)"
  trap 'rm -f "$env_file"' EXIT
  { cat .env.example; ./scripts/gen-secrets.sh; echo "MISTRAL_API_KEY=ci-dummy"; } > "$env_file"
  docker compose --env-file "$env_file" --profile sso --profile tunnel config -q
fi

echo "== Caddy (exposition des routes)"
./caddy/test-caddy.sh

if [ "${1:-}" != --light ]; then
  echo "== Presidio (analyseur français)"
  docker compose build -q presidio-analyzer >/dev/null
  ./presidio/test-analyzer.sh
fi

echo "OK"
