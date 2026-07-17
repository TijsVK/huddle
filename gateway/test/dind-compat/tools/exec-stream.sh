#!/usr/bin/env bash
# exec + logs streaming against the private daemon — the mechanics behind the
# Huddle portal terminal and log views, and `docker exec`-based tooling.
source "$(dirname "$0")/../lib.sh"
NAME=execstream
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'docker run -d --name box alpine:3.20 sh -c "i=0; while true; do echo line-\$i; i=\$((i+1)); sleep 1; done" >/dev/null 2>&1' >/dev/null 2>&1
sleep 2

# exec with captured output
out=$(dcsh "$NAME" 'docker exec box echo EXEC_OK' 2>/dev/null | tr -d '\r')
assert_contains "$out" "EXEC_OK" "$NAME: docker exec (command output)" || rc=1

# exec with stdin piped through
out=$(dcsh "$NAME" 'echo PIPED_IN | docker exec -i box cat' 2>/dev/null | tr -d '\r')
assert_contains "$out" "PIPED_IN" "$NAME: docker exec -i (stdin round-trip)" || rc=1

# exec with a TTY (portal terminal path)
out=$(dcsh "$NAME" 'docker exec -t box sh -c "echo TTY_OK" 2>/dev/null' | tr -d '\r')
assert_contains "$out" "TTY_OK" "$NAME: docker exec -t (TTY allocated)" || rc=1

# logs follow: capture a few streamed lines then stop
out=$(dcsh "$NAME" 'timeout 4 docker logs -f box 2>/dev/null | head -3' | tr -d '\r')
assert_contains "$out" "line-" "$NAME: docker logs -f (streaming)" || rc=1

dcsh "$NAME" 'docker rm -f box >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
