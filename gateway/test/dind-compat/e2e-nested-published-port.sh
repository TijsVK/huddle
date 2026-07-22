#!/usr/bin/env bash
# Regression for the DinD egress<->docker-proxy collision: a REAL Huddle gateway
# (HUDDLE_DIND=1) applies an OUTPUT egress policy in the devcontainer netns
# (DNAT :80 -> proxy, DROP all other tcp except lo+huddle). The dind daemon's
# docker-proxy forwards a published port by connecting localhost:<pub> ->
# <container-ip>:<port> OUT the docker0 bridge — which that policy caught:
#   * any port  -> hit the blanket `-p tcp -j DROP`  (published port unreachable)
#   * port 80   -> hit the `--dport 80 -j DNAT`      (curl got 502 via the proxy)
# So NO published port of a nested container was reachable from the devcontainer
# (Aspire project->SqlServer, `docker compose` port mappings, testcontainers).
# The fix exempts bridge-bound traffic (docker0 / br-*) from both rules. This
# test asserts a nested container's published :80 and a large transfer both work
# from the devcontainer. The harness (tools/*.sh) never caught this: it runs a
# bare dind daemon WITHOUT the gateway's egress policy.
#
# Requires locally-built huddle-local:dind + huddle-e2e-base:latest.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3972; DC=e2e-nested-pub; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-data-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; rm -rf /tmp/dc-sockets/"$DC" 2>/dev/null||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/np-init.log 2>&1 && pass "gateway init (DinD)" || { fail init; cat /tmp/np-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
for d in docker.io registry-1.docker.io auth.docker.io "*.docker.io" "*.docker.com" production.cloudflare.docker.com "*.cloudflare.docker.com"; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done
curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done
pass "devcontainer started"

# The egress policy must actually be in place (else this test proves nothing).
docker exec -u root "$DC" iptables -S OUTPUT 2>/dev/null | grep -q -- '-p tcp -j DROP' \
  && pass "egress OUTPUT DROP policy present (real gateway, not harness)" || { fail "no egress policy — test would be vacuous"; rc=1; }

log "run nested nginx with a published port (:8080 -> container :80)"
docker exec -u vscode "$DC" sh -c 'docker rm -f ngx >/dev/null 2>&1; docker run -d --name ngx -p 8080:80 nginx:alpine >/dev/null 2>&1' \
  && pass "nested nginx published :8080" || { fail "nginx start"; rc=1; }
for i in $(seq 1 20); do docker exec -u vscode "$DC" sh -c 'docker exec ngx true' >/dev/null 2>&1 && break; sleep 1; done

# port 80 inside the container -> exercised the --dport 80 DNAT bug (was 502).
code=$(docker exec -u vscode "$DC" bash -lc 'curl -s -o /dev/null -w "%{http_code}" -m10 http://localhost:8080')
[ "$code" = "200" ] && pass "devcontainer -> nested published :80 == 200 (was 502 via proxy DNAT)" || { fail "nested published :80 got $code (expected 200)"; rc=1; }

# a large body -> proves the full bidirectional forward path (no MTU/short-read).
docker exec -u vscode "$DC" sh -c 'docker exec ngx sh -c "head -c 5000000 /dev/urandom > /usr/share/nginx/html/big.bin"' >/dev/null 2>&1
sz=$(docker exec -u vscode "$DC" bash -lc 'curl -s -o /dev/null -w "%{size_download}" -m20 http://localhost:8080/big.bin')
[ "$sz" = "5000000" ] && pass "5MB transfer through published port intact ($sz bytes)" || { fail "large transfer short/blocked ($sz/5000000)"; rc=1; }

# a non-80 published port -> exercised the blanket DROP bug (was dropped).
docker exec -u vscode "$DC" sh -c 'docker rm -f ngx2 >/dev/null 2>&1; docker run -d --name ngx2 -p 9090:80 nginx:alpine >/dev/null 2>&1'
for i in $(seq 1 20); do docker exec -u vscode "$DC" sh -c 'docker exec ngx2 true' >/dev/null 2>&1 && break; sleep 1; done
code2=$(docker exec -u vscode "$DC" bash -lc 'curl -s -o /dev/null -w "%{http_code}" -m10 http://localhost:9090')
[ "$code2" = "200" ] && pass "devcontainer -> nested published :9090 (non-80) == 200 (was DROPped)" || { fail "nested published :9090 got $code2 (expected 200)"; rc=1; }

# egress itself must STILL be enforced: a devcontainer curl to a non-allowlisted
# external host must not sneak out (the fix must not have opened the policy).
ext=$(docker exec -u vscode "$DC" bash -lc 'curl -s -o /dev/null -w "%{http_code}" -m8 http://example.org 2>/dev/null'; echo)
[ "$ext" != "200" ] && pass "external egress still blocked/proxied (got '${ext:-blocked}', not a clean 200)" || { fail "SECURITY: external egress now reachable (200) — fix widened the policy"; rc=1; }

exit $rc
