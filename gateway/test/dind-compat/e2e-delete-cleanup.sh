#!/usr/bin/env bash
# Deleting a devcontainer must fully clean up its DinD sidecar + volumes + network
# (no leaks). Also probes an ordering hazard: the sidecar shares the devcontainer's
# netns (--network container:X), so removing X while the sidecar is attached can
# fail unless the sidecar is removed first.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3991; DC=e2e-del; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-data-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; rm -rf /tmp/dc-sockets/"$DC" 2>/dev/null||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/del-init.log 2>&1 && pass "gateway init (DinD)" || { fail init; cat /tmp/del-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done

# spawn a nested container so the private daemon has real state to clean.
docker exec -u vscode "$DC" docker run -d --name inner alpine:3.20 sleep 300 >/dev/null 2>&1

exists_c(){ docker inspect "$1" >/dev/null 2>&1; }
exists_v(){ docker volume inspect "$1" >/dev/null 2>&1; }
exists_n(){ docker network inspect "$1" >/dev/null 2>&1; }

exists_c "$DC" && exists_c "dind-$DC" && pass "devcontainer + sidecar exist before delete" || { fail "setup missing"; rc=1; }
# Socket topology is a host bind DIR (/tmp/dc-sockets/<name>) holding docker.sock
# (filter) + inner.sock (sidecar dockerd), plus the data volume.
[ -S "/tmp/dc-sockets/$DC/docker.sock" ] && exists_v "huddle-dind-data-$DC" && pass "dind sock dir + data volume exist before delete" || { fail "dind sock dir / data volume missing"; rc=1; }

log "DELETE /api/docker/containers/$DC"
resp=$(curl -s -H "$AUTH" -X DELETE "$API/api/docker/containers/$DC")
echo "$resp" | grep -q '"ok":true' && pass "delete API returned ok" || { fail "delete API: $resp"; docker logs huddle 2>&1|tail -8>&2; rc=1; }
sleep 3

exists_c "$DC" && { fail "LEAK: devcontainer still exists"; rc=1; } || pass "devcontainer removed"
exists_c "dind-$DC" && { fail "LEAK: sidecar still exists"; rc=1; } || pass "sidecar removed"
[ -e "/tmp/dc-sockets/$DC" ] && { fail "LEAK: sock dir remains"; rc=1; } || pass "sock dir removed"
exists_v "huddle-dind-data-$DC" && { fail "LEAK: data volume remains"; rc=1; } || pass "data volume removed"
exists_n "dc-net-$DC" && { fail "LEAK: dc-net remains"; rc=1; } || pass "dc-net removed"

exit $rc
