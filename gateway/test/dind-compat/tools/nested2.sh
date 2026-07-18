#!/usr/bin/env bash
# Docker-in-Docker-in-Docker (nested²): a second dind INSIDE the private daemon
# needs a --privileged container. Since the C1 host-escape filter refuses
# --privileged, nested² is a DOCUMENTED LIMITATION in DinD mode. This test asserts
# the refusal is clean (not a crash) and that ordinary single-level nesting still
# works.
source "$(dirname "$0")/../lib.sh"
NAME=nested2
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'docker pull -q docker:28-dind >/dev/null 2>&1' >/dev/null 2>&1

# A level-2 dind (privileged) must be REFUSED by the filter.
out=$(dcsh "$NAME" 'docker run -d --name l2 --privileged docker:28-dind true 2>&1' | tr -d '\r')
assert_contains "$out" "not permitted" "$NAME: level-2 privileged dind refused (documented limitation)" || rc=1

# Single-level nesting (the supported case) still works.
dcsh "$NAME" 'docker pull -q alpine:3.20 >/dev/null 2>&1' >/dev/null 2>&1
out=$(dcsh "$NAME" 'docker run --rm alpine:3.20 echo L2_OK 2>&1' | tr -d '\r')
assert_contains "$out" "L2_OK" "$NAME: single-level nested container still runs" || rc=1

dcsh "$NAME" 'docker rm -f l2 >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
