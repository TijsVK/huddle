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

# up <name> [network]  — start devcontainer + netns-sharing dind sidecar.
up() {
  local name="$1"; local net="${2:-bridge}"
  local dc="${PREFIX}-${name}" dind="${PREFIX}-${name}-dind"
  local sock="${PREFIX}-${name}-sock" data="${PREFIX}-${name}-data" work="${PREFIX}-${name}-work"
  docker rm -f "$dc" "$dind" >/dev/null 2>&1 || true
  docker volume rm "$sock" "$data" "$work" >/dev/null 2>&1 || true
  docker volume create "$sock" >/dev/null
  docker volume create "$data" >/dev/null
  docker volume create "$work" >/dev/null
  # /work is a workspace volume shared by BOTH devcontainer and sidecar at the
  # same path — exactly what the gateway now does with the real workspace so that
  # bind-mounting workspace paths into nested containers sees real files.
  docker run -d --name "$dc" --network "$net" \
    -v "$sock":/var/run/dind -v "$work":/work \
    -e DOCKER_HOST=unix:///var/run/dind/docker.sock \
    --cap-add NET_ADMIN \
    "$TESTDC_IMAGE" sleep infinity >/dev/null || { fail "$name: devcontainer failed to start"; return 1; }
  docker run -d --name "$dind" --privileged \
    --network "container:${dc}" \
    -v "$sock":/var/run/dind -v "$data":/var/lib/docker -v "$work":/work \
    -e DOCKER_TLS_CERTDIR= \
    "$DIND_IMAGE" dockerd --host=unix:///var/run/dind/docker.sock --mtu=1400 >/dev/null \
    || { fail "$name: dind sidecar failed to start"; return 1; }
  local i
  for i in $(seq 1 90); do
    docker exec "$dc" docker version >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "$name: dind daemon did not become ready"; return 1
}

# dcsh <name> "<script>" — run a shell script inside the devcontainer.
# -i so callers can feed a heredoc/pipe on stdin (e.g. writing config files).
dcsh() { docker exec -i "${PREFIX}-$1" bash -lc "$2"; }
# dcshu <name> <user> "<script>"
dcshu() { docker exec -i -u "$2" "${PREFIX}-$1" bash -lc "$3"; }

down() {
  local name="$1"
  docker rm -f "${PREFIX}-${name}" "${PREFIX}-${name}-dind" >/dev/null 2>&1 || true
  docker volume rm "${PREFIX}-${name}-sock" "${PREFIX}-${name}-data" "${PREFIX}-${name}-work" >/dev/null 2>&1 || true
}

# assert_contains <haystack> <needle> <label>
assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; return 0
  else fail "$3 (missing: '$2')"; return 1; fi
}
