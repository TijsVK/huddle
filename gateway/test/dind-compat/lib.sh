#!/usr/bin/env bash
# Shared helpers for the DinD tool-compatibility harness.
#
# Replicates Huddle's Design-N topology on a bare host daemon:
#   devcontainer  (holds the network namespace; DOCKER_HOST -> shared socket)
#   dind sidecar  (docker:dind, --privileged, --network container:<devcontainer>)
# so each tool is driven against a REAL private daemon exactly as it would be
# inside Huddle-with-HUDDLE_DIND, without needing the full gateway/IDE stack.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIND_IMAGE="${DIND_IMAGE:-docker:28-dind}"
TESTDC_IMAGE="${TESTDC_IMAGE:-huddle-dind-test-dc:latest}"
PREFIX="dindc"

log()  { printf '\033[36m[harness]\033[0m %s\n' "$*" >&2; }
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; }

build_testdc() {
  if docker image inspect "$TESTDC_IMAGE" >/dev/null 2>&1; then return 0; fi
  log "building test devcontainer image $TESTDC_IMAGE (first run only)"
  docker build -t "$TESTDC_IMAGE" -f "$HERE/Dockerfile.testdc" "$HERE" >&2
}

# up <name> [network]  — start devcontainer + netns-sharing dind sidecar, WITH the
# real host-escape filter in front (mirrors the gateway: devcontainer -> filter
# docker.sock -> sidecar inner.sock). This makes the harness faithful — a
# --privileged/--device/socket-bind nested container is refused exactly as it is
# in the shipped product, not passed straight to raw dockerd.
up() {
  local name="$1"; local net="${2:-bridge}"
  local dc="${PREFIX}-${name}" dind="${PREFIX}-${name}-dind"
  local data="${PREFIX}-${name}-data" work="${PREFIX}-${name}-work"
  local sockdir="/tmp/dindc-sock/${name}"
  # Authz model (mirrors the gateway): dockerd runs with
  # --authorization-plugin=huddle-authz and listens on its OWN docker.sock; the
  # host serves the plugin socket that dockerd calls before every request. No
  # unfiltered socket exists, so there is nothing to bypass.
  #   outer/  → sidecar (dockerd docker.sock) + devcontainer
  #   plugin/ → host (authz-runner) + sidecar (at /run/docker/plugins)
  local outerdir="$sockdir/outer" plugindir="$sockdir/plugin"
  docker rm -f "$dc" "$dind" >/dev/null 2>&1 || true
  docker volume rm "$data" "$work" >/dev/null 2>&1 || true
  [ -f "$sockdir/authz.pid" ] && kill "$(cat "$sockdir/authz.pid")" 2>/dev/null || true
  rm -rf "$sockdir"; mkdir -p "$outerdir" "$plugindir"; chmod 0777 "$sockdir" "$outerdir" "$plugindir"
  docker volume create "$data" >/dev/null
  docker volume create "$work" >/dev/null
  # Start the authz plugin on the host BEFORE dockerd, so the socket is present
  # when dockerd loads the plugin (dockerd fails requests closed otherwise).
  node "$HERE/authz-runner.mjs" "$name" "$plugindir/huddle-authz.sock" >"$sockdir/authz.log" 2>&1 &
  echo $! > "$sockdir/authz.pid"
  for i in $(seq 1 40); do [ -S "$plugindir/huddle-authz.sock" ] && break; sleep 0.25; done
  # /work is a workspace volume shared by BOTH devcontainer and sidecar at the same
  # path (bind-mounting workspace paths into nested containers sees real files).
  # The devcontainer mounts outer/ (dockerd's authz-guarded docker.sock).
  docker run -d --name "$dc" --network "$net" \
    -v "$outerdir":/var/run/dind -v "$work":/work \
    -e DOCKER_HOST=unix:///var/run/dind/docker.sock \
    --cap-add NET_ADMIN \
    "$TESTDC_IMAGE" sleep infinity >/dev/null || { fail "$name: devcontainer failed to start"; return 1; }
  # Sidecar: dockerd on outer/docker.sock with the authz plugin (plugin/ mounted
  # at dockerd's discovery path /run/docker/plugins).
  docker run -d --name "$dind" --privileged \
    --network "container:${dc}" \
    -v "$outerdir":/var/run/dind -v "$plugindir":/run/docker/plugins -v "$data":/var/lib/docker -v "$work":/work \
    -e DOCKER_TLS_CERTDIR= \
    "$DIND_IMAGE" sh -c 'if [ -f /sys/fs/cgroup/cgroup.controllers ]; then mkdir -p /sys/fs/cgroup/init 2>/dev/null||true; xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null||true; sed -e "s/ / +/g" -e "s/^/+/" < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null||true; fi; dockerd --host=unix:///var/run/dind/docker.sock --authorization-plugin=huddle-authz --mtu=1400 & DPID=$!; i=0; while [ ! -S /var/run/dind/docker.sock ] && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done; chmod 0666 /var/run/dind/docker.sock 2>/dev/null || true; wait $DPID' >/dev/null \
    || { fail "$name: dind sidecar failed to start"; return 1; }
  local i
  for i in $(seq 1 90); do
    docker exec "$dc" docker version >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "$name: dind daemon did not become ready"; cat "$sockdir/authz.log" >&2 2>/dev/null; return 1
}

# dcsh <name> "<script>" — run a shell script inside the devcontainer.
# -i so callers can feed a heredoc/pipe on stdin (e.g. writing config files).
dcsh() { docker exec -i "${PREFIX}-$1" bash -lc "$2"; }
# dcshu <name> <user> "<script>"
dcshu() { docker exec -i -u "$2" "${PREFIX}-$1" bash -lc "$3"; }

down() {
  local name="$1"; local sockdir="/tmp/dindc-sock/${name}"
  [ -f "$sockdir/authz.pid" ] && kill "$(cat "$sockdir/authz.pid")" 2>/dev/null || true
  docker rm -f "${PREFIX}-${name}" "${PREFIX}-${name}-dind" >/dev/null 2>&1 || true
  docker volume rm "${PREFIX}-${name}-data" "${PREFIX}-${name}-work" >/dev/null 2>&1 || true
  rm -rf "$sockdir"
}

# assert_contains <haystack> <needle> <label>
assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; return 0
  else fail "$3 (missing: '$2')"; return 1; fi
}
