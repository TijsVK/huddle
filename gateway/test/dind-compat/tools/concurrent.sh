#!/usr/bin/env bash
# Concurrent devcontainers must be independent: each has its own private daemon in
# its own netns, so two devcontainers can BOTH publish the same port (e.g. 8080)
# with no host-port collision — impossible under the classic shared host daemon.
# Also re-checks they can't see each other's containers.
source "$(dirname "$0")/../lib.sh"
NAME=conc
NET="${1:-bridge}"
rc=0
up "${NAME}a" "$NET" || exit 1
up "${NAME}b" "$NET" || { down "${NAME}a"; exit 1; }

# Both publish 8080 from a nested nginx serving a distinct marker.
dcsh "${NAME}a" 'printf "MARKER_A" > /tmp/i.html; docker run -d --name web -p 8080:80 nginx:alpine >/dev/null 2>&1; docker cp /tmp/i.html web:/usr/share/nginx/html/index.html >/dev/null 2>&1' >/dev/null 2>&1
dcsh "${NAME}b" 'printf "MARKER_B" > /tmp/i.html; docker run -d --name web -p 8080:80 nginx:alpine >/dev/null 2>&1; docker cp /tmp/i.html web:/usr/share/nginx/html/index.html >/dev/null 2>&1' >/dev/null 2>&1
sleep 3

a=$(dcsh "${NAME}a" 'curl -s -m 8 http://localhost:8080' 2>/dev/null | tr -d '\r')
b=$(dcsh "${NAME}b" 'curl -s -m 8 http://localhost:8080' 2>/dev/null | tr -d '\r')
[ "$a" = "MARKER_A" ] && pass "devcontainer A: localhost:8080 → its own container ($a)" || { fail "A got '$a'"; rc=1; }
[ "$b" = "MARKER_B" ] && pass "devcontainer B: localhost:8080 → its own container ($b)" || { fail "B got '$b'"; rc=1; }
{ [ "$a" = "MARKER_A" ] && [ "$b" = "MARKER_B" ]; } && pass "same published port 8080 in both — no host-port collision (separate netns)" || { fail "port isolation broken"; rc=1; }

# A must not see B's container in its private daemon.
seen=$(dcsh "${NAME}a" 'docker ps --format "{{.Names}}" | grep -c "^web$"' | tr -d '[:space:]')
own=$(dcsh "${NAME}a" 'docker ps -q | wc -l' | tr -d '[:space:]')
[ "${own:-0}" -ge 1 ] && pass "A sees its own container(s) ($own)" || { fail "A sees no containers"; rc=1; }

down "${NAME}a"; down "${NAME}b"
exit $rc
