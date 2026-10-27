#!/usr/bin/env bash
# Checks the container hardening of the running stack (docker inspect, no API key needed):
# no-new-privileges everywhere, capabilities dropped, no Internet egress for the data tier,
# only Caddy publishing host ports, every image pinned by digest.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Services that never need the Internet: they live on the internal "donnees" network only.
NO_EGRESS=(postgres presidio-analyzer presidio-anonymizer)
# Services that must run with every capability dropped (cap_add only what they need).
CAP_DROP_ALL=(caddy postgres presidio-analyzer presidio-anonymizer litellm openwebui)

inspect() { docker inspect -f "$2" "$(docker compose ps -q "$1")"; }

for s in $(docker compose ps --services --status running); do
  [[ "$(inspect "$s" '{{json .HostConfig.SecurityOpt}}')" == *no-new-privileges* ]] \
    && pass "$s : no-new-privileges" || fail "$s : no-new-privileges absent"
  ports="$(inspect "$s" '{{range $p, $b := .HostConfig.PortBindings}}{{$p}} {{end}}')"
  if [ "$s" = caddy ] || [ -z "$ports" ]; then :; else fail "$s publie des ports : $ports"; fi
done

for s in "${CAP_DROP_ALL[@]}"; do
  [[ "$(inspect "$s" '{{json .HostConfig.CapDrop}}')" == *ALL* ]] && pass "$s : cap_drop ALL" || fail "$s : capacités non retirées"
done

for s in "${NO_EGRESS[@]}"; do
  # Python is present in every image of this list; urllib avoids depending on curl/wget.
  if docker compose exec -T "$s" sh -c 'command -v python3 >/dev/null && exec python3 -c "import urllib.request as u; u.urlopen(\"https://www.example.com\", timeout=5)" || exec getent hosts www.example.com' >/dev/null 2>&1; then
    fail "$s : accès Internet possible"
  else
    pass "$s : pas d'accès Internet"
  fi
done

while read -r svc image; do
  [[ "$image" == *@sha256:* ]] && pass "$svc : image épinglée par empreinte" || fail "$svc : $image sans empreinte"
done < <(docker compose --profile sso --profile tunnel config --format json \
  | python3 -c 'import json,sys
for n,s in json.load(sys.stdin)["services"].items():
    if "build" not in s: print(n, s["image"])')
grep -q '^FROM .*@sha256:' presidio/Dockerfile && pass "presidio/Dockerfile : base épinglée par empreinte" \
  || fail "presidio/Dockerfile : base sans empreinte"

finish
