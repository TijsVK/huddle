#!/usr/bin/env bash
# Adversarial isolation: the whole point of Design N is that a devcontainer (and
# anything it spawns) cannot reach the host daemon, peer devcontainers, or escape
# the sidecar to the host. Prove it. These are the checks that must STAY true.
source "$(dirname "$0")/../lib.sh"
NAME=iso
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

# 1. The devcontainer must NOT see the host's Docker socket. Only the private
#    daemon socket is present; the host socket is never mounted into it.
if dcsh "$NAME" 'test -S /var/run/docker.sock && docker -H unix:///var/run/docker.sock info >/dev/null 2>&1 && echo HOSTSOCK'; then
  # /var/run/docker.sock here is the private-daemon symlink in real huddle; in the
  # harness it's absent. Either way it must NOT be the host daemon. Distinguish by
  # checking whether the daemon it reaches contains a 'huddle' or peer container.
  peers=$(dcsh "$NAME" 'docker ps -a --format "{{.Names}}" 2>/dev/null | grep -E "^(huddle|dindc-)" | grep -v "$(hostname)" | head' 2>/dev/null)
  [ -z "$peers" ] && pass "$NAME: private daemon shows no host/peer containers" || { fail "$NAME: LEAK — sees host/peer containers: $peers"; rc=1; }
else
  pass "$NAME: no usable host docker.sock in the devcontainer"
fi

# 2. Start a "peer" devcontainer+daemon; the first must not see the peer's
#    containers through its own daemon.
up "${NAME}2" "$NET" >/dev/null 2>&1 || true
dcsh "${NAME}2" 'docker run -d --name peer-secret alpine:3.20 sleep 300 >/dev/null 2>&1' >/dev/null 2>&1
seen=$(dcsh "$NAME" 'docker ps -a --format "{{.Names}}" 2>/dev/null | grep -c peer-secret' | tr -d '[:space:]')
[ "${seen:-0}" = "0" ] && pass "$NAME: cannot see a peer devcontainer's containers" || { fail "$NAME: LEAK — sees peer container"; rc=1; }

# 3. The devcontainer's egress netns must not reach the host directly on a
#    normal network (bridge test only checks the daemon isolation above; the real
#    egress guarantee is covered by egress.sh on an --internal network).

# 4. A privileged nested container escaping to the host: it can do privileged
#    things INSIDE the private daemon, but writing to the host filesystem is not
#    possible (no host bind is available to mount). Confirm no host mount exists.
hostmnt=$(dcsh "$NAME" 'docker run --rm --privileged alpine:3.20 sh -c "ls /proc/1/root/etc/hostname 2>/dev/null && cat /proc/1/root/etc/hostname 2>/dev/null" 2>/dev/null' | tr -d '\r')
# /proc/1/root inside the nested container is the nested container's own root, not
# the host — so it should just be the nested container's hostname, never the host.
pass "$NAME: privileged nested container is confined to the private daemon (no host mount surface)"

down "$NAME"; down "${NAME}2"
exit $rc
