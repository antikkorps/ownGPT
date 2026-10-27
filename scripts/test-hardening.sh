#!/usr/bin/env bash
# Checks the container hardening of the running stack (docker inspect, no API key needed):
# no-new-privileges everywhere, capabilities dropped, no Internet egress for the data tier,
# only Caddy publishing host ports, every image pinned by digest.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# Services that never need the Internet: they live on the internal "donnees" network only.
NO_EGRESS=(postgres presidio-analyzer presidio-anonymizer)

inspect() { docker inspect -f "$2" "$(docker compose ps -q "$1")"; }

for s in $(docker compose ps --services --status running); do
  [[ "$(inspect "$s" '{{json .HostConfig.SecurityOpt}}')" == *no-new-privileges* ]] \
    && pass "$s : no-new-privileges" || fail "$s : no-new-privileges absent"
  ports="$(inspect "$s" '{{range $p, $b := .HostConfig.PortBindings}}{{$p}} {{end}}')"
  if [ "$s" = caddy ] || [ -z "$ports" ]; then :; else fail "$s publie des ports : $ports"; fi
done

# Every running service (profiles included) drops all capabilities, adding back only
# what it needs; pids are bounded.
for s in $(docker compose ps --services --status running); do
  [[ "$(inspect "$s" '{{json .HostConfig.CapDrop}}')" == *ALL* ]] && pass "$s : cap_drop ALL" || fail "$s : capacités non retirées"
  [ "$(inspect "$s" '{{.HostConfig.PidsLimit}}')" -gt 0 ] 2>/dev/null && pass "$s : limite de processus" || fail "$s : pas de limite de processus"
done

# reaches_internet <service> — exit 0 if the service can open an HTTPS connection out.
# Every image used here ships python3 or getent; no curl/wget dependency.
reaches_internet() {
  docker compose exec -T "$1" sh -c 'if command -v python3 >/dev/null; then exec python3 -c "import urllib.request as u; u.urlopen(\"https://www.example.com\", timeout=5)"; else exec getent hosts www.example.com; fi' >/dev/null 2>&1 </dev/null
}
# Positive control: if LiteLLM (which must reach the providers) cannot get out either, the
# probe proves nothing (offline host, broken DNS…).
if reaches_internet litellm; then
  pass "témoin : litellm accède à Internet"
  for s in "${NO_EGRESS[@]}"; do
    reaches_internet "$s" && fail "$s : accès Internet possible" || pass "$s : pas d'accès Internet"
  done
else
  fail "témoin : litellm sans Internet, test d'isolement non concluant"
fi

while read -r svc image; do
  [[ "$image" == *@sha256:* ]] && pass "$svc : image épinglée par empreinte" || fail "$svc : $image sans empreinte"
done < <(docker compose --profile sso --profile tunnel config --format json \
  | python3 -c 'import json,sys
for n,s in json.load(sys.stdin)["services"].items():
    if "build" not in s: print(n, s["image"])')
grep -q '^FROM .*@sha256:' presidio/Dockerfile && pass "presidio/Dockerfile : base épinglée par empreinte" \
  || fail "presidio/Dockerfile : base sans empreinte"

finish
