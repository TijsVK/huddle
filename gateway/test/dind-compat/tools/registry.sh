#!/usr/bin/env bash
# Local registry push/pull. In the classic socket-proxy model image push was
# restricted; against the private daemon a full build -> push -> pull -> run
# round-trip to a local registry:2 works unrestricted.
source "$(dirname "$0")/../lib.sh"
NAME=reg
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'docker run -d --name reg -p 5000:5000 registry:2 >/dev/null 2>&1' >/dev/null 2>&1
ok=""; for i in $(seq 1 30); do dcsh "$NAME" 'curl -sf http://localhost:5000/v2/ >/dev/null 2>&1' && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] && pass "$NAME: local registry:2 up on localhost:5000" || { fail "$NAME: registry never ready"; down "$NAME"; exit 1; }

dcsh "$NAME" 'mkdir -p /work/img && printf "FROM alpine:3.20\nRUN echo HUDDLE_REG_IMG > /marker\nCMD [\"cat\",\"/marker\"]\n" > /work/img/Dockerfile'
dcsh "$NAME" 'cd /work/img && docker build -t localhost:5000/demo:v1 .' >/tmp/regbuild.log 2>&1 \
  && pass "$NAME: build image" || { fail "$NAME: build"; tail -4 /tmp/regbuild.log >&2; rc=1; }

dcsh "$NAME" 'docker push localhost:5000/demo:v1' >/tmp/regpush.log 2>&1 \
  && pass "$NAME: push to local registry" || { fail "$NAME: push"; tail -4 /tmp/regpush.log >&2; rc=1; }

# Remove local image + pull it back to prove the registry round-trip.
dcsh "$NAME" 'docker rmi localhost:5000/demo:v1 >/dev/null 2>&1'
dcsh "$NAME" 'docker pull -q localhost:5000/demo:v1' >/tmp/regpull.log 2>&1 \
  && pass "$NAME: pull from local registry" || { fail "$NAME: pull"; tail -4 /tmp/regpull.log >&2; rc=1; }

out=$(dcsh "$NAME" 'docker run --rm localhost:5000/demo:v1' 2>/dev/null | tr -d '\r')
[ "$out" = "HUDDLE_REG_IMG" ] && pass "$NAME: run pulled image (=$out)" || { fail "$NAME: run pulled ($out)"; rc=1; }

dcsh "$NAME" 'docker rm -f reg >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
