#!/usr/bin/env bash
# Restart resilience: after the gateway container restarts, it must re-establish
# everything a running devcontainer depends on — rejoin dc-net, refresh the
# in-container iptables (huddle's IP may change), keep the private-daemon sidecar
# usable, and restore root grants. Exercises the restore paths in index.ts /
# dind.ts / root-grant.ts that were never run end-to-end.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3996; DC=e2e-restart; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm "huddle-dind-sock-$DC" "huddle-dind-data-$DC" huddle-data >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/rs-init.log 2>&1 && pass "gateway init (DinD)" || { fail init; cat /tmp/rs-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
apiup(){ for i in $(seq 1 40); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
apiup || { fail "API never came up"; exit 1; }

for d in example.com "*.example.com"; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done

resp=$(curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}")
echo "$resp" | grep -q '"id"' && pass "devcontainer started" || { fail "start: $resp"; docker logs huddle 2>&1|tail -10>&2; exit 1; }
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done

egress(){ docker exec -u vscode "$DC" curl -s -o /dev/null -w '%{http_code}' -m 20 https://example.com 2>/dev/null; }

# Baseline before restart. Retry: the first request can 502/time out while the
# MITM proxy warms its leaf-cert cache (cold-start, same as the post-restart check).
b=""; for i in $(seq 1 15); do b=$(egress); [ "$b" = 200 ] && break; sleep 3; done
[ "$b" = 200 ] && pass "egress works before restart" || { fail "egress before restart ($b)"; rc=1; }
# Apply a root grant (permanent) and confirm sudo works.
curl -s -H "$AUTH" -H 'content-type: application/json' -X PUT "$API/api/authz/root-grants/$DC" -d '{"permanent":true}' >/dev/null 2>&1
sleep 2
docker exec -u vscode "$DC" sudo -n id -u 2>/dev/null | grep -q '^0$' && pass "root grant active before restart (passwordless sudo)" || { fail "root grant before restart"; rc=1; }

# ── restart the gateway ──────────────────────────────────────────────────────
log "restarting the huddle gateway container"
docker restart huddle >/dev/null 2>&1
apiup && pass "gateway API back after restart" || { fail "API did not return after restart"; rc=1; }
# Give index.ts restore paths time (network reconnect + iptables refresh + sidecar ensure + root grants).
sleep 12

# Egress must work again (huddle rejoined dc-net + iptables refreshed to its IP).
code=""; for i in $(seq 1 15); do code=$(egress); [ "$code" = 200 ] && break; sleep 3; done
[ "$code" = 200 ] && pass "egress works AFTER restart (dc-net rejoin + iptables refresh)" || { fail "egress after restart ($code)"; rc=1; }

# Private daemon still reachable.
docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && pass "private daemon still reachable after restart" || { fail "private daemon unreachable after restart"; rc=1; }

# Root grant restored/persisted.
docker exec -u vscode "$DC" sudo -n id -u 2>/dev/null | grep -q '^0$' && pass "root grant still active after restart" || { fail "root grant lost after restart"; rc=1; }

# Sidecar tracked as running (ensureDindSidecar).
docker ps --filter name="dind-$DC" --filter status=running -q | grep -q . && pass "private-daemon sidecar running after restart" || { fail "sidecar not running after restart"; rc=1; }

exit $rc
