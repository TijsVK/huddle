#!/usr/bin/env bash
# Docker-in-Docker-in-Docker: inside the devcontainer's private daemon, run ANOTHER
# dind and a container inside that (3 levels of nesting). Stresses cgroup-v2
# delegation and privileged nesting at depth — some CI/tooling does this.
source "$(dirname "$0")/../lib.sh"
NAME=nested2
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

# Level 2: a dind inside the private daemon (with the same cgroup prep so level-3
# containers can be created).
dcsh "$NAME" 'docker run -d --name l2 --privileged docker:28-dind sh -c "if [ -f /sys/fs/cgroup/cgroup.controllers ]; then mkdir -p /sys/fs/cgroup/init 2>/dev/null||true; xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null||true; sed -e \"s/ / +/g\" -e \"s/^/+/\" < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null||true; fi; dockerd --host=unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1" >/dev/null 2>&1' >/dev/null 2>&1
ok=""; for i in $(seq 1 90); do dcsh "$NAME" 'docker exec l2 docker version >/dev/null 2>&1' && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] && pass "$NAME: level-2 dind daemon up (inside the private daemon)" || { fail "$NAME: level-2 dind never ready"; dcsh "$NAME" 'docker exec l2 tail -5 /var/log/dockerd.log' >&2 2>/dev/null; down "$NAME"; exit 1; }

# Level 3: a container inside the level-2 daemon. Pre-pull to avoid racing the
# first-run image fetch in the fresh L2 daemon.
dcsh "$NAME" 'docker exec l2 docker pull -q alpine:3.20 >/dev/null 2>&1' >/dev/null 2>&1
out=""; for i in $(seq 1 5); do out=$(dcsh "$NAME" 'docker exec l2 docker run --rm alpine:3.20 echo L3_OK' 2>/dev/null | tr -d '\r'); printf '%s' "$out" | grep -q L3_OK && break; sleep 3; done
assert_contains "$out" "L3_OK" "$NAME: level-3 container runs (triple-nested)" || rc=1

# Resource limit at level 3 (cgroup delegation survived two levels).
mem=$(dcsh "$NAME" 'docker exec l2 docker run --rm --memory=32m alpine:3.20 cat /sys/fs/cgroup/memory.max 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
[ "$mem" = "33554432" ] && pass "$NAME: --memory enforced at level 3 (cgroup delegation 2 levels deep)" || fail "$NAME: level-3 memory limit not enforced (got '$mem') (non-fatal)"

dcsh "$NAME" 'docker rm -f l2 >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
