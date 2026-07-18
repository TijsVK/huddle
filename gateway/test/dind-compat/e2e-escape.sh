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
#     Pre-pull docker:28-cli with a retry so a Docker Hub flake doesn't empty $dood.
for i in $(seq 1 6); do
  docker exec -u vscode "$DC" docker image inspect docker:28-cli >/dev/null 2>&1 && break
  docker exec -u vscode "$DC" docker pull -q docker:28-cli >/dev/null 2>&1; sleep 4
done
if ! docker exec -u vscode "$DC" docker image inspect docker:28-cli >/dev/null 2>&1; then
  fail "setup: docker:28-cli not pullable — 5b inconclusive"; rc=1
else
  dood=$(docker exec -u vscode "$DC" docker run --rm -v /var/run/dind/docker.sock:/var/run/docker.sock docker:28-cli \
    sh -c 'docker run --rm --privileged alpine:3.20 true 2>&1' | tr -d '\r')
  if printf '%s' "$dood" | grep -qi "denied\|not permitted"; then
    pass "docker.sock passthrough stays authz-guarded (privileged-through-Ryuk refused)"
  else
    fail "privileged create through the bound docker.sock was NOT refused ($dood)"; rc=1
  fi
fi

# 5d. Plugin-socket tamper: a nested container must NOT be able to delete/replace
#     the authz plugin socket (that would swap in an allow-all plugin → full
#     bypass). The plugin dir is mounted READ-ONLY into the sidecar; the write
#     must fail even via a parent/root bind (recursive-bind preserves the ro).
tamper=0
for src in /run/docker/plugins /run /; do
  rel=""; [ "$src" = /run ] && rel=/docker/plugins; [ "$src" = / ] && rel=/run/docker/plugins
  if docker exec -u vscode "$DC" docker run --rm -v "$src:/x" alpine:3.20 sh -c "rm -f /x$rel/huddle-authz.sock 2>/dev/null && ! test -e /x$rel/huddle-authz.sock" >/dev/null 2>&1; then
    fail "nested container tampered with the authz plugin socket via $src (authz bypass)"; tamper=1; rc=1
  fi
done
[ "$tamper" = 0 ] && pass "authz plugin socket is tamper-proof from nested containers (read-only)"

# 5c. MaskedPaths unmask (finding #3/#4): a create that clears /proc/kcore's mask
#     (host kernel memory) must be refused even without --privileged.
mp=$(docker exec -u vscode "$DC" sh -c 'curl -s -o /dev/null -w "%{http_code}" --unix-socket /var/run/dind/docker.sock -X POST -H "content-type: application/json" --data "{\"Image\":\"alpine:3.20\",\"HostConfig\":{\"MaskedPaths\":[]}}" http://x/v1.43/containers/create 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
[ "$mp" = 403 ] && pass "MaskedPaths unmask refused (finding #3/#4)" || { fail "MaskedPaths unmask not refused (HTTP $mp)"; rc=1; }

# 5e. Case-insensitive bypass (finding #1): dockerd matches JSON keys
#     case-insensitively, so a lowercase-keyed privileged create must be denied.
cb=$(docker exec -u vscode "$DC" sh -c 'curl -s -o /dev/null -w "%{http_code}" --unix-socket /var/run/dind/docker.sock -X POST -H "content-type: application/json" --data "{\"Image\":\"alpine:3.20\",\"hostconfig\":{\"privileged\":true}}" http://x/v1.43/containers/create 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
[ "$cb" = 403 ] && pass "lowercase-key privileged create refused (finding #1)" || { fail "case-variant create not refused (HTTP $cb)"; rc=1; }

# 5f. Host kernel bind (finding #3): binding the privileged sidecar's /proc/sys
#     lets a nested container write the HOST's core_pattern → host root. Must be
#     refused; and the host core_pattern must be UNCHANGED after the attempt.
before=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)
docker exec -u vscode "$DC" docker run --rm -v /proc/sys:/ps alpine:3.20 sh -c 'echo "|pwned|" > /ps/kernel/core_pattern' >/dev/null 2>&1
after=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)
if docker exec -u vscode "$DC" docker run --rm -v /proc/sys:/ps alpine:3.20 true >/dev/null 2>&1; then
  fail "/proc/sys bind ALLOWED (host kernel escape vector open)"; rc=1
