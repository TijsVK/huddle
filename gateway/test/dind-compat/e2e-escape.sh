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
# not image-missing. Retry: Docker Hub via the MITM proxy can be slow on a cold
# start (transient), which would otherwise read as "not pullable".
for i in $(seq 1 6); do
  docker exec -u vscode "$DC" docker pull -q alpine:3.20 >/dev/null 2>&1
  docker exec -u vscode "$DC" docker image inspect alpine:3.20 >/dev/null 2>&1 && break
  sleep 5
done
if ! docker exec -u vscode "$DC" docker image inspect alpine:3.20 >/dev/null 2>&1; then
  fail "setup: alpine not pullable (Docker Hub not reachable) — test inconclusive"; exit 1
fi
pass "setup: alpine image present (escape attempts will use it)"

HOST_HN=$(hostname)

# 0. CRITICAL (findings #1/#2): there must be NO unfiltered daemon socket. With the
#    authz-plugin model dockerd exposes only docker.sock (authz-guarded); the old
#    inner.sock is gone. So inner.sock must not exist in the devcontainer's mount,
#    and docker.sock must actually enforce authz (a raw privileged create over it
#    is denied), not be a second unguarded daemon.
if docker exec -u vscode "$DC" test -S /var/run/dind/inner.sock 2>/dev/null; then
  fail "inner.sock present in the devcontainer (should not exist under authz)"; rc=1
else pass "no inner.sock in the devcontainer"; fi
raw=$(docker exec -u vscode "$DC" sh -c 'curl -s -o /dev/null -w "%{http_code}" --unix-socket /var/run/dind/docker.sock -X POST -H "content-type: application/json" --data "{\"Image\":\"alpine:3.20\",\"HostConfig\":{\"Privileged\":true}}" http://x/v1.43/containers/create 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
[ "$raw" = 403 ] && pass "raw privileged create over docker.sock is authz-denied (403)" || { fail "raw privileged create not denied (HTTP $raw) — authz not enforcing"; rc=1; }

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

# 4. Host-path bind of the host root must not reach the real host fs (in DinD it
#    resolves to the disposable sidecar root, and `/` is refused anyway as an
#    ancestor of the daemon socket dir).
hb=$(docker exec -u vscode "$DC" docker run --rm -v /:/hostroot:ro alpine:3.20 cat /hostroot/etc/hostname 2>/dev/null | tr -d '[:space:]')
[ "$hb" = "$HOST_HN" ] && { fail "host-path bind reached the host root ($hb)"; rc=1; } || pass "host-path bind does not reach the host root"

# 5. No UNFILTERED daemon socket exists anywhere a nested bind could reach. With
#    the authz-plugin model dockerd has ONE socket (docker.sock, authz-guarded);
#    there is no inner.sock, so scanning the plausible locations finds nothing.
bypass=0
for src in /var/run/dind /run/dind /var/run /run /; do
  found=$(docker exec -u vscode "$DC" docker run --rm -v "$src:/d" alpine:3.20 sh -c 'find /d -maxdepth 3 -name inner.sock 2>/dev/null | head -1' 2>/dev/null | tr -d '[:space:]')
  [ -n "$found" ] && { fail "found an inner.sock via $src ($found)"; bypass=1; rc=1; }
done
[ "$bypass" = 0 ] && pass "no unfiltered daemon socket reachable by a nested bind"

# 5b. Binding docker.sock (the real, authz-guarded socket) into a nested container
#     IS allowed (Testcontainers Ryuk / docker-outside-of-docker) but stays
#     guarded: a --privileged create issued THROUGH it must still be refused.
docker exec -u vscode "$DC" docker pull -q docker:28-cli >/dev/null 2>&1
dood=$(docker exec -u vscode "$DC" docker run --rm -v /var/run/dind/docker.sock:/var/run/docker.sock docker:28-cli \
  sh -c 'docker run --rm --privileged alpine:3.20 true 2>&1' | tr -d '\r')
if printf '%s' "$dood" | grep -qi "denied\|not permitted"; then
  pass "docker.sock passthrough stays authz-guarded (privileged-through-Ryuk refused)"
else
  fail "privileged create through the bound docker.sock was NOT refused ($dood)"; rc=1
fi

# 5c. MaskedPaths unmask (finding #3): a create that clears /proc/kcore's mask
#     (host kernel memory) must be refused even without --privileged.
mp=$(docker exec -u vscode "$DC" sh -c 'curl -s -o /dev/null -w "%{http_code}" --unix-socket /var/run/dind/docker.sock -X POST -H "content-type: application/json" --data "{\"Image\":\"alpine:3.20\",\"HostConfig\":{\"MaskedPaths\":[]}}" http://x/v1.43/containers/create 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
[ "$mp" = 403 ] && pass "MaskedPaths unmask refused (finding #3)" || { fail "MaskedPaths unmask not refused (HTTP $mp)"; rc=1; }

# 6. A benign (non-socket) host-path bind MUST still be forwarded — the DinD
#    compat win (compose/testcontainers workspace mounts). It resolves against the
#    sidecar fs; reading the sidecar's own /etc/alpine-release proves it works.
ok=$(docker exec -u vscode "$DC" docker run --rm -v /etc/alpine-release:/x:ro alpine:3.20 cat /x 2>/dev/null | tr -d '[:space:]')
[ -n "$ok" ] && pass "benign host-path bind still forwarded (compose/testcontainers compat: $ok)" || { fail "benign host-path bind was blocked (compat regression)"; rc=1; }

exit $rc
