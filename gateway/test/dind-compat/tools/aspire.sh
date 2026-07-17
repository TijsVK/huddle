#!/usr/bin/env bash
# .NET Aspire — the flagship case (issues #12 and #61). Aspire's DCP orchestrates
# containers over DOCKER_HOST and does exactly the things the socket-proxy breaks:
#   #12  DCP loopback calls proxied -> 403 ; docker CopyFile (dev-cert) blocked
#   #61  InspectContainers -> "container not owned by this devcontainer" -> stuck
# Against the private daemon these all work. We run the #12 repro end-to-end and
# assert the DCP-spawned container actually reaches Running, with none of those
# errors in the AppHost log.
source "$(dirname "$0")/../lib.sh"
NAME=aspire
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

# .NET needs libicu (dev-certs/DCP crash without it). Install it as root.
dcsh "$NAME" 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq libicu72 >/dev/null 2>&1 || apt-get install -y -qq libicu-dev >/dev/null 2>&1' || true

log "$NAME: installing .NET SDK 10 (large download, first run)"
if ! dcshu "$NAME" dev 'curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh && bash /tmp/di.sh --channel 10.0 --install-dir $HOME/.dotnet' >/tmp/aspire-dotnet.log 2>&1; then
  fail "$NAME: dotnet SDK install"; tail -5 /tmp/aspire-dotnet.log >&2; down "$NAME"; exit 1
fi
pass "$NAME: .NET SDK 10 installed"

dcshu "$NAME" dev 'mkdir -p ~/apphost' >/dev/null
docker exec -i -u dev "${PREFIX}-$NAME" bash -lc 'cat > ~/apphost/AppHost.csproj' <<'CSPROJ'
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
  </ItemGroup>
</Project>
CSPROJ
docker exec -i -u dev "${PREFIX}-$NAME" bash -lc 'cat > ~/apphost/Program.cs' <<'CS'
var builder = DistributedApplication.CreateBuilder(args);
builder.AddContainer("repro", "nginx", "alpine");
builder.Build().Run();
CS

DENV='export PATH=$HOME/.dotnet:$PATH DOTNET_ROOT=$HOME/.dotnet DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 ASPIRE_ALLOW_UNSECURED_TRANSPORT=true'

# Pre-restore so first-run nuget download isn't counted against the run timeout.
log "$NAME: dotnet restore"
dcshu "$NAME" dev "$DENV; cd ~/apphost && dotnet restore" >/tmp/aspire-restore.log 2>&1 \
  && pass "$NAME: nuget restore (Aspire SDK)" || { fail "$NAME: nuget restore"; tail -8 /tmp/aspire-restore.log >&2; }

# dev-certs (Aspire copies these into containers — the #12 CopyFile path).
dcshu "$NAME" dev "$DENV; dotnet dev-certs https >/dev/null 2>&1 || true"

log "$NAME: dotnet run (AppHost) — DCP orchestration"
dcshu "$NAME" dev "$DENV; cd ~/apphost && setsid bash -c 'dotnet run --project AppHost.csproj > \$HOME/apphost/run.log 2>&1' </dev/null >/dev/null 2>&1 &" >/dev/null 2>&1
sleep 8
# Confirm it actually launched (perms / crash guard).
if ! dcsh "$NAME" 'pgrep -f "dotnet" >/dev/null 2>&1'; then
  log "$NAME: dotnet did not stay running; log tail:"; dcsh "$NAME" 'tail -15 /home/dev/apphost/run.log 2>/dev/null' >&2
fi

# Wait for DCP to bring the container to Running (via the private daemon).
running=""
for i in $(seq 1 72); do
  n=$(dcsh "$NAME" 'docker ps --filter ancestor=nginx:alpine --filter status=running -q | wc -l' 2>/dev/null | tr -d '[:space:]')
  [ "${n:-0}" -ge 1 ] && { running=1; break; }
  sleep 5
done
[ -n "$running" ] && pass "$NAME: DCP-spawned container reached Running (#61 inspect path OK)" || { fail "$NAME: DCP container never reached Running"; rc=1; }

runlog=$(dcsh "$NAME" 'cat /home/dev/apphost/run.log 2>/dev/null' 2>/dev/null)
if printf '%s' "$runlog" | grep -qiE "proxy tunnel request .* failed with status code '403'|403 \(Forbidden\)"; then
  fail "$NAME: DCP loopback got 403 (issue #12 regression)"; rc=1
else pass "$NAME: no DCP loopback 403 (issue #12 fixed)"; fi
if printf '%s' "$runlog" | grep -qiE "CopyFile.*non-zero|command 'CopyFile' returned"; then
  fail "$NAME: docker CopyFile failed (issue #12 cert-copy regression)"; rc=1
else pass "$NAME: docker CopyFile not blocked (issue #12 cert-copy OK)"; fi
if printf '%s' "$runlog" | grep -qi "not owned by this devcontainer"; then
  fail "$NAME: InspectContainers ownership error (issue #61 regression)"; rc=1
else pass "$NAME: no ownership/inspect error (issue #61 fixed)"; fi

[ $rc -ne 0 ] && { log "$NAME: --- AppHost log tail ---"; printf '%s\n' "$runlog" | tail -25 >&2; }

dcshu "$NAME" dev 'pkill -f "dotnet" 2>/dev/null; pkill -f dcp 2>/dev/null' >/dev/null 2>&1 || true
down "$NAME"
exit $rc
