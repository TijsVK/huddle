#!/usr/bin/env bash
# docker compose with a build: context from the workspace. The private daemon
# reads the Dockerfile + context from its own fs, so this only works because the
# workspace is shared into the sidecar (the gateway mounts it; harness shares
# /work). Proves build-context files reach the daemon and the built image serves.
source "$(dirname "$0")/../lib.sh"
NAME=cbuild
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'mkdir -p /work/app && printf "HUDDLE_BUILT_PAGE" > /work/app/index.html && cat > /work/app/Dockerfile' <<'DOCKER'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
DOCKER
dcsh "$NAME" 'cat > /work/app/compose.yaml' <<'YAML'
services:
  web:
    build: .
    ports: ["8085:80"]
YAML

if dcsh "$NAME" 'cd /work/app && docker compose up -d --build' >/tmp/cbuild.log 2>&1; then
  pass "$NAME: compose up --build (build context from workspace)"
else fail "$NAME: compose up --build"; tail -6 /tmp/cbuild.log >&2; rc=1; fi

body=$(dcsh "$NAME" 'curl -s -m 10 http://localhost:8085' 2>/dev/null | tr -d '\r')
[ "$body" = "HUDDLE_BUILT_PAGE" ] && pass "$NAME: built image serves workspace file (=$body)" || { fail "$NAME: served body '$body'"; rc=1; }

dcsh "$NAME" 'cd /work/app && docker compose down -v' >/dev/null 2>&1
down "$NAME"
exit $rc
