#!/usr/bin/env bash
# docker build (BuildKit) + buildx: multi-stage build then run the result.
source "$(dirname "$0")/../lib.sh"
NAME=buildx
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'mkdir -p /home/dev/b && cat > /home/dev/b/Dockerfile' <<'DOCKER'
FROM alpine:3.20 AS build
RUN echo "hello-from-buildkit" > /msg
FROM alpine:3.20
COPY --from=build /msg /msg
CMD ["cat", "/msg"]
DOCKER

if dcsh "$NAME" 'cd /home/dev/b && DOCKER_BUILDKIT=1 docker build -t demo:bk .' >/tmp/bk.log 2>&1; then
  pass "$NAME: BuildKit multi-stage build"
else fail "$NAME: BuildKit build"; rc=1; fi

out=$(dcsh "$NAME" 'docker run --rm demo:bk' 2>/dev/null | tr -d "\r")
[ "$out" = "hello-from-buildkit" ] && pass "$NAME: run built image -> '$out'" || { fail "$NAME: run built image ($out)"; rc=1; }

if dcsh "$NAME" 'cd /home/dev/b && docker buildx build --load -t demo:bx .' >/tmp/bx.log 2>&1; then
  pass "$NAME: buildx build --load"
else fail "$NAME: buildx build --load"; rc=1; fi

down "$NAME"
exit $rc
