#!/usr/bin/env bash
# Seamless migration: a devcontainer created in CLASSIC (socket-proxy) mode is
# migrated to DinD by recreating it from its labels, with portal state (a
# firewall rule) preserved across the switch. Forced recreate; same UX after.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3995; DC=e2e-migrate; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm "huddle-dind-sock-$DC" "huddle-dind-data-$DC" huddle-data >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; rm -f /tmp/dc-sockets/"$DC"/docker.sock 2>/dev/null||true; }
trap cleanup EXIT
cleanup

COMMON="HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT"

# ── 1. classic mode ──────────────────────────────────────────────────────────
log "huddle init (CLASSIC, no HUDDLE_DIND)"
env $COMMON node "$REPO/cli/dist/index.js" init >/tmp/mg-init1.log 2>&1 && pass "gateway init (classic)" || { fail "init classic"; cat /tmp/mg-init1.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
apiup(){ for i in $(seq 1 40); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
apiup || { fail "API not up"; exit 1; }

# A portal rule that must survive the migration (persisted in huddle-data) +
# Docker Hub so the migrated devcontainer can pull hello-world through the proxy.
for d in migrate-marker.example docker.io registry-1.docker.io auth.docker.io "*.docker.io" "*.docker.com" production.cloudflare.docker.com "*.cloudflare.docker.com"; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done

resp=$(curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}")
echo "$resp" | grep -q '"id"' && pass "devcontainer started (classic)" || { fail "start: $resp"; docker logs huddle 2>&1|tail -10>&2; exit 1; }
sleep 3
docker inspect "$DC" --format '{{range .Mounts}}{{.Destination}} {{end}}' | grep -q '/var/run/huddle' \
  && pass "classic devcontainer uses the socket-proxy mount (/var/run/huddle)" || { fail "not classic?"; rc=1; }
docker ps --filter name="dind-$DC" -q | grep -q . && { fail "unexpected sidecar in classic mode"; rc=1; } || pass "no private-daemon sidecar in classic mode"

# ── 2. switch the gateway to DinD (re-init; same data volume → same token/rules)
log "huddle init (DinD) — devcontainer persists across the gateway swap"
env $COMMON HUDDLE_DIND=1 node "$REPO/cli/dist/index.js" init >/tmp/mg-init2.log 2>&1 && pass "gateway re-init (DinD)" || { fail "init dind"; cat /tmp/mg-init2.log>&2; exit 1; }
apiup || { fail "API not up after re-init"; exit 1; }
sleep 3
# The rule persisted (same huddle-data volume).
curl -s -H "$AUTH" "$API/api/rules" 2>/dev/null | grep -q 'migrate-marker.example' && pass "portal state (firewall rule) preserved across mode switch" || { fail "rule lost across re-init"; rc=1; }

# ── 3. migrate the devcontainer ──────────────────────────────────────────────
log "migrating $DC to DinD"
mres=$(curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/containers/$DC/migrate" -d '{}')
echo "$mres" | grep -q '"mode":"dind"' && pass "migrate API returned dind mode" || { fail "migrate: $mres"; docker logs huddle 2>&1|tail -12>&2; rc=1; }

for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done
docker inspect "$DC" --format '{{range .Mounts}}{{.Destination}} {{end}}' | grep -q '/var/run/dind' \
  && pass "migrated devcontainer now uses the private-daemon mount (/var/run/dind)" || { fail "no /var/run/dind after migrate"; rc=1; }
docker ps --filter name="dind-$DC" --filter status=running -q | grep -q . && pass "private-daemon sidecar running after migrate" || { fail "no sidecar after migrate"; rc=1; }
docker exec -u vscode "$DC" docker run --rm hello-world >/dev/null 2>&1 \
  && pass "docker fully works in the migrated devcontainer (unrestricted private daemon)" || { fail "docker not working after migrate"; rc=1; }

exit $rc
