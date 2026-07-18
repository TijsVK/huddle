#!/usr/bin/env bash
# Red test: stopping and starting a DEVCONTAINER (via Huddle's start endpoint)
# resets its network namespace. That kills the netns-shared DinD sidecar (docker
# access) AND the in-netns egress iptables. Huddle's start path must restore both.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3992; DC=e2e-dcrestart; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-sock-$DC" "huddle-dind-data-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/dcr-init.log 2>&1 && pass "gateway init (DinD)" || { fail init; cat /tmp/dcr-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
for d in example.com "*.example.com"; do curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1; done
curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done

dockerworks(){ docker exec -u vscode "$DC" docker version >/dev/null 2>&1; }
egressworks(){ [ "$(docker exec -u vscode "$DC" curl -s -o /dev/null -w '%{http_code}' -m 20 https://example.com 2>/dev/null)" = 200 ]; }

dockerworks && pass "docker works before restart" || { fail "docker before restart"; rc=1; }
# Retry: the very first HTTPS through a cold MITM proxy (cert-gen + upstream
# connect) can exceed the single-shot timeout; it's warm on retry.
ok=""; for i in $(seq 1 8); do egressworks && { ok=1; break; }; sleep 3; done
[ -n "$ok" ] && pass "egress works before restart" || { fail "egress before restart"; rc=1; }

# ── stop + start the devcontainer via Huddle's start endpoint ─────────────────
log "stopping the devcontainer (netns will reset)"
docker stop "$DC" >/dev/null 2>&1
sleep 2
log "starting it again via POST /api/docker/containers/$DC/start"
curl -s -H "$AUTH" -X POST "$API/api/docker/containers/$DC/start" >/dev/null 2>&1
# give Huddle time to restore sidecar + iptables
sleep 8
for i in $(seq 1 30); do docker inspect "$DC" --format '{{.State.Running}}' 2>/dev/null | grep -q true && break; sleep 2; done

ok=""; for i in $(seq 1 20); do dockerworks && { ok=1; break; }; sleep 3; done
[ -n "$ok" ] && pass "docker works AFTER devcontainer restart (sidecar restored)" || { fail "docker BROKEN after devcontainer restart (sidecar not restored)"; rc=1; }
ok=""; for i in $(seq 1 15); do egressworks && { ok=1; break; }; sleep 3; done
[ -n "$ok" ] && pass "egress works AFTER devcontainer restart (via proxy)" || { fail "egress BROKEN after devcontainer restart"; rc=1; }

# Egress must still be CONFINED after restart — no direct internet without the proxy
# (the --internal network is the primary boundary; iptables is secondary).
if docker exec -u vscode "$DC" curl --noproxy '*' -s -m 8 -o /dev/null https://example.com 2>/dev/null; then
  fail "EGRESS LEAK after devcontainer restart — direct internet reachable"; rc=1
else pass "no egress leak after restart (direct internet still blocked)"; fi

exit $rc
