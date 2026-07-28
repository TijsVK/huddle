#!/usr/bin/env bash
# ============================================================================
# VIDEO-RECORDED web-UI E2E: an operator drives the Huddle portal end to end.
#
#   1. open the web UI + log in
#   2. add a devcontainer (Start modal)
#   3. enable docker functionalities (Docker permissions grant)
#   4. run `docker run hello-world` inside it
#   5. approve the firewall rules the image pull needs, live in the UI, as each
#      registry domain surfaces (registry-1.docker.io, auth.docker.io, …)
#   6. verify hello-world printed "Hello from Docker!"
#
# DinD mode is used deliberately: it is the only mode where the container's own
# docker pull egresses through Huddle, so the pull genuinely requires firewall
# approval in the UI (classic mode pulls on a host-side daemon and never asks).
#
# Produces a screen-recording (.webm) + numbered per-step screenshots under
# .artifacts/webui-docker-hello/.
#
# Env: REUSE=1 reuse an already-running gateway on HUDDLE_PORT; KEEP=1 leave the
#      stack up afterwards.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT="${HUDDLE_PORT:-3972}"; DC=ui-demo; API="http://localhost:$PORT"
SHOTDIR="${SHOTDIR:-$HERE/.artifacts/webui-docker-hello}"
PROBE_IMG=huddle-dashboard-probe:latest
pass(){ printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '\033[31mFAIL\033[0m %s\n' "$*"; rc=1; }
log(){  printf '\033[36m[ui-e2e]\033[0m %s\n' "$*" >&2; }
rc=0
cleanup(){ [ "${KEEP:-0}" = 1 ] && return 0; docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-data-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; rm -rf /tmp/dc-sockets/"$DC" 2>/dev/null||true; }
trap cleanup EXIT

rm -rf "$SHOTDIR"; mkdir -p "$SHOTDIR/video"
docker image inspect "$PROBE_IMG" >/dev/null 2>&1 || { log "building $PROBE_IMG"; docker build -t "$PROBE_IMG" -f "$HERE/lib/Dockerfile.probe" "$HERE/lib" >/tmp/probe-build.log 2>&1; }

# ── gateway (DinD) ───────────────────────────────────────────────────────────
if [ "${REUSE:-0}" != 1 ] || ! curl -sf "$API/api/auth/status" >/dev/null 2>&1; then
  KEEP=0 cleanup
  export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
  node "$REPO/cli/dist/index.js" init >/tmp/ui-init.log 2>&1 && pass "gateway init (DinD)" || { fail "gateway init"; cat /tmp/ui-init.log>&2; exit 1; }
else
  log "reusing running gateway on $PORT"
fi
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)")
for i in $(seq 1 30); do curl -sf -H "Authorization: Bearer $TOKEN" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
pass "web UI up ($(curl -s -o /dev/null -w '%{http_code}' "$API/"))"

# ── host-side `docker run hello-world` retry loop (browser approves the rules) ─
# Waits for the browser to create + boot the container, then retries the run;
# each denied attempt surfaces the next registry domain as a pending request.
( until docker exec -u vscode "$DC" docker version >/dev/null 2>&1; do sleep 2; done
  log "container docker reachable — running hello-world (retry until rules approved)"
  for i in $(seq 1 90); do
    if docker exec -u vscode "$DC" bash -lc 'docker run --rm hello-world' > "$SHOTDIR/hello.out" 2>&1; then
      touch "$SHOTDIR/hello.done"; break
    fi
    sleep 3
  done
) &
HELLO_PID=$!

# ── drive the UI in a real browser (video + screenshots) ─────────────────────
log "driving the web UI in headless Chromium (recording video)"
probe=$(docker run --rm --network host \
  -e BASE_URL="$API" -e TOKEN="$TOKEN" -e DC="$DC" \
  -e OUT=/probe/out -e VIDEO=/probe/out/video \
  -v "$HERE/lib/ui-demo-flow.mjs:/probe/ui-demo-flow.mjs:ro" \
  -v "$SHOTDIR:/probe/out" \
  -w /probe "$PROBE_IMG" /probe/ui-demo-flow.mjs 2>&1)
prc=$?
wait $HELLO_PID 2>/dev/null || true

echo "$probe" | tail -1
# name the video deterministically
vid=$(ls -t "$SHOTDIR/video/"*.webm 2>/dev/null | head -1)
[ -n "$vid" ] && cp "$vid" "$SHOTDIR/ui-demo-flow.webm" && log "video: $SHOTDIR/ui-demo-flow.webm"
log "screenshots: $SHOTDIR/*.png"
grep -q 'Hello from Docker' "$SHOTDIR/hello.out" 2>/dev/null && pass "hello-world ran (image pulled through approved firewall rules)" || fail "hello-world did not complete"
[ $prc -eq 0 ] && pass "UI flow completed (container added, docker enabled, rules approved in-browser)" || fail "UI flow reported failure"

if [ "${KEEP:-0}" = 1 ]; then log "KEEP=1 — stack left up. token=$TOKEN port=$PORT dc=$DC"; fi
exit $rc
