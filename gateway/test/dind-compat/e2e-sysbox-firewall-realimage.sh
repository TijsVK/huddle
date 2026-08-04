#!/usr/bin/env bash
# Firewall behaviour under HUDDLE_SYSBOX=1, driven by a REAL gateway.
# Covers what the egress script doesn't: the DENY path, the request->approve loop
# (dynamic policy on a running devcontainer), root bypass attempts from inside the
# devcontainer, and nested-container egress in both directions.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3995; DC=e2e-sbx-real; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; rm -rf /tmp/dc-sockets/"$DC" 2>/dev/null||true; }
[ -n "${KEEP:-}" ] || trap cleanup EXIT
cleanup

export HUDDLE_SYSBOX=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 \
       BASE_IMAGE_VSCODE=base-devimage-vscode-sysbox:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/sbxfw-init.log 2>&1 && pass "gateway init (SYSBOX)" || { fail init; cat /tmp/sbxfw-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done

allow(){ curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$1\",\"status\":\"allow\"}" >/dev/null 2>&1; }
# Only example.com + Docker Hub. example.org is deliberately NOT allowlisted.
for d in example.com "*.example.com" docker.io registry-1.docker.io auth.docker.io "*.docker.io" "*.docker.com" production.cloudflare.docker.com "*.cloudflare.docker.com"; do allow "$d"; done
pass "allowlist seeded (example.com + Docker Hub; example.org NOT allowed)"

curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" \
  -d "{\"imageName\":\"base-devimage-vscode-sysbox:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 90); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done
docker exec -u vscode "$DC" docker version >/dev/null 2>&1 \
  && pass "devcontainer up with its own in-container dockerd (sysbox, no sidecar)" \
  || { fail "in-container dockerd not reachable"; docker exec "$DC" tail -20 /var/log/huddle-dockerd.log 2>&1 >&2; rc=1; }

dcurl(){ docker exec -u vscode "$DC" curl -s -o /dev/null -w '%{http_code}' -m 25 "$@" 2>/dev/null; }

# ── 1. allow path ────────────────────────────────────────────────────────────
code=""; for i in $(seq 1 8); do code=$(dcurl https://example.com); [ "$code" = 200 ] && break; sleep 3; done
[ "$code" = 200 ] && pass "allowlisted domain reachable (=$code)" || { fail "allowlisted domain ($code)"; rc=1; }

# ── 2. deny path ─────────────────────────────────────────────────────────────
code=$(dcurl https://example.org)
[ "$code" = 200 ] && { fail "NOT-allowlisted domain reachable (=$code) — firewall bypassed"; rc=1; } \
                  || pass "not-allowlisted domain blocked (=$code)"

# ── 3. request -> approve loop on a RUNNING devcontainer ─────────────────────
sleep 2
req=$(curl -s -H "$AUTH" "$API/api/rules?status=requested")
echo "$req" | grep -q 'example.org' && pass "blocked attempt logged as a firewall REQUEST in the portal" \
  || { fail "no requested rule for example.org: $req"; rc=1; }
rid=$(curl -s -H "$AUTH" "$API/api/rules?status=requested" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const r=JSON.parse(d);const m=r.find(x=>String(x.domain).includes("example.org"));process.stdout.write(m?String(m.id):"")}catch(e){process.stdout.write("")}})')
if [ -n "$rid" ]; then
  res=$(curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules/$rid/resolve" -d '{"status":"allow","scope":"rule"}')
  echo "$res" | grep -q '"status":"allow"' && pass "operator approval accepted by the API (rule $rid)" \
    || { fail "resolve did not set allow: $res"; rc=1; }
  code=""; for i in $(seq 1 8); do code=$(dcurl https://example.org); [ "$code" = 200 ] && break; sleep 2; done
  [ "$code" = 200 ] && pass "approval takes effect live on a running devcontainer, no restart (=$code)" \
                    || { fail "approved domain still blocked (=$code)"; rc=1; }
else
  fail "could not extract requested rule id"; rc=1
fi

# ── 5. nested container egress, both directions ─────────────────────────────
docker exec -u vscode "$DC" docker pull -q curlimages/curl:latest >/dev/null 2>&1
nall=$(docker exec -u vscode "$DC" docker run --rm curlimages/curl:latest -sk -o /dev/null -w '%{http_code}' -m 25 https://example.com 2>&1 | tr -d '\r')
[ "$nall" = 200 ] && pass "nested container reaches allowlisted domain through the proxy (=$nall)" \
                  || { fail "nested container cannot reach allowlisted domain (=$nall)"; rc=1; }
nden=$(docker exec -u vscode "$DC" docker run --rm curlimages/curl:latest -sk -o /dev/null -w '%{http_code}' -m 25 https://neverssl.com 2>&1 | tr -d '\r')
[ "$nden" = 200 ] && { fail "nested container reached a NOT-allowlisted domain (=$nden)"; rc=1; } \
                  || pass "nested container blocked for not-allowlisted domain (=$nden)"
nbyp=$(docker exec -u vscode "$DC" docker run --rm curlimages/curl:latest -sk -o /dev/null -w '%{http_code}' -m 15 https://1.1.1.1/ 2>&1 | tr -d '\r')
[ "$nbyp" = 200 ] && { fail "nested container reached the internet by direct IP (=$nbyp)"; rc=1; } \
                  || pass "nested container cannot bypass by direct IP (=$nbyp)"

# ── 6. network log fidelity ──────────────────────────────────────────────────
audit=$(curl -s -H "$AUTH" "$API/api/audit?container=$DC")
echo "$audit" | grep -q 'example.com' && pass "network log records the devcontainer's requests" \
  || { fail "no audit entries for $DC"; rc=1; }


# ── 4. root bypass attempts from inside the devcontainer ─────────────────────
# The in-container iptables are UX/defence-in-depth; the real boundary is the
# --internal dc-net. Root flushes the filter rules and tries to leave anyway.
# NOTE: only the filter OUTPUT chain is flushed. Flushing nat OUTPUT would also
# remove docker's embedded-DNS DNAT (127.0.0.11:53 -> resolver), breaking DNS for
# every nested container afterwards — a harness artefact, not a product finding.
docker exec -u root "$DC" sh -c 'iptables -F OUTPUT 2>/dev/null; echo flushed-filter-only' >/dev/null 2>&1
byp=$(docker exec -u root "$DC" curl -s -o /dev/null -w '%{http_code}' -m 15 https://1.1.1.1/ 2>/dev/null)
[ "$byp" = 200 ] && { fail "root reached the internet by direct IP after flushing iptables (=$byp)"; rc=1; } \
                 || pass "root cannot bypass by flushing iptables + direct IP (=$byp)"
dns=$(docker exec -u root "$DC" sh -c 'getent hosts example.org >/dev/null 2>&1 && echo resolved || echo blocked')
pass "DNS from devcontainer: $dns (proxy does the resolving; CONNECT carries the hostname)"
# restore the rules for the rest of the test
docker exec -u root "$DC" sh -c 'HUDDLE_IP=$(getent hosts huddle | awk "{print \$1}"); iptables -A OUTPUT -o lo -j ACCEPT; iptables -A OUTPUT -p tcp -d "$HUDDLE_IP" -j ACCEPT; for b in docker0 br+; do iptables -I OUTPUT 1 -o "$b" -j ACCEPT 2>/dev/null||true; done; iptables -A OUTPUT -p tcp -j DROP' >/dev/null 2>&1


exit $rc
