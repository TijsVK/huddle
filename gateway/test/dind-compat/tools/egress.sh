#!/usr/bin/env bash
# Tier-2: the REAL Huddle constraint. Devcontainer sits on an --internal network
# with NO direct route out; the only egress is a forward proxy ("huddle"). The
# dind sidecar shares that firewalled netns. This proves tools stay fully
# functional when all egress is proxied — and pins the Aspire #12 regression
# (DCP loopback must NOT be proxied) and the egress guarantee (no proxy = no net).
source "$(dirname "$0")/../lib.sh"
NAME=egress
rc=0
INT=eg-int
PROXY=huddle-proxy
PXY=http://huddle:3128
NOPROXY='localhost,127.0.0.1,::1,[::1],huddle'
sock="${PREFIX}-${NAME}-sock"; data="${PREFIX}-${NAME}-data"
dc="${PREFIX}-${NAME}"; dind="${PREFIX}-${NAME}-dind"

cleanup() {
  docker rm -f "$dc" "$dind" "$PROXY" >/dev/null 2>&1 || true
  docker volume rm "$sock" "$data" >/dev/null 2>&1 || true
  docker network rm "$INT" >/dev/null 2>&1 || true
}
cleanup

# ── huddle stand-in: squid on the internal net (alias huddle) + bridge (internet)
docker network create --internal "$INT" >/dev/null
docker run -d --name "$PROXY" --network bridge \
  -v "$HERE/squid.conf":/etc/squid/squid.conf:ro ubuntu/squid:latest >/dev/null 2>&1 \
  || { fail "$NAME: squid proxy failed to start"; cleanup; exit 1; }
docker network connect --alias huddle "$INT" "$PROXY" >/dev/null 2>&1
sleep 3

# ── devcontainer on the INTERNAL net only, all egress via the proxy ──────────
docker volume create "$sock" >/dev/null; docker volume create "$data" >/dev/null
docker run -d --name "$dc" --network "$INT" \
  -v "$sock":/var/run/dind -e DOCKER_HOST=unix:///var/run/dind/docker.sock \
  --cap-add NET_ADMIN \
  -e HTTP_PROXY="$PXY" -e HTTPS_PROXY="$PXY" -e http_proxy="$PXY" -e https_proxy="$PXY" \
  -e NO_PROXY="$NOPROXY" -e no_proxy="$NOPROXY" \
  "$TESTDC_IMAGE" sleep infinity >/dev/null
docker run -d --name "$dind" --privileged --network "container:${dc}" \
  -v "$sock":/var/run/dind -v "$data":/var/lib/docker -e DOCKER_TLS_CERTDIR= \
  -e HTTP_PROXY="$PXY" -e HTTPS_PROXY="$PXY" -e http_proxy="$PXY" -e https_proxy="$PXY" \
  -e NO_PROXY="$NOPROXY" -e no_proxy="$NOPROXY" \
  "$DIND_IMAGE" dockerd --host=unix:///var/run/dind/docker.sock --mtu=1400 >/dev/null
for i in $(seq 1 90); do docker exec "$dc" docker version >/dev/null 2>&1 && break; sleep 1; done
docker exec "$dc" docker version >/dev/null 2>&1 || { fail "$NAME: dind daemon never ready on internal net"; cleanup; exit 1; }

# Nested containers inherit proxy env via the DEVCONTAINER's docker client-config
# (proxies.default) — exactly as docker.ts's dindClientProxyConfig does. A nested
# container cannot resolve the name `huddle` (separate daemon network), so the
# config uses the RESOLVED proxy IP, not the name.
HIP=$(docker exec "$dc" getent hosts huddle | awk '{print $1}')
docker exec -i "$dc" sh -c 'mkdir -p /root/.docker && cat > /root/.docker/config.json' <<JSON
{"proxies":{"default":{"httpProxy":"http://$HIP:3128","httpsProxy":"http://$HIP:3128","noProxy":"localhost,127.0.0.1,::1,[::1]"}}}
JSON

# 1. No direct internet (egress guarantee): bypassing the proxy must FAIL.
if dcsh "$NAME" "curl --noproxy '*' -s -m 8 -o /dev/null https://example.com" >/dev/null 2>&1; then
  fail "$NAME: EGRESS LEAK — direct internet reachable without proxy"; rc=1
else pass "$NAME: direct internet blocked (no route without proxy)"; fi

# 2. Proxied internet works (devcontainer's own traffic).
code=$(dcsh "$NAME" "curl -s -o /dev/null -w '%{http_code}' -m 20 https://example.com" 2>/dev/null)
[ "$code" = "200" ] && pass "$NAME: proxied HTTPS from devcontainer (=$code)" || { fail "$NAME: proxied HTTPS ($code)"; rc=1; }

# 3. dockerd image pull through the proxy (no direct registry route).
if dcsh "$NAME" 'docker pull -q nginx:alpine' >/tmp/eg-pull.log 2>&1; then
  pass "$NAME: image pull through proxy (dockerd honours HTTPS_PROXY)"
else fail "$NAME: image pull through proxy"; tail -3 /tmp/eg-pull.log >&2; rc=1; fi

# 4. Nested container reaches internet ONLY via injected proxy env (from the
#    daemon client-config, as dind.ts does). curl honours the injected HTTPS_PROXY
#    and does CONNECT (busybox wget can't tunnel TLS, so it's not a valid probe).
code=$(dcsh "$NAME" "docker run --rm curlimages/curl:latest -s -o /dev/null -w '%{http_code}' -m 25 https://example.com" 2>/dev/null | tr -d '\r')
[ "$code" = "200" ] && pass "$NAME: nested container egress via injected proxy (=$code)" || { fail "$NAME: nested egress via injected proxy ($code)"; rc=1; }
# And confirm a nested container has NO direct (non-proxied) route out.
if dcsh "$NAME" "docker run --rm curlimages/curl:latest --noproxy '*' -s -m 8 -o /dev/null https://example.com" >/dev/null 2>&1; then
  fail "$NAME: EGRESS LEAK — nested container reached internet without proxy"; rc=1
else pass "$NAME: nested container has no direct route (proxy-only egress)"; fi

# 5. Aspire #12 fix: loopback must NOT be proxied. Publish a port, hit it on
#    localhost and [::1] — a proxied loopback would 403/timeout at the proxy.
dcsh "$NAME" 'docker run -d --name lb -p 8080:80 nginx:alpine >/dev/null 2>&1'
sleep 2
c4=$(dcsh "$NAME" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080" 2>/dev/null)
c6=$(dcsh "$NAME" "curl -s -o /dev/null -w '%{http_code}' 'http://[::1]:8080'" 2>/dev/null)
[ "$c4" = "200" ] && pass "$NAME: loopback localhost:8080 not proxied (=$c4)" || { fail "$NAME: loopback localhost ($c4)"; rc=1; }
[ "$c6" = "200" ] && pass "$NAME: loopback [::1]:8080 not proxied (=$c6, Aspire DCP path)" || { fail "$NAME: loopback [::1] ($c6)"; rc=1; }
dcsh "$NAME" 'docker rm -f lb >/dev/null 2>&1'

cleanup
exit $rc
