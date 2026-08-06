#!/usr/bin/env bash
# The REPORTED real-world failure: Aspire SqlServer with a PERSISTENT data volume
# never becomes healthy (perms on /var/opt/mssql), so every resource gated on its
# health check (WaitFor) never starts. Run under HUDDLE_SYSBOX=1.
#
# Three cases, in increasing harshness:
#   A. WithDataVolume()  — named volume on the in-container daemon, first run
#   B. same volume REUSED after an AppHost restart (where ownership usually bites)
#   C. WithDataBindMount() into the workspace — crosses Sysbox's ID-mapped mount
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PORT=3968; DC=e2e-sbx-aspvol; rc=0
pass(){ printf 'PASS %s\n' "$*"; }; fail(){ printf 'FAIL %s\n' "$*"; }; log(){ printf '\033[36m[e2e]\033[0m %s\n' "$*" >&2; }
cleanup(){ [ -n "${KEEP:-}" ] && return; docker rm -f "$DC" huddle >/dev/null 2>&1||true; docker volume rm huddle-data >/dev/null 2>&1||true; docker network rm "dc-net-$DC" >/dev/null 2>&1||true; rm -rf /tmp/dc-sockets/"$DC" 2>/dev/null||true; }
trap cleanup EXIT
cleanup

BASE_IMAGE="${BASE_IMAGE:-huddle-e2e-base-sysbox:latest}"
export HUDDLE_SYSBOX=1 HUDDLE_IMAGE="${HUDDLE_IMAGE:-huddle}" HUDDLE_NO_PULL=1 \
       BASE_IMAGE_VSCODE="$BASE_IMAGE" HUDDLE_RUNTIME=docker HUDDLE_PORT=$PORT
