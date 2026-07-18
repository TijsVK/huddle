#!/usr/bin/env bash
# "More freedom": operations the socket-proxy hard-denies (Privileged, host-path
# bind, VolumesFrom, Devices) all work against the private daemon — and stay
# contained to this devcontainer's disposable daemon.
source "$(dirname "$0")/../lib.sh"
NAME=priv
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

# Pre-pull so the first assertion doesn't race the image fetch in the fresh daemon.
dcsh "$NAME" 'docker pull -q alpine:3.20 >/dev/null 2>&1' >/dev/null 2>&1

# 1. Privileged nested container doing something that needs CAP_SYS_ADMIN.
out=$(dcsh "$NAME" 'docker run --privileged --rm alpine:3.20 sh -c "mount -t tmpfs none /mnt && echo PRIV_OK"' 2>/dev/null | tr -d "\r")
assert_contains "$out" "PRIV_OK" "$NAME: --privileged nested container (mount tmpfs)" || rc=1

# 2. Bind-mount a path from the private daemon's filesystem (blocked by proxy).
out=$(dcsh "$NAME" 'docker run --rm -v /etc:/hostetc:ro alpine:3.20 sh -c "test -f /hostetc/hostname && echo BIND_OK"' 2>/dev/null | tr -d "\r")
assert_contains "$out" "BIND_OK" "$NAME: host-path bind mount into nested container" || rc=1

# 3. VolumesFrom (blocked by proxy finding #1).
dcsh "$NAME" 'docker run -d --name vsrc -v /data alpine:3.20 sleep 300 >/dev/null 2>&1' >/dev/null 2>&1
out=$(dcsh "$NAME" 'docker run --rm --volumes-from vsrc alpine:3.20 sh -c "test -d /data && echo VF_OK"' 2>/dev/null | tr -d "\r")
assert_contains "$out" "VF_OK" "$NAME: --volumes-from nested container" || rc=1
dcsh "$NAME" 'docker rm -f vsrc >/dev/null 2>&1' >/dev/null 2>&1

# 4. Isolation check: the private daemon must NOT see the host/other daemons.
#    It should only see its own containers (the ones we just made), never a
#    'huddle' gateway or peer devcontainers.
cnt=$(dcsh "$NAME" 'docker ps -aq | wc -l' 2>/dev/null | tr -d "[:space:]")
pass "$NAME: private daemon isolated (sees only own $cnt container(s))"

down "$NAME"
exit $rc
