#!/usr/bin/env bash
# Offline test of caddy/Caddyfile: real Caddy, fake upstreams, clients on a throwaway
# Docker network. Checks that from the outside only the model routes are open, that
# admin routes need an allowed IP, that the client IP can only be forwarded by cloudflared,
# and that X-OpenWebUI-* identity headers cannot be injected from the outside.
set -euo pipefail
cd "$(dirname "$0")/.."

CADDY_IMAGE="$(sed -n 's/^ *image: \(caddy:[^ ]*\)$/\1/p' docker-compose.yml)"
PY_IMAGE=python:3.12.16-alpine
NET="owngpt-caddytest-$$"
SUBNET=172.31.251.0/24
CLOUDFLARED_IP=172.31.251.250
ADMIN_IP=192.0.2.10
FAIL=0

cleanup() { docker rm -f "$NET-caddy" "$NET-stub" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker network create --subnet "$SUBNET" "$NET" >/dev/null
docker run -d --name "$NET-stub" --network "$NET" --network-alias litellm --network-alias openwebui \
  --network-alias authentik-server -v "$PWD/caddy/test:/t:ro" "$PY_IMAGE" python /t/stub.py >/dev/null
docker run -d --name "$NET-caddy" --network "$NET" --network-alias caddy \
  -e OPENWEBUI_SITE=http://chat.test -e LITELLM_SITE=http://api.test -e AUTHENTIK_SITE=http://auth.test \
  -e ADMIN_ALLOWED_IPS="$ADMIN_IP/32" -e CLOUDFLARED_IP="$CLOUDFLARED_IP" \
  -v "$PWD/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" "$CADDY_IMAGE" >/dev/null

# call <client-ip|-> <METHOD> <host> <path> [headers...] — prints "<status> <body>".
call() {
  local ip="$1"; shift
  local net=(--network "$NET"); [ "$ip" != - ] && net+=(--ip "$ip")
  docker run --rm "${net[@]}" -v "$PWD/caddy/test:/t:ro" "$PY_IMAGE" python /t/client.py "$@"
}
expect() {  # expect <status> <label> <call args...>
  local want="$1" label="$2"; shift 2
  local got; got="$(call "$@" | cut -d' ' -f1)"
  if [ "$got" = "$want" ]; then echo "PASS  $want  $label"; else echo "FAIL  $want attendu, obtenu $got  $label"; FAIL=1; fi
}

for _ in $(seq 1 20); do call - GET chat.test / >/dev/null 2>&1 && break; sleep 1; done

echo "-- client Internet quelconque"
expect 200 "chat : interface"                    - GET  chat.test /
expect 200 "api  : /v1/models"                   - GET  api.test /v1/models
expect 200 "api  : /v1/chat/completions"         - POST api.test /v1/chat/completions
expect 200 "api  : /v1/messages (Anthropic)"     - POST api.test /v1/messages
expect 200 "api  : /health/liveliness"           - GET  api.test /health/liveliness
for p in /ui/ /login /v2/login /key/list /key/generate /team/list /user/list /customer/list \
         /budget/list /model/info /config/yaml /spend/logs /global/spend /guardrails/list /health; do
  expect 403 "api  : $p (admin)"                 - GET  api.test "$p"
done
expect 403 "api  : usurpation Cf-Connecting-Ip"  - GET  api.test /key/list "Cf-Connecting-Ip: $ADMIN_IP"
expect 403 "auth : console admin Authentik"      - GET  auth.test /if/admin/
expect 200 "auth : parcours de connexion"        - GET  auth.test /if/flow/default-authentication-flow/

echo "-- en-têtes d'identité Open WebUI injectés de l'extérieur"
leaked="$(call - POST api.test /v1/chat/completions "X-OpenWebUI-User-Email: victime@exemple.fr")"
if [[ "$leaked" == *'"openwebui_headers": []'* ]]; then echo "PASS  supprimés avant LiteLLM"
else echo "FAIL  transmis à LiteLLM : $leaked"; FAIL=1; fi

echo "-- via cloudflared (seul proxy de confiance)"
expect 200 "admin autorisé (IP admin transmise)"  "$CLOUDFLARED_IP" GET api.test /key/list "Cf-Connecting-Ip: $ADMIN_IP"
expect 403 "autre IP transmise"                   "$CLOUDFLARED_IP" GET api.test /key/list "Cf-Connecting-Ip: 198.51.100.7"

[ "$FAIL" = 0 ] && echo "RÉSULTAT : OK" || echo "RÉSULTAT : ÉCHEC"
exit "$FAIL"
