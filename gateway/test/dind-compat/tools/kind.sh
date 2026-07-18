#!/usr/bin/env bash
# kind runs Kubernetes nodes as --privileged containers (kubeadm + systemd). The
# C1 host-escape filter refuses --privileged, so kind is a DOCUMENTED LIMITATION
# in DinD mode. This test asserts the refusal is clean (kind reports the denial,
# not a hang/crash).
source "$(dirname "$0")/../lib.sh"
NAME=kind
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

out=$(dcsh "$NAME" 'kind create cluster --name k1 --wait 30s 2>&1'; dcsh "$NAME" 'kind delete cluster --name k1 >/dev/null 2>&1')
if printf '%s' "$out" | grep -q "not permitted"; then
  pass "$NAME: kind node (privileged) refused by filter (documented limitation)"
else
  fail "$NAME: expected a privileged-refused error from kind"; printf '%s\n' "$out" | tail -6 >&2; rc=1
fi

down "$NAME"
exit $rc
