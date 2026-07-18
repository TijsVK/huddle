#!/usr/bin/env bash
# DinD host-escape guard (finding C1): the private daemon runs with a dockerd
# AUTHORIZATION PLUGIN (dind-authz.ts) that denies the device/kernel/namespace
# vectors on every request — the sidecar is --privileged, so an un-guarded
# --privileged/--device nested container would reach the HOST's block devices.
# Ordinary binds/volumes stay ALLOWED (and even binding docker.sock is safe — it
# is the authz-guarded socket) so compose/testcontainers keep working.
source "$(dirname "$0")/../lib.sh"
NAME=priv
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'docker pull -q alpine:3.20 >/dev/null 2>&1' >/dev/null 2>&1

# 1. --privileged is REFUSED (primary host-escape vector).
out=$(dcsh "$NAME" 'docker run --privileged --rm alpine:3.20 true 2>&1' | tr -d "\r")
assert_contains "$out" "not permitted" "$NAME: --privileged nested container refused" || rc=1

# 2. --device is REFUSED (direct host device access).
out=$(dcsh "$NAME" 'docker run --rm --device /dev/fuse alpine:3.20 true 2>&1' | tr -d "\r")
assert_contains "$out" "not permitted" "$NAME: --device nested container refused" || rc=1

# 3. --pid=host is REFUSED (host namespace).
out=$(dcsh "$NAME" 'docker run --rm --pid=host alpine:3.20 true 2>&1' | tr -d "\r")
assert_contains "$out" "not permitted" "$NAME: --pid=host nested container refused" || rc=1

# 4. No unfiltered daemon socket exists: only docker.sock (authz-guarded), no
#    inner.sock. Binding docker.sock is allowed but stays guarded — a --privileged
#    create issued THROUGH the bound socket is still refused.
inner=$(docker exec "dindc-$NAME-dind" sh -c 'ls /var/run/dind/ 2>/dev/null | grep -c inner.sock' 2>/dev/null | tr -d "[:space:]")
[ "${inner:-0}" = 0 ] && pass "$NAME: no unfiltered inner.sock exposed" || { fail "$NAME: inner.sock present"; rc=1; }
dcsh "$NAME" 'docker pull -q docker:28-cli >/dev/null 2>&1' >/dev/null 2>&1
out=$(dcsh "$NAME" 'docker run --rm -v /var/run/dind/docker.sock:/var/run/docker.sock docker:28-cli sh -c "docker run --rm --privileged alpine:3.20 true 2>&1"' | tr -d "\r")
if printf '%s' "$out" | grep -qi "denied\|not permitted"; then
  pass "$NAME: docker.sock passthrough stays authz-guarded (privileged refused)"
else fail "$NAME: privileged via bound docker.sock not refused"; rc=1; fi

# 5. COMPAT: an ordinary host-path bind is still forwarded (resolves against the
#    sidecar fs). Reading the sidecar's own /etc/alpine-release proves it works.
out=$(dcsh "$NAME" 'docker run --rm -v /etc/alpine-release:/x:ro alpine:3.20 cat /x 2>&1' | tr -d "\r")
assert_contains "$out" "3." "$NAME: benign host-path bind still works (compose/testcontainers compat)" || rc=1

# 6. COMPAT: a non-privileged nested container runs fine.
out=$(dcsh "$NAME" 'docker run --rm alpine:3.20 echo RUN_OK 2>&1' | tr -d "\r")
assert_contains "$out" "RUN_OK" "$NAME: non-privileged nested container runs" || rc=1

# 7. Isolation: the private daemon only sees its own containers.
cnt=$(dcsh "$NAME" 'docker ps -aq | wc -l' 2>/dev/null | tr -d "[:space:]")
pass "$NAME: private daemon isolated (sees only own $cnt container(s))"

down "$NAME"
exit $rc
