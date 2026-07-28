#!/usr/bin/env bash
# FULL end-to-end: a REAL Huddle gateway (HUDDLE_DIND=1) + devcontainer, then a
# .NET Aspire AppHost with a PROJECT resource (ASP.NET + EF Core) referencing a
# SqlServer container. Confirms the realistic Aspire path the container-only e2e
# doesn't: project -> SqlServer connection via Aspire service discovery + the
# shared-netns loopback, an EF schema create, and a DB round-trip through the
# project's HTTP endpoint. Also asserts the dashboard/OTLP run on plain http
# (ASPIRE_ALLOW_UNSECURED_TRANSPORT injected by the gateway) with no gRPC
# UntrustedRoot — the user-reported "grpc errors on the dashboard" regression.
#
# Requires locally-built huddle-local:dind + huddle-e2e-base:latest.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3970; DC=e2e-aspire-ef; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-data-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; rm -rf /tmp/dc-sockets/"$DC" 2>/dev/null||true; }
trap cleanup EXIT
cleanup

export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/ef-init.log 2>&1 && pass "gateway init (DinD)" || { fail init; cat /tmp/ef-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
for d in docker.io registry-1.docker.io auth.docker.io "*.docker.io" "*.docker.com" production.cloudflare.docker.com "*.cloudflare.docker.com" \
         api.nuget.org "*.nuget.org" mcr.microsoft.com "*.data.mcr.microsoft.com" "*.azureedge.net" builds.dotnet.microsoft.com ci.dot.net; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done
curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done
pass "devcontainer started"

# The gateway must have injected ASPIRE_ALLOW_UNSECURED_TRANSPORT (dev-cert gRPC fix).
docker exec -u vscode "$DC" printenv ASPIRE_ALLOW_UNSECURED_TRANSPORT | grep -q true \
  && pass "ASPIRE_ALLOW_UNSECURED_TRANSPORT injected by gateway" || { fail "env not injected"; rc=1; }

# ── project (ASP.NET + EF Core) + AppHost ────────────────────────────────────
docker exec -i -u vscode "$DC" bash -lc 'mkdir -p ~/svc && cat > ~/svc/svc.csproj' <<'CSPROJ'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
  <ItemGroup><PackageReference Include="Aspire.Microsoft.EntityFrameworkCore.SqlServer" Version="13.4.6" /></ItemGroup>
</Project>
CSPROJ
docker exec -i -u vscode "$DC" bash -lc 'cat > ~/svc/Program.cs' <<'CS'
using Microsoft.EntityFrameworkCore;
var builder = WebApplication.CreateBuilder(args);
builder.AddSqlServerDbContext<AppDb>("appdb");
var app = builder.Build();
using (var scope = app.Services.CreateScope()) {
  var db = scope.ServiceProvider.GetRequiredService<AppDb>();
  for (var i = 0; i < 30; i++) { try { db.Database.EnsureCreated(); break; } catch { Thread.Sleep(2000); } }
  if (!db.Widgets.Any()) { db.Widgets.Add(new Widget { Name = "hello-from-ef" }); db.SaveChanges(); }
}
app.MapGet("/count", (AppDb db) => new { count = db.Widgets.Count(), first = db.Widgets.Select(w => w.Name).FirstOrDefault() });
app.Run();
public class Widget { public int Id { get; set; } public string Name { get; set; } = ""; }
public class AppDb : DbContext { public AppDb(DbContextOptions<AppDb> o) : base(o) {} public DbSet<Widget> Widgets => Set<Widget>(); }
CS
docker exec -i -u vscode "$DC" bash -lc 'mkdir -p ~/apphost && cat > ~/apphost/AppHost.csproj' <<'CSPROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <Sdk Name="Aspire.AppHost.Sdk" Version="13.4.6" />
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>
  <ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable><IsAspireHost>true</IsAspireHost></PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Aspire.Hosting.AppHost" Version="13.4.6" />
    <PackageReference Include="Aspire.Hosting.SqlServer" Version="13.4.6" />
    <ProjectReference Include="../svc/svc.csproj" IsAspireProjectResource="true" />
  </ItemGroup>
</Project>
CSPROJ
docker exec -i -u vscode "$DC" bash -lc 'cat > ~/apphost/Program.cs' <<'CS'
var builder = DistributedApplication.CreateBuilder(args);
var pw = builder.AddParameter("sqlpw", "Test@2026AspireEfProj", secret: true);
var sql = builder.AddSqlServer("sql", password: pw).WithImageTag("2022-latest");
var db = sql.AddDatabase("appdb");
// .WaitFor(db): svc only starts once SqlServer is healthy. This is the idiomatic
// Aspire pattern AND exercises the health-check path — which requires the
// devcontainer/DCP to actually reach the SqlServer container's published port.
// Before the docker0/br+ egress exemption that path was DROPped, so the health
// check never went green and WaitFor stalled forever; hence this doubles as a
// regression guard for that fix.
builder.AddProject("svc", "../svc/svc.csproj").WithReference(db).WaitFor(db);
builder.Build().Run();
CS

log "dotnet restore + build (through the Huddle proxy)"
docker exec -u vscode "$DC" bash -lc 'cd ~/apphost && dotnet build AppHost.csproj' >/tmp/ef-build.log 2>&1 \
  && pass "AppHost + EF project build (nuget via proxy)" || { fail "build (see log)"; tail -15 /tmp/ef-build.log>&2; exit 1; }

log "dotnet run (no manual ASPIRE flag — must inherit from the devcontainer env)"
docker exec -u vscode "$DC" bash -lc 'cd ~/apphost && setsid bash -c "dotnet run --no-build --project AppHost.csproj > \$HOME/apphost/run.log 2>&1" </dev/null >/dev/null 2>&1 &' >/dev/null 2>&1

# ── wait for SqlServer + the project, then a DB round-trip ────────────────────
# NB: svc's own HTTP port is assigned by Aspire and is NOT printed in the AppHost
# run.log (only the dashboard/OTLP ports are). So probe every loopback listener
# for a /count that answers with JSON — that's the svc endpoint whatever port it
# landed on.
log "waiting for SqlServer (~1.7GB pull) + the svc project + EF EnsureCreated"
result=""; for i in $(seq 1 180); do
  for p in $(docker exec -u root "$DC" bash -lc 'ss -tlnH 2>/dev/null | grep -oE "127.0.0.1:[0-9]+" | cut -d: -f2 | sort -un'); do
    r=$(docker exec -u vscode "$DC" bash -lc "curl -s -m5 http://localhost:$p/count 2>/dev/null")
    printf '%s' "$r" | grep -q '"count"' && { result="$r"; break 2; }
  done
  sleep 5
done
runlog=$(docker exec -u vscode "$DC" cat /home/vscode/apphost/run.log 2>/dev/null)

printf '%s' "$result" | grep -q 'hello-from-ef' \
  && pass "project -> SqlServer DB round-trip via Aspire service discovery ($result)" \
  || { fail "no DB round-trip from the project resource ($result)"; rc=1; }

echo "$runlog" | grep -qE "Dashboard:  http://" && pass "dashboard on plain http (unsecured-transport inherited)" || { fail "dashboard not http"; rc=1; }
echo "$runlog" | grep -qiE "UntrustedRoot|RpcException.*SSL" && { fail "dashboard gRPC UntrustedRoot present"; rc=1; } || pass "no dashboard gRPC UntrustedRoot / cert errors"

# ── ACTUALLY exercise the dashboard IN A REAL BROWSER (not log-greps) ──────────
# The greps above only prove the dashboard logged an http URL with no cert error.
# They do NOT prove the Blazor UI renders the resources, which is what a user means
# by "the dashboard works". Drive a headless Chromium (joined to this devcontainer's
# netns) through the login token and assert the resource grid actually populates
# over the live SignalR/gRPC circuit: sql + appdb + svc present, sql & svc Running.
# A dead resource circuit leaves the grid empty and fails here — the real signal.
source "$HERE/lib/dashboard.sh"
dashurl=$(echo "$runlog" | grep -oE 'http://localhost:[0-9]+/login\?t=[a-f0-9]+' | head -1)
if [ -n "$dashurl" ]; then
  probe=$(assert_dashboard "$DC" "$dashurl" "sql,appdb,svc" "sql,svc" "$HERE/.artifacts/aspire-project-ef")
  if [ $? -eq 0 ]; then
    pass "dashboard renders the SqlServer resource in a real browser (grid populated)"
    log "probe: $probe"; log "screenshot: $HERE/.artifacts/aspire-project-ef/dashboard.png"
  else
    fail "dashboard did NOT render resources in a real browser"; rc=1
    log "probe: $probe"; log "screenshot: $HERE/.artifacts/aspire-project-ef/dashboard.png"
  fi
else
  fail "no dashboard login URL in AppHost log"; rc=1
fi

[ -z "$result" ] && { rc=1; log "--- AppHost log tail ---"; echo "$runlog" | tail -30 >&2; }
exit $rc
