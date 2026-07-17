#!/usr/bin/env bash
# @devcontainers/cli — builds and starts a dev container from a devcontainer.json
# (docker build + run + inspect + exec). Directly in Huddle's domain, so a strong
# signal that nested devcontainer workflows work against the private daemon.
source "$(dirname "$0")/../lib.sh"
NAME=devc
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

if ! dcsh "$NAME" 'npm i -g @devcontainers/cli >/tmp/devc-install.log 2>&1'; then
  fail "$NAME: @devcontainers/cli install"; down "$NAME"; exit 1
fi
pass "$NAME: devcontainers/cli installed ($(dcsh "$NAME" 'devcontainer --version' 2>/dev/null | tr -d '\r'))"

# Project lives on the SHARED /work volume so the bind source resolves to real
# files in the private daemon's fs (the gateway does the same with the workspace).
dcsh "$NAME" 'mkdir -p /work/wp/.devcontainer && echo "hello-workspace" > /work/wp/marker.txt && cat > /work/wp/.devcontainer/devcontainer.json' <<'JSON'
{
  "name": "compat",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "overrideCommand": true
}
JSON

if dcsh "$NAME" 'cd /work/wp && devcontainer up --workspace-folder .' >/tmp/devc-up.log 2>&1; then
  pass "$NAME: devcontainer up (build + start)"
else fail "$NAME: devcontainer up"; tail -5 /tmp/devc-up.log >&2; rc=1; fi

out=$(dcsh "$NAME" 'cd /work/wp && devcontainer exec --workspace-folder . bash -lc "echo DEVC_EXEC_OK && cat marker.txt"' 2>/dev/null | tr -d '\r')
assert_contains "$out" "hello-workspace" "$NAME: workspace files visible inside nested devcontainer (shared /work)" || rc=1
assert_contains "$out" "DEVC_EXEC_OK" "$NAME: devcontainer exec into running container" || rc=1

# Cleanup the nested devcontainer.
dcsh "$NAME" 'docker ps -aq --filter label=devcontainer.local_folder | xargs -r docker rm -f >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
