#!/usr/bin/env bash
# Helm's app workflow needs a Kubernetes cluster, and the only in-DinD way to get
# one (k3d/kind) requires --privileged node containers — refused by the C1 filter.
# So the helm-on-k3d workflow is a DOCUMENTED LIMITATION in DinD mode. This test
# confirms the helm binary itself works and that the k3d cluster is cleanly
# refused (privileged). Chart templating (no cluster) still works.
source "$(dirname "$0")/../lib.sh"
NAME=helm
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'command -v helm >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/tmp/helm-install.log 2>&1' \
  && pass "$NAME: helm installed ($(dcsh "$NAME" 'helm version --short' 2>/dev/null | tr -d '\r'))" || { fail "$NAME: helm install"; down "$NAME"; exit 1; }

# Chart scaffold + template (client-only, no cluster) works.
tmpl=$(dcsh "$NAME" 'cd /home/dev && helm create demo >/dev/null 2>&1 && helm template demo ./demo 2>&1' | tr -d '\r')
assert_contains "$tmpl" "kind: Deployment" "$NAME: helm template renders (client-side workflow works)" || rc=1

# A privileged-node cluster (k3d) is refused by the filter — documented limitation.
out=$(dcsh "$NAME" "k3d cluster create h1 --wait --timeout 30s --no-lb 2>&1"; dcsh "$NAME" "k3d cluster delete h1 >/dev/null 2>&1")
if printf '%s' "$out" | grep -q "not permitted"; then
  pass "$NAME: k3d cluster (privileged) refused by filter (documented limitation)"
else
  fail "$NAME: expected a privileged-refused error from k3d"; printf '%s\n' "$out" | tail -6 >&2; rc=1
fi

down "$NAME"
exit $rc
