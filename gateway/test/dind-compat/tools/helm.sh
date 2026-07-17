#!/usr/bin/env bash
# Helm on k3d: the Kubernetes app-packaging workflow. Spin a k3d cluster, install
# a locally-scaffolded chart, and confirm the release deploys and the pod runs.
source "$(dirname "$0")/../lib.sh"
NAME=helm
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'command -v helm >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/tmp/helm-install.log 2>&1' \
  && pass "$NAME: helm installed ($(dcsh "$NAME" 'helm version --short' 2>/dev/null | tr -d '\r'))" || { fail "$NAME: helm install"; down "$NAME"; exit 1; }

if dcsh "$NAME" "k3d cluster create h1 --wait --timeout 180s --no-lb --k3s-arg '--disable=traefik@server:0' --kubeconfig-update-default=false --kubeconfig-switch-context=false" >/tmp/helm-k3d.log 2>&1; then
  pass "$NAME: k3d cluster up"
else fail "$NAME: k3d cluster create"; tail -4 /tmp/helm-k3d.log >&2; down "$NAME"; exit 1; fi
dcsh "$NAME" "k3d kubeconfig get h1 > /home/dev/kc 2>/dev/null"
KC='export KUBECONFIG=/home/dev/kc'

# Scaffold a chart (defaults to an nginx deployment) and install it.
dcsh "$NAME" 'cd /home/dev && helm create demo >/dev/null 2>&1'
if dcsh "$NAME" "$KC; cd /home/dev && helm install demo ./demo --wait --timeout 150s" >/tmp/helm-install2.log 2>&1; then
  pass "$NAME: helm install --wait (release deployed)"
else fail "$NAME: helm install"; tail -6 /tmp/helm-install2.log >&2; rc=1; fi

st=$(dcsh "$NAME" "$KC; helm status demo -o json 2>/dev/null" | tr -d '\r' | grep -o '"status":"deployed"' | head -1)
[ -n "$st" ] && pass "$NAME: helm release status=deployed" || { fail "$NAME: release not deployed"; rc=1; }
running=$(dcsh "$NAME" "$KC; kubectl get pods -l app.kubernetes.io/name=demo --no-headers 2>/dev/null | grep -c Running" | tr -d '[:space:]')
[ "${running:-0}" -ge 1 ] && pass "$NAME: chart pod Running" || { fail "$NAME: pod not Running"; rc=1; }

dcsh "$NAME" "k3d cluster delete h1 >/dev/null 2>&1" >/dev/null 2>&1
down "$NAME"
exit $rc
