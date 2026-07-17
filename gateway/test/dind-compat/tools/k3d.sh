#!/usr/bin/env bash
# k3d (k3s-in-Docker): a full Kubernetes cluster built from containers via the
# Docker socket, with the API server + a service published back onto localhost.
# Deeply exercises container create, networks, inspect, and port publishing.
source "$(dirname "$0")/../lib.sh"
NAME=k3d
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

export_kube='export KUBECONFIG=/home/dev/kcfg'

if dcsh "$NAME" "k3d cluster create c1 --wait --timeout 180s --no-lb --k3s-arg '--disable=traefik@server:0' --kubeconfig-update-default=false --kubeconfig-switch-context=false" >/tmp/k3d.log 2>&1; then
  pass "$NAME: k3d cluster create"
else fail "$NAME: k3d cluster create (see log)"; tail -5 /tmp/k3d.log >&2; rc=1; down "$NAME"; exit 1; fi

dcsh "$NAME" "k3d kubeconfig get c1 > /home/dev/kcfg 2>/dev/null"

nodes=$(dcsh "$NAME" "$export_kube; kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready '" | tr -d "[:space:]")
[ "${nodes:-0}" -ge 1 ] && pass "$NAME: $nodes node(s) Ready" || { fail "$NAME: no Ready nodes"; rc=1; }

# Deploy something and confirm it reaches Running (scheduler + kubelet + image pull).
dcsh "$NAME" "$export_kube; kubectl create deployment web --image=nginx:alpine >/dev/null 2>&1; kubectl rollout status deployment/web --timeout=120s" >/tmp/k3drollout.log 2>&1 \
  && pass "$NAME: deployment rollout complete" || { fail "$NAME: deployment rollout"; rc=1; }

running=$(dcsh "$NAME" "$export_kube; kubectl get pods -l app=web --no-headers 2>/dev/null | grep -c Running" | tr -d "[:space:]")
[ "${running:-0}" -ge 1 ] && pass "$NAME: nginx pod Running" || { fail "$NAME: pod not Running"; rc=1; }

dcsh "$NAME" "k3d cluster delete c1 >/dev/null 2>&1" >/dev/null 2>&1
down "$NAME"
exit $rc