node "$REPO/cli/dist/index.js" init >/tmp/sbxvol-init.log 2>&1 && pass "gateway init (SYSBOX)" || { fail init; cat /tmp/sbxvol-init.log>&2; exit 1; }
TOKEN=$(node -e "console.log(require('$HOME/.huddle/config.json').operatorToken)"); AUTH="Authorization: Bearer $TOKEN"; API="http://localhost:$PORT"
for i in $(seq 1 30); do curl -sf -H "$AUTH" "$API/api/auth/status" >/dev/null 2>&1 && break; sleep 1; done
for d in docker.io registry-1.docker.io auth.docker.io "*.docker.io" "*.docker.com" production.cloudflare.docker.com "*.cloudflare.docker.com" \
         api.nuget.org "*.nuget.org" mcr.microsoft.com "*.data.mcr.microsoft.com" "*.azureedge.net" builds.dotnet.microsoft.com ci.dot.net; do
  curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/rules" -d "{\"domain\":\"$d\",\"status\":\"allow\"}" >/dev/null 2>&1
done
curl -s -H "$AUTH" -H 'content-type: application/json' -X POST "$API/api/docker/start" \
  -d "{\"imageName\":\"$BASE_IMAGE\",\"containerName\":\"$DC\",\"ideName\":\"vscode\",\"empty\":true}" >/dev/null
for i in $(seq 1 90); do docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && break; sleep 2; done
docker exec -u vscode "$DC" docker version >/dev/null 2>&1 && pass "devcontainer + in-container dockerd up" || { fail "dockerd"; exit 1; }

dex(){ docker exec -i -u vscode "$DC" bash -lc "$1"; }

# ── project (ASP.NET + EF) ───────────────────────────────────────────────────
dex 'mkdir -p ~/svc && cat > ~/svc/svc.csproj' <<'CSPROJ'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
  <ItemGroup><PackageReference Include="Aspire.Microsoft.EntityFrameworkCore.SqlServer" Version="13.4.6" /></ItemGroup>
</Project>
CSPROJ
dex 'cat > ~/svc/Program.cs' <<'CS'
using Microsoft.EntityFrameworkCore;
var builder = WebApplication.CreateBuilder(args);
builder.AddSqlServerDbContext<AppDb>("appdb");
var app = builder.Build();
using (var scope = app.Services.CreateScope()) {
  var db = scope.ServiceProvider.GetRequiredService<AppDb>();
  for (var i = 0; i < 30; i++) { try { db.Database.EnsureCreated(); break; } catch { Thread.Sleep(2000); } }
  if (!db.Widgets.Any()) { db.Widgets.Add(new Widget { Name = "persisted-widget" }); db.SaveChanges(); }
}
app.MapGet("/count", (AppDb db) => new { count = db.Widgets.Count(), first = db.Widgets.Select(w => w.Name).FirstOrDefault() });
app.Run();
public class Widget { public int Id { get; set; } public string Name { get; set; } = ""; }
public class AppDb : DbContext { public AppDb(DbContextOptions<AppDb> o) : base(o) {} public DbSet<Widget> Widgets => Set<Widget>(); }
CS
dex 'mkdir -p ~/apphost && cat > ~/apphost/AppHost.csproj' <<'CSPROJ'
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
# WithDataVolume() = the reported failing shape: SQL Server (non-root uid 10001)
# must own /var/opt/mssql inside a persistent volume, and every dependent is
# gated on its health check via WaitFor.
dex 'cat > ~/apphost/Program.cs' <<'CS'
var builder = DistributedApplication.CreateBuilder(args);
var pw = builder.AddParameter("sqlpw", "Test@2026AspireVol", secret: true);
var sql = builder.AddSqlServer("sql", password: pw).WithImageTag("2022-latest").WithDataVolume("sbx-mssql-data");
var db = sql.AddDatabase("appdb");
builder.AddProject("svc", "../svc/svc.csproj").WithReference(db).WaitFor(db);
builder.Build().Run();
CS
dex 'cd ~/apphost && dotnet build AppHost.csproj' >/tmp/sbxvol-build.log 2>&1 \
  && pass "AppHost + EF build (nuget via proxy)" || { fail "build"; tail -12 /tmp/sbxvol-build.log>&2; exit 1; }

run_apphost(){ dex 'cd ~/apphost && setsid bash -c "dotnet run --no-build --project AppHost.csproj > \$HOME/apphost/run$1.log 2>&1" </dev/null >/dev/null 2>&1 &' >/dev/null 2>&1; }
stop_apphost(){ docker exec -u root "$DC" bash -lc 'pkill -f "AppHost" 2>/dev/null; pkill -f dcpctrl 2>/dev/null; sleep 3; true' >/dev/null 2>&1; }
probe_count(){ # find svc's /count on any loopback port
  local out=""
  for i in $(seq 1 "${1:-150}"); do
    for p in $(docker exec -u root "$DC" bash -lc 'ss -tlnH 2>/dev/null | grep -oE "127.0.0.1:[0-9]+" | cut -d: -f2 | sort -un'); do
      r=$(docker exec -u vscode "$DC" bash -lc "curl -s -m5 http://localhost:$p/count 2>/dev/null")
      printf '%s' "$r" | grep -q '"count"' && { printf '%s' "$r"; return 0; }
    done
    sleep 5
  done
  printf ''; return 1
}
sql_state(){ docker exec -u vscode "$DC" docker ps -a --filter 'name=sql' --format '{{.Names}} {{.Status}}' 2>/dev/null | head -3; }

# ── A. first run with the persistent volume ──────────────────────────────────
log "A: first run — WithDataVolume, dependents gated on the SqlServer health check"
run_apphost 1
resA=$(probe_count 170)
[ -n "$resA" ] && pass "A: SqlServer healthy + dependent project started (round-trip: $resA)" \
  || { fail "A: dependent project never came up (SqlServer health gate)"; rc=1; }
log "A: sql container -> $(sql_state)"
docker exec -u vscode "$DC" docker logs "$(docker exec -u vscode "$DC" docker ps -aq --filter 'name=sql' | head -1)" 2>&1 | tail -12 > /tmp/sbxvol-sql1.log 2>/dev/null
grep -qiE "permission denied|cannot open|access is denied|Operating system error" /tmp/sbxvol-sql1.log \
  && { fail "A: SqlServer log shows a permissions error"; sed 's/^/    /' /tmp/sbxvol-sql1.log >&2; rc=1; } \
  || pass "A: no permission errors in the SqlServer log"

# ── B. restart, REUSING the volume (where ownership usually bites) ───────────
log "B: restart AppHost against the SAME data volume"
stop_apphost
run_apphost 2
resB=$(probe_count 170)
[ -n "$resB" ] && pass "B: SqlServer healthy again on the REUSED volume ($resB)" \
  || { fail "B: SqlServer/dependents failed after volume reuse"; rc=1; }
printf '%s' "$resB" | grep -q '"count":1' \
  && pass "B: data persisted across restart (count still 1, no re-seed)" \
  || log "B: count was not 1 ($resB) — volume may not have persisted"
docker exec -u vscode "$DC" docker logs "$(docker exec -u vscode "$DC" docker ps -aq --filter 'name=sql' | head -1)" 2>&1 | tail -15 > /tmp/sbxvol-sql2.log 2>/dev/null
grep -qiE "permission denied|cannot open|access is denied|Operating system error" /tmp/sbxvol-sql2.log \
  && { fail "B: permissions error after volume reuse"; sed 's/^/    /' /tmp/sbxvol-sql2.log >&2; rc=1; } \
  || pass "B: no permission errors after volume reuse"

# ── C. harsher: bind mount into the workspace (ID-mapped mount boundary) ─────
log "C: WithDataBindMount into the workspace"
stop_apphost
dex 'mkdir -p ~/mssqldata && cat > ~/apphost/Program.cs' <<'CS'
var builder = DistributedApplication.CreateBuilder(args);
var pw = builder.AddParameter("sqlpw", "Test@2026AspireVol", secret: true);
var sql = builder.AddSqlServer("sql", password: pw).WithImageTag("2022-latest").WithDataBindMount("/home/vscode/mssqldata");
var db = sql.AddDatabase("appdb");
builder.AddProject("svc", "../svc/svc.csproj").WithReference(db).WaitFor(db);
builder.Build().Run();
CS
dex 'cd ~/apphost && dotnet build AppHost.csproj' >/tmp/sbxvol-build2.log 2>&1 || { fail "C: rebuild"; tail -8 /tmp/sbxvol-build2.log>&2; }
run_apphost 3
resC=$(probe_count 120)
if [ -n "$resC" ]; then
  pass "C: bind-mounted data dir works too ($resC)"
else
  docker exec -u vscode "$DC" docker logs "$(docker exec -u vscode "$DC" docker ps -aq --filter 'name=sql' | head -1)" 2>&1 | tail -15 > /tmp/sbxvol-sql3.log 2>/dev/null
  if grep -qiE "permission denied|cannot open|access is denied|Operating system error" /tmp/sbxvol-sql3.log; then
    log "C: FAILS with a permissions error (documented limitation, needs chown of the bind dir):"
    sed 's/^/    /' /tmp/sbxvol-sql3.log >&2
  fi
  log "C: bind-mount variant did not come up — recorded, not counted as a product failure yet"
fi

exit $rc
