#!/usr/bin/env bash
# FULL end-to-end: run the REAL Huddle gateway (via the CLI `init`) with
# HUDDLE_DIND=1, let it create a real devcontainer + private daemon through its
# own code, allowlist the egress the build needs, then run a .NET Aspire AppHost
# with SqlServer inside it (issues #12 + #61) and confirm the SQL container comes
# up through the private daemon.
#
# Requires locally-built images: huddle-local:dind (gateway) and
# huddle-e2e-base:latest (devcontainer base with dotnet). Run build steps first.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3999
DC=e2e-aspire
rc=0

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; }
log()  { printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }

cleanup() {
  log "cleanup"
  docker rm -f "$DC" "dind-$DC" >/dev/null 2>&1 || true
  docker volume rm "huddle-dind-sock-$DC" "huddle-dind-data-$DC" >/dev/null 2>&1 || true
  docker rm -f huddle >/dev/null 2>&1 || true
  docker network rm "dc-net-$DC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
# Fresh data volume so no stale grants/rules leak in.
docker volume rm huddle-data >/dev/null 2>&1 || true

# ── 1. run the real gateway via the CLI ──────────────────────────────────────
log "huddle init (HUDDLE_DIND=1, local images)"
export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 \
       BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
if node "$REPO/cli/dist/index.js" init >/tmp/e2e-init.log 2>&1; then
  pass "gateway init (DinD)"
else fail "gateway init"; cat /tmp/e2e-init.log >&2; exit 1; fi

TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)" 2>/dev/null)
[ -n "$TOKEN" ] && pass "operator token obtained" || { fail "no operator token"; exit 1; }
AUTH="Authorization: Bearer $TOKEN"
API="http://localhost:$PORT"

# wait for API
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && pass "gateway API reachable" || { fail "API not reachable"; exit 1; }

# ── 2. allowlist the egress the build needs ──────────────────────────────────
log "allowlisting nuget + mcr domains"
allow() {
  curl -sf -H "$AUTH" -H 'content-type: application/json' \
    -X POST "$API/api/rules" -d "{\"domain\":\"$1\",\"status\":\"allow\"}" >/dev/null 2>&1
}
for d in \
  nuget.org "*.nuget.org" api.nuget.org \
  dot.net "*.dot.net" builds.dotnet.microsoft.com dotnetcli.azureedge.net \
  "*.azureedge.net" "*.blob.core.windows.net" \
  mcr.microsoft.com "*.mcr.microsoft.com" "*.data.mcr.microsoft.com" \
  "*.cdn.mscr.io" "*.microsoft.com"; do
  allow "$d"
done
pass "egress allowlist installed"

# ── 3. start a real devcontainer via the gateway ─────────────────────────────
log "starting devcontainer via /api/docker/start"
resp=$(curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" \
  -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" 2>/tmp/e2e-start.err)
if echo "$resp" | grep -q '"id"'; then pass "devcontainer started ($DC)"; else fail "devcontainer start: $resp $(cat /tmp/e2e-start.err)"; log "gateway logs:"; docker logs huddle 2>&1 | tail -20 >&2; exit 1; fi

# devcontainer + sidecar up, private daemon reachable as the vscode user
for i in $(seq 1 60); do
  docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2
done
if docker exec -u vscode "$DC" docker version >/dev/null 2>&1; then
  pass "private daemon reachable from devcontainer (vscode user)"
else fail "private daemon not reachable"; docker logs "dind-$DC" 2>&1 | tail -15 >&2; exit 1; fi

# ── 4. Aspire AppHost with SqlServer (issue #61 repro) ───────────────────────
log "writing Aspire SqlServer AppHost"
docker exec -i -u vscode "$DC" bash -lc 'mkdir -p ~/apphost && cat > ~/apphost/AppHost.csproj' <<'CSPROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <Sdk Name="Aspire.AppHost.Sdk" Version="13.4.6" />
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <IsAspireHost>true</IsAspireHost>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Aspire.Hosting.AppHost" Version="13.4.6" />
    <PackageReference Include="Aspire.Hosting.SqlServer" Version="13.4.6" />
  </ItemGroup>
</Project>
CSPROJ
docker exec -i -u vscode "$DC" bash -lc 'cat > ~/apphost/Program.cs' <<'CS'
var builder = DistributedApplication.CreateBuilder(args);
var pw = builder.AddParameter("sql-pw", "Test@2026AspireRunSqlServer", secret: true);
var sql = builder.AddSqlServer("sqlserver", password: pw)
    .WithImageTag("2022-latest")
    .WithLifetime(ContainerLifetime.Persistent);
var db = sql.AddDatabase("TestDatabase");
builder.Build().Run();
CS

log "dotnet restore (through the Huddle proxy)"
if docker exec -u vscode "$DC" bash -lc 'cd ~/apphost && ASPIRE_ALLOW_UNSECURED_TRANSPORT=true dotnet restore' >/tmp/e2e-restore.log 2>&1; then
  pass "nuget restore through Huddle egress"
else fail "nuget restore (see log)"; tail -15 /tmp/e2e-restore.log >&2; rc=1; fi

log "dotnet run (AppHost) — DCP creates the SqlServer container"
docker exec -u vscode "$DC" bash -lc 'cd ~/apphost && setsid bash -c "ASPIRE_ALLOW_UNSECURED_TRANSPORT=true dotnet run --project AppHost.csproj > \$HOME/apphost/run.log 2>&1" </dev/null >/dev/null 2>&1 &' >/dev/null 2>&1

# ── 5. confirm the SqlServer container comes up in the private daemon ─────────
log "waiting for the SqlServer container (image ~1.7GB pulled through the proxy)"
running=""; cid=""
for i in $(seq 1 180); do
  cid=$(docker exec -u vscode "$DC" docker ps -q --filter ancestor=mcr.microsoft.com/mssql/server:2022-latest 2>/dev/null | head -1)
  [ -n "$cid" ] && { running=1; break; }
  sleep 4
done
[ -n "$running" ] && pass "SqlServer container reached Running (issue #61: no longer stuck Unknown)" || { fail "SqlServer container never ran"; }

# Definitive functional proof: connect and run a query.
healthy=""
if [ -n "$cid" ]; then
  for i in $(seq 1 45); do
    out=$(docker exec -u vscode "$DC" docker exec "$cid" /opt/mssql-tools18/bin/sqlcmd \
      -S localhost -U sa -P 'Test@2026AspireRunSqlServer' -C -No -Q "SELECT @@VERSION" 2>&1)
    echo "$out" | grep -qi "Microsoft SQL Server" && { healthy=1; break; }
    sleep 4
  done
fi
[ -n "$healthy" ] && pass "SqlServer answers a real query (fully functional through the private daemon)" || { fail "SqlServer never answered a query (last sqlcmd: ${out:-<none>})"; rc=1; }

runlog=$(docker exec -u vscode "$DC" cat /home/vscode/apphost/run.log 2>/dev/null)
echo "$runlog" | grep -qi "not owned by this devcontainer" && { fail "issue #61 ownership error present"; rc=1; } || pass "no 'not owned by this devcontainer' error (#61)"
echo "$runlog" | grep -qiE "403|CopyFile.*non-zero" && { fail "issue #12 error present"; rc=1; } || pass "no 403 / CopyFile error (#12)"

[ -z "$running" ] && { rc=1; log "--- AppHost log tail ---"; echo "$runlog" | tail -30 >&2; log "--- sidecar log tail ---"; docker logs "dind-$DC" 2>&1 | tail -15 >&2; }

exit $rc
