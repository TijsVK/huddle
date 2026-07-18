#!/usr/bin/env bash
# k3d (k3s-in-Docker) builds its nodes as --privileged containers. The C1
# host-escape filter refuses --privileged, so k3d is a DOCUMENTED LIMITATION in
# DinD mode. This test asserts the refusal is clean (k3d reports the denial).
source "$(dirname "$0")/../lib.sh"
NAME=k3d
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

out=$(dcsh "$NAME" "k3d cluster create c1 --wait --timeout 30s --no-lb 2>&1"; dcsh "$NAME" "k3d cluster delete c1 >/dev/null 2>&1")
if printf '%s' "$out" | grep -q "not permitted"; then
  pass "$NAME: k3d node (privileged) refused by filter (documented limitation)"
else
  fail "$NAME: expected a privileged-refused error from k3d"; printf '%s\n' "$out" | tail -6 >&2; rc=1
fi

down "$NAME"
exit $rc