else pass "/proc/sys (host kernel) bind refused"; fi
# 5g. The local-volume-driver bind-in-disguise (device=/proc/sys,o=bind) must also
#     be refused (path lives in VolumeOptions.DriverConfig, not Mounts.Source).
docker exec -u vscode "$DC" docker run --rm --mount 'type=volume,dst=/x,volume-driver=local,volume-opt=type=none,volume-opt=device=/proc/sys,volume-opt=o=bind' alpine:3.20 sh -c 'echo "|vp|" > /x/kernel/core_pattern' >/dev/null 2>&1
if docker exec -u vscode "$DC" docker run --rm --mount 'type=volume,dst=/x,volume-driver=local,volume-opt=type=none,volume-opt=device=/proc/sys,volume-opt=o=bind' alpine:3.20 true >/dev/null 2>&1; then
  fail "local-volume-driver /proc/sys bind ALLOWED (escape vector open)"; rc=1
else pass "local-volume-driver /proc/sys bind refused"; fi
# 5h. Named-volume second door (review#3 #1): create a `local` volume with
#     device=/proc/sys at volume-create, then reference it by name. The volume
#     create must be refused so the volume never exists.
docker exec -u vscode "$DC" docker volume create --driver local --opt type=none --opt o=bind --opt device=/proc/sys evilvol >/dev/null 2>&1
if docker exec -u vscode "$DC" docker volume inspect evilvol >/dev/null 2>&1; then
  fail "named volume with device=/proc/sys was created (escape door open)"; rc=1
  docker exec -u vscode "$DC" docker run --rm -v evilvol:/host alpine:3.20 sh -c 'echo "|nv|" > /host/kernel/core_pattern' >/dev/null 2>&1
else pass "named local-volume device=/proc/sys refused at volume-create"; fi

# 5i. Swarm service (review#3 #2): an unchecked container/mount factory — refused.
docker exec -u vscode "$DC" sh -c 'docker swarm init >/dev/null 2>&1' >/dev/null 2>&1
sw=$(docker exec -u vscode "$DC" docker service create --mount type=bind,source=/proc/sys,target=/host alpine:3.20 true 2>&1 | tr -d '\r')
printf '%s' "$sw" | grep -qi "denied\|not permitted" && pass "swarm service create refused" || { fail "swarm service create NOT refused ($sw)"; rc=1; }

# 5j. Sidecar-scratch symlink (review#4 #2): binding a NON-shared sidecar dir
#     (/tmp,/etc,…) is refused — else a planted symlink (/tmp/x -> /proc) escapes.
#     Only nosymfollow'd shared roots + docker.sock + named volumes are bindable.
if docker exec -u vscode "$DC" docker run --rm -v /tmp:/m alpine:3.20 true >/dev/null 2>&1; then
  fail "bind of sidecar /tmp ALLOWED (symlink-plant escape ground open)"; rc=1
else pass "bind of a non-shared sidecar dir (/tmp) refused (bind allowlist)"; fi

# 5k. Managed-plugin install (review#4 #1): a local plugin tar can request host
#     mounts/caps and runs as root on the privileged sidecar — refused.
pl=$(docker exec -u vscode "$DC" sh -c 'docker plugin install --grant-all-permissions vieux/sshfs 2>&1' | tr -d '\r')
printf '%s' "$pl" | grep -qi "denied\|not permitted" && pass "docker plugin install refused" || { fail "docker plugin install NOT refused ($pl)"; rc=1; }

after=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)
[ "$before" = "$after" ] && pass "host core_pattern unchanged by nested bind attempts" || { fail "HOST ESCAPE — core_pattern changed ($before -> $after)"; rc=1; }

# 6. COMPAT: this is an EMPTY devcontainer (no workspace/shared mounts), so the
#    bind allowlist permits named volumes + the docker socket, but NOT sidecar
#    host paths like /etc (which would be symlink-plant ground). Confirm a named
#    volume round-trips (the compat path that works here); /etc bind is refused.
docker exec -u vscode "$DC" docker volume create escv >/dev/null 2>&1
vok=$(docker exec -u vscode "$DC" docker run --rm -v escv:/v alpine:3.20 sh -c 'echo VOK > /v/f; cat /v/f' 2>/dev/null | tr -d '[:space:]')
[ "$vok" = VOK ] && pass "named-volume round-trip works (compat under the allowlist)" || { fail "named volume broken (compat regression: $vok)"; rc=1; }
docker exec -u vscode "$DC" docker run --rm -v /etc:/x alpine:3.20 true >/dev/null 2>&1 && { fail "/etc bind ALLOWED in empty mode (allowlist hole)"; rc=1; } || pass "/etc (non-shared sidecar dir) bind refused"

exit $rc
