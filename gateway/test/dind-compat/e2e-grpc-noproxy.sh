#!/usr/bin/env bash
# Red test for the Aspire-dashboard gRPC bug: `host.docker.internal` (the standard
# "reach the host from a container" address, which Aspire uses for container OTLP/
# gRPC endpoints) must be in no_proxy. Otherwise .NET routes the gRPC (h2c) call
# through Huddle's HTTP/1 egress proxy and it fails with gRPC errors. Verified
# manually via HttpClient.DefaultProxy.IsBypassed: localhost/[::1] bypass, but
# host.docker.internal did NOT — it went to http://huddle/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3993; DC=e2e-grpc; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-sock-$DC" "huddle-dind-data-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/grpc-init.log 2>&1 && pass "gateway init (DinD)" || { fail init; cat /tmp/grpc-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done

# 1. devcontainer's own no_proxy must include host.docker.internal
np=$(docker exec "$DC" printenv no_proxy 2>/dev/null; docker exec "$DC" printenv NO_PROXY 2>/dev/null)
printf '%s' "$np" | grep -q 'host.docker.internal' \
  && pass "devcontainer no_proxy includes host.docker.internal" \
  || { fail "devcontainer no_proxy MISSING host.docker.internal (gRPC to it would be proxied)"; rc=1; }

# 2. the nested-container injected proxy config must bypass host.docker.internal too
cfg=$(docker exec -u vscode "$DC" cat /home/vscode/.docker/config.json 2>/dev/null)
printf '%s' "$cfg" | grep -q 'host.docker.internal' \
  && pass "nested-container proxy config bypasses host.docker.internal" \
  || { fail "nested-container proxy config MISSING host.docker.internal"; rc=1; }

# 3. functional: .NET's proxy decision must bypass host.docker.internal (the exact
#    check that determines whether an Aspire gRPC channel is proxied).
docker exec -i -u vscode "$DC" bash -lc 'mkdir -p ~/pb && cat > ~/pb/P.csproj' <<'CSPROJ'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><Nullable>disable</Nullable></PropertyGroup></Project>
CSPROJ
docker exec -i -u vscode "$DC" bash -lc 'cat > ~/pb/Program.cs' <<'CS'
using System; using System.Net; using System.Net.Http;
var p = HttpClient.DefaultProxy;
Console.WriteLine("hdi_bypassed=" + p.IsBypassed(new Uri("http://host.docker.internal:34695")));
CS
probe=$(docker exec -u vscode "$DC" bash -lc 'export PATH=$HOME/.dotnet:$PATH DOTNET_ROOT=$HOME/.dotnet; cd ~/pb && dotnet run 2>/dev/null' | tr -d '\r')
printf '%s' "$probe" | grep -q 'hdi_bypassed=True' \
  && pass "(.NET) host.docker.internal is bypassed — gRPC channel goes direct, not via proxy" \
  || { fail "(.NET) host.docker.internal NOT bypassed ($probe) — Aspire gRPC to it is routed through Huddle → gRPC errors"; rc=1; }

exit $rc
