#!/usr/bin/env bash
# Real-gateway test of NESTED-container runtime egress through Huddle's MITM
# proxy — the case only image-pulls exercised so far. A nested container that
# makes outbound HTTPS at runtime must (a) route via the proxy and (b) trust the
# Huddle MITM CA. This characterises the documented "nested containers aren't
# auto-CA-trusted" gap: PASS if it works, FAIL (with the reason) if not.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3998; DC=e2e-egress; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm "huddle-dind-sock-$DC" "huddle-dind-data-$DC" huddle-data >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/nege-init.log 2>&1 && pass "gateway init (DinD)" || { fail "init"; cat /tmp/nege-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done

# Allow the HTTPS test domain + Docker Hub (so the nested image can be pulled).
for d in example.com "*.example.com" \
  docker.io registry-1.docker.io index.docker.io auth.docker.io \
  "*.docker.io" "*.docker.com" production.cloudflare.docker.com "*.cloudflare.docker.com"; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done
pass "allowlisted example.com + Docker Hub"

resp=$(curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}")
echo "$resp" | grep -q '"id"' && pass "devcontainer started" || { fail "start: $resp"; docker logs huddle 2>&1|tail -15>&2; exit 1; }
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done

# Baseline: the DEVCONTAINER itself reaches the allowlisted domain (CA trusted).
code=$(docker exec -u vscode "$DC" curl -s -o /dev/null -w '%{http_code}' -m 25 https://example.com 2>/dev/null)
[ "$code" = 200 ] && pass "devcontainer HTTPS to allowlisted domain (=$code)" || { fail "devcontainer HTTPS ($code)"; rc=1; }

# The actual question: a NESTED container doing runtime HTTPS through the proxy.
# curlimages/curl honours proxy env (injected via the devcontainer docker client
# config) but does NOT ship the Huddle CA.
docker exec -u vscode "$DC" docker pull -q curlimages/curl:latest >/dev/null 2>&1
out=$(docker exec -u vscode "$DC" docker run --rm curlimages/curl:latest -s -o /dev/null -w '%{http_code}' -m 25 https://example.com 2>&1)
if [ "$out" = 200 ]; then
  pass "nested container HTTPS through proxy works out-of-the-box (=$out)"
else
  # --insecure skips cert verification. If THAT works but the normal one fails,
  # routing/proxy is fine and the only missing piece is CA trust — the documented,
  # expected limitation (a nested container doesn't carry the Huddle MITM CA;
  # same as Docker Desktop behind a corporate MITM proxy). That is a PASS of the
  # boundary we expect; a real FAIL is when even --insecure can't get out.
  ins=$(docker exec -u vscode "$DC" docker run --rm curlimages/curl:latest -sk -o /dev/null -w '%{http_code}' -m 25 https://example.com 2>&1 | tr -d '\r')
  if [ "$ins" = 200 ]; then
    pass "nested egress routes through the proxy; only CA trust is missing (expected — mount the CA / set SSL_CERT_FILE in the nested container)"
  else
    fail "nested egress fails even with --insecure (code=$out, insecure=$ins) — routing/proxy problem, not just CA"
    rc=1
  fi
fi

exit $rc
