#!/usr/bin/env bash
# ============================================================================
# FULL-PARITY autonomous Aspire scenario — the exact thing a user does by hand:
#
#   1. build the Huddle gateway image + a devcontainer base image  (once, cached)
#   2. `huddle init` a real gateway in DinD mode
#   3. start a devcontainer inside it
#   4. create a .NET Aspire AppHost that provisions a SqlServer resource
#   5. `dotnet run` the AppHost
#   6. OPEN THE DASHBOARD IN A REAL BROWSER  (headless Chromium)
#   7. SEE THE SQL SERVER — assert the resource grid renders `sql` Running,
#      its database, and the referencing project, over the live SignalR/gRPC
#      circuit (NOT a log-grep), and screenshot it as evidence.
#
# The last two steps are the whole point: earlier tests only grepped the AppHost
# log / fetched the Blazor shell, both of which pass even when the dashboard's
# resource circuit is dead and a user sees an empty grid. This drives the actual
# rendered DOM.
#
# Requires locally-built images (auto-built if missing):
#   huddle-local:dind, huddle-e2e-base:latest, huddle-dashboard-probe:latest
#
# Env:
#   KEEP=1   leave the whole stack running on success (for manual/browser poking)
#            and print the container name + dashboard login URL.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
source "$HERE/lib/dashboard.sh"

PORT="${HUDDLE_PORT:-3971}"; DC=e2e-aspire-dash; rc=0
SHOTDIR="${SHOTDIR:-$HERE/.artifacts/aspire-dashboard}"
pass(){ printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '\033[31mFAIL\033[0m %s\n' "$*"; rc=1; }
log(){  printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ [ "${KEEP:-0}" = 1 ] && return 0; docker rm -f "$DC" "dind-$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data "huddle-dind-data-$DC" >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; rm -rf /tmp/dc-sockets/"$DC" 2>/dev/null||true; }
trap cleanup EXIT
# always start clean regardless of KEEP
KEEP=0 cleanup

# ── 0. images ────────────────────────────────────────────────────────────────
build_if_missing(){ docker image inspect "$1" >/dev/null 2>&1 || { log "building $1"; eval "$2"; }; }
build_if_missing huddle-local:dind          "docker build -t huddle-local:dind '$REPO/gateway' >/tmp/dash-img.log 2>&1"
build_if_missing huddle-e2e-base:latest     "docker build -t huddle-e2e-base:latest -f '$HERE/Dockerfile.e2e-base' '$HERE' >/tmp/dash-img.log 2>&1"
build_if_missing huddle-dashboard-probe:latest "docker build -t huddle-dashboard-probe:latest -f '$HERE/lib/Dockerfile.probe' '$HERE/lib' >/tmp/dash-img.log 2>&1"

# ── 1-2. gateway init (DinD) ─────────────────────────────────────────────────
export HUDDLE_DIND=1 HUDDLE_IMAGE=huddle-local:dind HUDDLE_NO_PULL=1 BASE_IMAGE_VSCODE=huddle-e2e-base:latest HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/dash-init.log 2>&1 && pass "gateway init (DinD)" || { fail "gateway init"; cat /tmp/dash-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
for d in docker.io registry-1.docker.io auth.docker.io "*.docker.io" "*.docker.com" production.cloudflare.docker.com "*.cloudflare.docker.com" \
         api.nuget.org "*.nuget.org" mcr.microsoft.com "*.data.mcr.microsoft.com" "*.azureedge.net" builds.dotnet.microsoft.com ci.dot.net; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done

# ── 3. start the devcontainer ────────────────────────────────────────────────
curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" -d "{\"imageName\":\"huddle-e2e-base:latest\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 60); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done
pass "devcontainer started"

# ── 4. an Aspire AppHost that provisions SqlServer + a project that uses it ───
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
var pw = builder.AddParameter("sqlpw", "Test@2026AspireDash", secret: true);
var sql = builder.AddSqlServer("sql", password: pw).WithImageTag("2022-latest");
var db = sql.AddDatabase("appdb");
builder.AddProject("svc", "../svc/svc.csproj").WithReference(db).WaitFor(db);
builder.Build().Run();
CS

log "dotnet build (nuget through the Huddle proxy)"
docker exec -u vscode "$DC" bash -lc 'cd ~/apphost && dotnet build AppHost.csproj' >/tmp/dash-build.log 2>&1 \
  && pass "AppHost + project build" || { fail "build"; tail -15 /tmp/dash-build.log>&2; exit 1; }

# ── 5. run the AppHost (dashboard + SqlServer come up) ────────────────────────
log "dotnet run (dashboard boots, SqlServer container starts)"
docker exec -u vscode "$DC" bash -lc 'cd ~/apphost && setsid bash -c "dotnet run --no-build --project AppHost.csproj > \$HOME/apphost/run.log 2>&1" </dev/null >/dev/null 2>&1 &' >/dev/null 2>&1

# wait for the project<->SqlServer round-trip (proves SqlServer is really up)
log "waiting for SqlServer (~1.7GB pull) + EF round-trip"
result=""; for i in $(seq 1 180); do
  for p in $(docker exec -u root "$DC" bash -lc 'ss -tlnH 2>/dev/null | grep -oE "127.0.0.1:[0-9]+" | cut -d: -f2 | sort -un'); do
    r=$(docker exec -u vscode "$DC" bash -lc "curl -s -m5 http://localhost:$p/count 2>/dev/null")
    printf '%s' "$r" | grep -q '"count"' && { result="$r"; break 2; }
  done
  sleep 5
done
printf '%s' "$result" | grep -q 'hello-from-ef' \
  && pass "SqlServer live: project -> DB round-trip ($result)" \
  || fail "SqlServer round-trip never succeeded ($result)"

# ── 6-7. OPEN THE DASHBOARD IN A REAL BROWSER, SEE THE SQL SERVER ─────────────
runlog=$(docker exec -u vscode "$DC" cat /home/vscode/apphost/run.log 2>/dev/null)
dashurl=$(echo "$runlog" | grep -oE 'http://localhost:[0-9]+/login\?t=[a-f0-9]+' | head -1)
if [ -z "$dashurl" ]; then
  fail "no dashboard login URL in AppHost log"; log "--- run.log tail ---"; echo "$runlog" | tail -20 >&2
else
  log "driving the dashboard in headless Chromium: $dashurl"
  probe=$(assert_dashboard "$DC" "$dashurl" "sql,appdb,svc" "sql,svc" "$SHOTDIR")
  prc=$?
  if [ $prc -eq 0 ]; then
    pass "dashboard RENDERS the SqlServer resource (grid populated over the live circuit)"
    log "probe: $probe"
    log "screenshot: $SHOTDIR/dashboard.png"
  else
    fail "dashboard did NOT render the SqlServer resource in a real browser"
    log "probe: $probe"
    log "screenshot (empty-grid evidence): $SHOTDIR/dashboard.png"
  fi
fi

if [ "${KEEP:-0}" = 1 ] && [ $rc -eq 0 ]; then
  log "KEEP=1 — leaving stack up.  devcontainer=$DC"
  log "dashboard login URL (from inside the netns): $dashurl"
fi
exit $rc
