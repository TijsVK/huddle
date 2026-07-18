#!/usr/bin/env bash
# SECURITY red test for finding C1: an untrusted devcontainer must NOT be able to
# escape its private Docker daemon to the host. Attempts the real exploit — a
# nested --privileged container reading the host's block devices / mounting the
# host disk. This test FAILS while the escape is possible (current DinD) and
# PASSES once the host-escape HostConfig vectors are denied on the private daemon.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3988; DC=e2e-escape; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-sock-$DC" "huddle-dind-data-$DC" "huddle-dind-filtersock-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/esc-init.log 2>&1 && pass "gateway init (DinD)" || { fail init; cat /tmp/esc-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
# Allowlist Docker Hub so alpine can be pulled — otherwise the escape runs fail
# for lack of an image and falsely read as "refused".
for d in docker.io registry-1.docker.io auth.docker.io "*.docker.io" "*.docker.com" production.cloudflare.docker.com "*.cloudflare.docker.com"; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done
curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done
# Pre-pull alpine and CONFIRM it's present, so a later failed run = policy-denied,
# not image-missing.
docker exec -u vscode "$DC" docker pull -q alpine:3.20 >/dev/null 2>&1
if ! docker exec -u vscode "$DC" docker image inspect alpine:3.20 >/dev/null 2>&1; then
  fail "setup: alpine not pullable (Docker Hub not reachable) — test inconclusive"; exit 1
fi
pass "setup: alpine image present (escape attempts will use it)"

HOST_HN=$(hostname)

# 1. A --privileged nested container must be REFUSED (the primary escape vector).
if docker exec -u vscode "$DC" docker run --rm --privileged alpine:3.20 true >/dev/null 2>&1; then
  fail "--privileged nested container ALLOWED (escape vector open)"; rc=1
else pass "--privileged nested container refused"; fi

# 2. Even if a container starts, it must NOT see host block devices.
disks=$(docker exec -u vscode "$DC" docker run --rm --privileged alpine:3.20 sh -c 'ls /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]')
[ "${disks:-0}" = 0 ] && pass "no host block devices in a nested privileged container" || { fail "SEES $disks host block devices (escape)"; rc=1; }

# 3. The decisive check: a nested container must NOT be able to read the host fs.
esc=$(docker exec -u vscode "$DC" docker run --rm --privileged alpine:3.20 sh -c '
  for d in /dev/sd* /dev/nvme* /dev/vd*; do
    [ -b "$d" ] || continue
    mkdir -p /m 2>/dev/null
    if mount -o ro "$d" /m 2>/dev/null; then
      [ -e /m/etc/hostname ] && cat /m/etc/hostname 2>/dev/null
      umount /m 2>/dev/null
    fi
  done' 2>/dev/null | tr -d '[:space:]')
if printf '%s' "$esc" | grep -qF "$HOST_HN"; then
  fail "HOST ESCAPE — nested container mounted a host disk and read host hostname ($esc)"; rc=1
else pass "nested container cannot mount/read the host filesystem"; fi

# 4. Host-path bind of a sensitive path must be refused/confined.
hb=$(docker exec -u vscode "$DC" docker run --rm -v /:/hostroot:ro alpine:3.20 cat /hostroot/etc/hostname 2>/dev/null | tr -d '[:space:]')
[ "$hb" = "$HOST_HN" ] && { fail "host-path bind reached the host root ($hb)"; rc=1; } || pass "host-path bind does not reach the host root"

exit $rc
