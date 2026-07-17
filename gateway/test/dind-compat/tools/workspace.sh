#!/usr/bin/env bash
# Workspace bind-through: the key Design-N fix. A tool inside the devcontainer
# bind-mounts a workspace path into a nested container; because the private
# daemon has its own filesystem, that only shows real files when the workspace is
# ALSO mounted into the sidecar at the same path. The harness shares /work in
# both (as the gateway now does with the real workspace). Also proves writes
# round-trip both ways.
source "$(dirname "$0")/../lib.sh"
NAME=ws
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

# Write a file from the devcontainer into the shared workspace.
dcsh "$NAME" 'echo "from-devcontainer" > /work/marker.txt'

# Bind-mount the workspace into a nested container and read it back (real files).
out=$(dcsh "$NAME" 'docker run --rm -v /work:/w alpine:3.20 cat /w/marker.txt' 2>/dev/null | tr -d '\r')
[ "$out" = "from-devcontainer" ] && pass "$NAME: nested container reads workspace file via bind (=$out)" \
  || { fail "$NAME: workspace bind not visible in nested container ($out)"; rc=1; }

# Write from the nested container; the devcontainer must see it (round-trip).
dcsh "$NAME" 'docker run --rm -v /work:/w alpine:3.20 sh -c "echo from-nested > /w/back.txt"' >/dev/null 2>&1
out=$(dcsh "$NAME" 'cat /work/back.txt' 2>/dev/null | tr -d '\r')
[ "$out" = "from-nested" ] && pass "$NAME: devcontainer sees nested container's workspace write (=$out)" \
  || { fail "$NAME: round-trip write not visible ($out)"; rc=1; }

# Negative control: a devcontainer-LOCAL path (not shared) is a known limitation —
# it mounts empty in the nested container. Assert the documented behaviour so we
# notice if it ever changes.
dcsh "$NAME" 'mkdir -p /home/dev/local && echo secret > /home/dev/local/x.txt'
out=$(dcsh "$NAME" 'docker run --rm -v /home/dev/local:/l alpine:3.20 sh -c "cat /l/x.txt 2>/dev/null || echo EMPTY"' 2>/dev/null | tr -d '\r')
[ "$out" = "EMPTY" ] && pass "$NAME: non-shared devcontainer path mounts empty in nested (documented limitation)" \
  || log "$NAME: note — non-shared path returned '$out' (behaviour changed?)"

down "$NAME"
exit $rc
