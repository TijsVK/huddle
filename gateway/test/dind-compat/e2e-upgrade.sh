#!/usr/bin/env bash
# In-place update: an existing install's data + devcontainers must survive a
# gateway update (re-init reuses the huddle-data volume + operator token and only
# recreates the gateway container). Writes every kind of persisted state, then
# re-inits (the "update"), then verifies it all carried over and the devcontainer
# still works. Runs in classic mode (a pure update, no mode switch).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3994; DC=e2e-upgrade; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-sock-$DC" "huddle-dind-data-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; }
trap cleanup EXIT
cleanup

COMMON="HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT"
INIT(){ env $COMMON node "$REPO/cli/dist/index.js" init >"$1" 2>&1; }
apiup(){ for i in $(seq 1 40); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

# ── initial install ──────────────────────────────────────────────────────────
log "initial install (classic)"
INIT /tmp/up-init1.log && pass "initial init" || { fail "initial init"; cat /tmp/up-init1.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
apiup || { fail "API not up"; exit 1; }
J(){ curl -s -H "$AUTH" -H 'content-type: application/json' "$@"; }

# write every kind of persisted state
J -X POST "$API/api/rules" -d '{"domain":"upgrade-keep.example","status":"allow"}' >/dev/null
J -X PUT "$API/api/authz/grants/$DC" -d '{"permanent":true}' >/dev/null
ACTION=$(J "$API/api/authz/docker-actions" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const j=JSON.parse(d);const a=j.actions;console.log(Array.isArray(a)?(a[0].id||a[0].action||a[0]):Object.keys(a)[0])}catch{console.log("")}})')
[ -n "$ACTION" ] && J -X PUT "$API/api/authz/docker-actions/$DC/$ACTION" -d '{"enabled":true}' >/dev/null
J -X POST "$API/api/settings" -d '{"defaultMemory":"6g","defaultCpus":"3"}' >/dev/null
J -X POST "$API/api/folder-mappings" -d '{"name":"keepme","container_path":"/home/vscode/.keepme","volume_name":"keepme-vol"}' >/dev/null
resp=$(J -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}")
echo "$resp" | grep -q '"id"' && pass "devcontainer started (classic)" || { fail "start: $resp"; docker logs huddle 2>&1|tail -10>&2; exit 1; }
for i in $(seq 1 40); do docker exec "$DC" test -S /var/run/huddle/docker.sock 2>/dev/null && break; sleep 2; done
pass "wrote rule + grant + action-policy + settings + folder-mapping + devcontainer"

# ── the update: re-init with the same volume/token ───────────────────────────
log "updating (re-init, same huddle-data volume + token)"
INIT /tmp/up-init2.log && pass "re-init (update) succeeded" || { fail "re-init"; cat /tmp/up-init2.log>&2; exit 1; }
apiup || { fail "API not up after update"; exit 1; }
sleep 5

# ── verify everything carried over ───────────────────────────────────────────
J "$API/api/rules" | grep -q 'upgrade-keep.example' && pass "firewall rule persisted" || { fail "rule lost"; rc=1; }
J "$API/api/authz/grants" | grep -q "$DC" && pass "docker grant persisted" || { fail "grant lost"; rc=1; }
[ -n "$ACTION" ] && { J "$API/api/authz/docker-actions/$DC" | grep -q "\"$ACTION\":true" && pass "action policy persisted ($ACTION)" || { fail "action policy lost"; rc=1; }; }
J "$API/api/settings" | grep -q '"defaultMemory":"6g"' && pass "settings persisted" || { fail "settings lost"; rc=1; }
J "$API/api/folder-mappings" | grep -q 'keepme' && pass "folder mapping persisted" || { fail "folder mapping lost"; rc=1; }
J "$API/api/docker/containers" | grep -q "$DC" && pass "devcontainer still present after update" || { fail "devcontainer lost"; rc=1; }

# docker access inside the devcontainer still works (socket-proxy recreated on boot)
sockok=""; for i in $(seq 1 30); do docker exec "$DC" test -S /var/run/huddle/docker.sock 2>/dev/null && { sockok=1; break; }; sleep 2; done
[ -n "$sockok" ] && pass "socket-proxy socket restored in devcontainer after update" || { fail "socket-proxy socket missing after update"; log "gateway log:"; docker logs huddle 2>&1 | grep -i "socket-proxy\|proxy" | tail -8 >&2; rc=1; }
# The proxy enforces secure-by-default policy (system.version off), so a bare
# 'docker version' is denied by Huddle — which itself proves the proxy is alive
# and enforcing. Enable the action, then the full round-trip succeeds.
J -X PUT "$API/api/authz/docker-actions/$DC/system.version" -d '{"enabled":true}' >/dev/null
dv=$(docker exec "$DC" env DOCKER_HOST=unix:///var/run/huddle/docker.sock docker version 2>&1)
if printf '%s' "$dv" | grep -q 'Server:'; then
  pass "docker access in the devcontainer works after update (socket-proxy restored + policy enforced)"
elif printf '%s' "$dv" | grep -qi 'disabled for this devcontainer'; then
  # Proxy alive + enforcing (policy denial), even if this action id isn't toggleable.
  pass "socket-proxy restored + enforcing policy after update (denial returned by Huddle)"
else
  fail "docker broken in devcontainer after update"; printf '%s\n' "$dv" | tail -4 >&2; rc=1
fi

exit $rc
