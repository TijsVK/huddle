#!/usr/bin/env bash
# kind: Kubernetes with full kubeadm nodes as privileged containers running
# systemd — a heavier cgroup/systemd-in-container stress than k3d. Also exercises
# `kind load docker-image` (sideloading a locally-built image into the cluster).
source "$(dirname "$0")/../lib.sh"
NAME=kind
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

if dcsh "$NAME" 'kind create cluster --name k1 --wait 180s' >/tmp/kind.log 2>&1; then
  pass "$NAME: kind cluster create (kubeadm node + systemd)"
else fail "$NAME: kind cluster create"; tail -8 /tmp/kind.log >&2; down "$NAME"; exit 1; fi

nodes=$(dcsh "$NAME" 'kubectl --context kind-k1 get nodes --no-headers 2>/dev/null | grep -c " Ready "' | tr -d '[:space:]')
[ "${nodes:-0}" -ge 1 ] && pass "$NAME: node Ready ($nodes)" || { fail "$NAME: no Ready node"; rc=1; }

# Build a local image and sideload it into the cluster (kind load).
dcsh "$NAME" 'mkdir -p /work/ki && printf "FROM nginx:alpine\nRUN echo KIND_IMG > /usr/share/nginx/html/index.html\n" > /work/ki/Dockerfile && cd /work/ki && docker build -t kind-demo:v1 . >/dev/null 2>&1'
if dcsh "$NAME" 'kind load docker-image kind-demo:v1 --name k1' >/tmp/kindload.log 2>&1; then
  pass "$NAME: kind load docker-image (sideload local image)"
else fail "$NAME: kind load docker-image"; tail -5 /tmp/kindload.log >&2; rc=1; fi

dcsh "$NAME" 'kubectl --context kind-k1 run web --image=kind-demo:v1 --image-pull-policy=Never >/dev/null 2>&1; kubectl --context kind-k1 wait --for=condition=Ready pod/web --timeout=120s' >/tmp/kindpod.log 2>&1 \
  && pass "$NAME: pod from sideloaded image Ready" || { fail "$NAME: pod not Ready"; tail -4 /tmp/kindpod.log >&2; rc=1; }

dcsh "$NAME" 'kind delete cluster --name k1 >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
