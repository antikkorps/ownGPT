#!/usr/bin/env bash
# Unit test of the French Presidio analyzer, without LiteLLM.
# Usage: presidio/test-analyzer.sh [image]   (default: the image built by docker compose)
set -euo pipefail

IMAGE="${1:-owngpt/presidio-analyzer-fr:2.2.366-fr_core_news_lg}"
NAME="presidio-test-$$"
PORT="${PORT:-53001}"

docker run -d --rm --name "$NAME" -p "127.0.0.1:${PORT}:3000" "$IMAGE" >/dev/null
trap 'docker stop "$NAME" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && break
  sleep 2
done

analyze() {
  curl -s "http://127.0.0.1:${PORT}/analyze" -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "language": "fr"}))' "$1")"
}

FAIL=0
expect() {  # expect <ENTITY> <text>
  local entities
  entities="$(analyze "$2" | python3 -c 'import json,sys
r=json.load(sys.stdin)
print(" ".join(sorted({e["entity_type"] for e in r})) if isinstance(r,list) else "ERROR:"+json.dumps(r))')"
  if [[ " $entities " == *" $1 "* ]]; then
    echo "PASS  $1  <- $2"
  else
    echo "FAIL  $1 attendu, obtenu [$entities]  <- $2"; FAIL=1
  fi
}
expect_none() {
  local out
  out="$(analyze "$1")"
  if [ "$out" = "[]" ]; then echo "PASS  (aucune entité)  <- $1"; else echo "FAIL  aucune entité attendue, obtenu $out"; FAIL=1; fi
}

expect PERSON        "Bonjour, je suis Camille Durand et je travaille à Lyon."
expect EMAIL_ADDRESS "Écrivez-moi à camille.durand@exemple.fr pour la suite."
expect PHONE_NUMBER  "Mon portable est le 06 12 34 56 78."
expect PHONE_NUMBER  "Appelez le +33 6 12 34 56 78 demain."
expect IBAN_CODE     "Mon IBAN est FR76 3000 6000 0112 3456 7890 189."
expect CREDIT_CARD   "Ma carte bancaire : 4111 1111 1111 1111, expiration 12/28."
expect FR_NIR        "Mon numéro de sécurité sociale est 1 85 05 78 006 084 91."
expect FR_NIR        "Dossier de l'assuré : 285072B00412365"
expect FR_NIR        "Immatriculation en cours (personne née à l'étranger) : 4 85 05 78 006 084 38"
expect FR_NIR        "Numéro de sécurité sociale sans clé : 1 85 05 78 006 084"
expect_none          "Référence dossier 1234567890123 à conserver."
expect_none          "Commande 1 85 05 78 006 084 36 expédiée."
expect_none          "Peux-tu résumer les avantages du télétravail en trois points ?"

exit "$FAIL"
