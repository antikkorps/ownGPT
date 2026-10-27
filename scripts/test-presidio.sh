#!/usr/bin/env bash
# Proves through real curl calls to the LiteLLM gateway (via Caddy) that:
#   (a) e-mail / phone / person name are masked before reaching the provider
#   (b) a credit card number is blocked
#   (c) a French social security number (NIR) is blocked
#   (d) a request without personal data goes through unchanged
#   (e) the coding-agent key keeps names (pii-dev) but still blocks cards and masks e-mails
# Uses the "automatisation" and "opencode" virtual keys (~2 500 tokens in total).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

KEY="${KEY:-$LITELLM_KEY_AUTOMATION}"
MODEL="${MODEL:-mistral-small}"
DEV_KEY="${DEV_KEY:-$LITELLM_KEY_OPENCODE}"
DEV_MODEL="${DEV_MODEL:-mistral-medium}"

# request <message> [key] [model] — sets CODE and BODY globals.
request() {
  local out
  out="$(api_curl "${2:-$KEY}" /v1/chat/completions "$(chat_body "${3:-$MODEL}" "$1")")"
  CODE="$(tail -n1 <<<"$out")"
  BODY="$(sed '$d' <<<"$out")"
}

field() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1" <<<"$BODY"; }

echo "Passerelle : $(api_base_url)  ·  modèle : $MODEL"

echo "(a) Masquage — nom, téléphone, e-mail"
request "Répète mot pour mot, sans rien ajouter : « Rappeler Camille Durand au 06 12 34 56 78 ou camille.durand@exemple.fr »"
if [ "$CODE" = 200 ]; then
  echo "     réponse du modèle : $(field 'd["choices"][0]["message"]["content"]' | head -c 200)"
  entities="$(masked_entities "$(field 'd["id"]')")"
  echo "     journal LiteLLM   : entités masquées = [$entities]"
  for e in PERSON PHONE_NUMBER EMAIL_ADDRESS; do
    [[ " $entities " == *" $e "* ]] && pass "$e masqué" || fail "$e non masqué"
  done
  field 'd["choices"][0]["message"]["content"]' | grep -q -E "Durand|06 12 34|camille\.durand@" \
    && fail "la donnée d'origine apparaît dans la réponse" || pass "aucune donnée d'origine dans la réponse"
else
  fail "HTTP $CODE : $BODY"
fi

echo "(b) Blocage — carte bancaire"
request "Réglez la facture avec ma carte bancaire 4111 1111 1111 1111, expiration 12/28."
[ "$CODE" = 400 ] && grep -q CREDIT_CARD <<<"$BODY" && pass "bloquée (HTTP 400, CREDIT_CARD)" || fail "HTTP $CODE : $BODY"

echo "(c) Blocage — numéro de sécurité sociale (NIR)"
request "Mon numéro de sécurité sociale est le 1 85 05 78 006 084 91, mettez à jour mon dossier."
[ "$CODE" = 400 ] && grep -q FR_NIR <<<"$BODY" && pass "bloqué (HTTP 400, FR_NIR)" || fail "HTTP $CODE : $BODY"

echo "(d) Requête sans donnée personnelle"
request "Donne trois conseils pour bien préparer une réunion, en une ligne chacun."
if [ "$CODE" = 200 ]; then
  entities="$(masked_entities "$(field 'd["id"]')")"
  [ -z "$entities" ] && pass "passée normalement, rien de masqué" || fail "masquage inattendu : [$entities]"
else
  fail "HTTP $CODE : $BODY"
fi

echo "(e) Clé des agents de code (guardrail pii-dev)"
request "Carte de test 4111 1111 1111 1111 dans la fixture" "$DEV_KEY" "$DEV_MODEL"
[ "$CODE" = 400 ] && grep -q CREDIT_CARD <<<"$BODY" && pass "carte bloquée" || fail "carte : HTTP $CODE : $BODY"
request "Réponds OK. # Auteur : Camille Durand, contact camille.durand@exemple.fr" "$DEV_KEY" "$DEV_MODEL"
if [ "$CODE" = 200 ]; then
  entities="$(masked_entities "$(field 'd["id"]')")"
  [[ " $entities " == *" EMAIL_ADDRESS "* ]] && pass "e-mail masqué" || fail "e-mail non masqué : [$entities]"
  [[ " $entities " != *" PERSON "* ]] && pass "noms conservés (code intact)" || fail "PERSON masqué avec la clé dev"
else
  fail "HTTP $CODE : $BODY"
fi

finish
