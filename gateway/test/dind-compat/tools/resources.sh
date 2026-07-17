#!/usr/bin/env bash
# Resource limits on nested containers. The Aspire run logged a cgroup-v2
# delegation warning in the sidecar; confirm --memory/--cpus are actually
# enforced on nested containers (cgroup v2 subtree delegation works).
source "$(dirname "$0")/../lib.sh"
NAME=res
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

mem=$(dcsh "$NAME" 'docker run --rm --memory=64m alpine:3.20 sh -c "cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null"' 2>/dev/null | tr -d '[:space:]')
[ "$mem" = "67108864" ] && pass "$NAME: --memory=64m enforced on nested container (memory.max=$mem)" || { fail "$NAME: memory limit not enforced (got '$mem')"; rc=1; }

cpu=$(dcsh "$NAME" 'docker run --rm --cpus=0.5 alpine:3.20 sh -c "cat /sys/fs/cgroup/cpu.max 2>/dev/null"' 2>/dev/null | tr -d '\r')
case "$cpu" in
  "50000 100000"*) pass "$NAME: --cpus=0.5 enforced on nested container (cpu.max='$cpu')";;
  *) fail "$NAME: cpu limit not enforced (got '$cpu')"; rc=1;;
esac

# pids limit (another cgroup controller)
pids=$(dcsh "$NAME" 'docker run --rm --pids-limit=42 alpine:3.20 sh -c "cat /sys/fs/cgroup/pids.max 2>/dev/null"' 2>/dev/null | tr -d '[:space:]')
[ "$pids" = "42" ] && pass "$NAME: --pids-limit=42 enforced (pids.max=$pids)" || fail "$NAME: pids limit not enforced (got '$pids') (non-fatal)"

down "$NAME"
exit $rc
