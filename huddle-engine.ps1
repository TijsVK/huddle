# ------------------------------------------------------------------------------
#  Huddle engine host (Windows) - provision the WSL2 distro that runs dockerd
#  with the Sysbox runtime, so every devcontainer can be a Sysbox sandbox with
#  its own Docker inside.
#
#  Why a separate distro: Sysbox installs on the Docker *host*, and Docker
#  Desktop's own distro is managed by Docker (its equivalent, Enhanced Container
#  Isolation, is Business-tier and Desktop-only). So Huddle owns an engine distro.
#
#  Dot-source this from huddle.ps1, or run standalone:
#     .\huddle-engine.ps1 -Setup     # create + provision the distro
#     .\huddle-engine.ps1 -Check     # verify an existing engine
#     .\huddle-engine.ps1 -Shell     # open a shell in the engine
# ------------------------------------------------------------------------------
param(
    [switch]$Setup,
    [switch]$Check,
    [switch]$Shell,
    [switch]$Diagnose,
    [switch]$Code,
    [switch]$Attach,
    [switch]$Up
)

# NB: do NOT set $ErrorActionPreference here. huddle.ps1 dot-sources this file,
# so a top-level assignment lands in ITS scope, and then any native command that
# writes to stderr (e.g. `docker info` printing "WARNING: daemon is not using the
# default seccomp profile") becomes a terminating NativeCommandError. It is set
# per standalone entry point at the bottom instead.

$ENGINE_DISTRO = if ($env:HUDDLE_ENGINE_DISTRO) { $env:HUDDLE_ENGINE_DISTRO } else { 'huddle-engine' }
$ENGINE_BASE   = if ($env:HUDDLE_ENGINE_BASE)   { $env:HUDDLE_ENGINE_BASE   } else { 'Ubuntu-24.04' }

function Write-Step { param([string]$Msg) Write-Host "== $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  [ok] $Msg" -ForegroundColor Green }
function Write-Bad  { param([string]$Msg) Write-Host "  [--] $Msg" -ForegroundColor Red }

function Test-Wsl {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Bad "wsl.exe not found. Install WSL2: 'wsl --install' (needs Windows 10 21H2+ / Windows 11)."
        return $false
    }
    return $true
}

# WSL writes UTF-16 with NULs; strip them so -match/-contains behave.
function Get-WslDistros {
    (& wsl.exe -l -q 2>$null) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Test-HuddleEngine {
    if (-not (Test-Wsl)) { return $false }
    return ((Get-WslDistros) -contains $ENGINE_DISTRO)
}

# Run a command inside the engine distro as root.
function Invoke-Engine {
    param([Parameter(Mandatory)][string]$Command, [switch]$AsUser, [switch]$Quiet)
    $userArgs = if ($AsUser) { @() } else { @('-u', 'root') }
    # Pass the script base64-encoded. PowerShell mangles quotes when it hands
    # arguments to a native .exe, so any command containing double quotes arrived
    # at bash half-quoted ("syntax error near unexpected token `('"). The encoded
    # payload contains no quotes, spaces or shell metacharacters, so nothing can
    # be re-interpreted on the way in.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    $wrapped = "echo $b64 | base64 -d | bash"
    if ($Quiet) {
        & wsl.exe -d $ENGINE_DISTRO @userArgs -- bash -lc $wrapped *> $null
    } else {
        # NO 2>&1: merging stderr into the pipeline turns every stderr line into
        # an ErrorRecord, so ordinary progress output (docker/buildkit writes its
        # progress to stderr) is rendered as a NativeCommandError. Out-Host keeps
        # stdout out of the return value.
        & wsl.exe -d $ENGINE_DISTRO @userArgs -- bash -lc $wrapped | Out-Host
    }
    return $LASTEXITCODE
}

# Windows path -> path inside the distro (C:\src\x -> /mnt/c/src/x).
function ConvertTo-EnginePath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $full = (Resolve-Path -LiteralPath $WindowsPath).Path
    $drive = $full.Substring(0, 1).ToLower()
    $rest = $full.Substring(2) -replace '\\', '/'
    return "/mnt/$drive$rest"
}

function New-HuddleEngineDistro {
    Write-Step "creating WSL2 distro '$ENGINE_DISTRO' from $ENGINE_BASE"
    # WSL 2.4+ can install a named instance without launching it. Older builds
    # need a manual --import of a rootfs tarball; we surface that clearly.
    & wsl.exe --install $ENGINE_BASE --name $ENGINE_DISTRO --no-launch
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "'wsl --install $ENGINE_BASE --name $ENGINE_DISTRO --no-launch' failed (needs WSL 2.4+)."
        Write-Host "  Fallback: download an Ubuntu 24.04 rootfs and import it:" -ForegroundColor Yellow
        Write-Host "    wsl --import $ENGINE_DISTRO C:\wsl\$ENGINE_DISTRO ubuntu-24.04-rootfs.tar.gz" -ForegroundColor Yellow
        return $false
    }
    Write-Ok "distro created"
    return $true
}

function Set-EngineWslConf {
    # Needed: systemd (sysbox ships systemd units) AND Windows PATH interop, so
    # `code` / `code-insiders` work from inside the distro - that is how VS Code
    # attaches to containers on the engine daemon. Only rewrite + restart when
    # something is actually wrong: terminating the distro kills the gateway and
    # every devcontainer.
    $okSystemd = (Invoke-Engine -Quiet -Command 'grep -q "^systemd=true" /etc/wsl.conf 2>/dev/null') -eq 0
    $okPath    = (Invoke-Engine -Quiet -Command 'grep -q "^appendWindowsPath=false" /etc/wsl.conf 2>/dev/null') -ne 0
    if ($okSystemd -and $okPath) {
        Write-Ok "wsl.conf already correct in '$ENGINE_DISTRO' (left running)"
        return $true
    }
    Write-Step "writing /etc/wsl.conf in '$ENGINE_DISTRO' (systemd + Windows PATH interop)"
    # printf per line instead of a here-doc: this .ps1 is checked out CRLF on
    # Windows and a here-doc terminator would carry a \r.
    $cmd = "printf '%s\n' '[boot]' 'systemd=true' '' '[interop]' 'enabled=true' 'appendWindowsPath=true' > /etc/wsl.conf && sed -i 's/\r$//' /etc/wsl.conf"
    if ((Invoke-Engine -Command $cmd) -ne 0) { Write-Bad "could not write /etc/wsl.conf"; return $false }
    & wsl.exe --terminate $ENGINE_DISTRO | Out-Null
    Write-Ok "wsl.conf written (distro restarted so it takes effect)"
    return $true
}

function Install-EngineStack {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $enginePath = ConvertTo-EnginePath $RepoRoot
    Write-Step "provisioning docker + sysbox inside '$ENGINE_DISTRO'"
    Write-Host "  (repo visible in the distro at $enginePath)" -ForegroundColor DarkGray
    # Pipe through sed: with git's autocrlf the .sh is checked out CRLF, and bash
    # then dies on $'\r' ("set: pipefail: invalid option name", "syntax error near
    # unexpected token elif"). Stripping CR here makes it work either way.
    $rc = Invoke-Engine -Command "sed 's/\r$//' '$enginePath/scripts/huddle-engine-install.sh' | bash -s --"
    if ($rc -ne 0) { Write-Bad "engine provisioning failed (exit $rc)"; return $false }
    Write-Ok "engine provisioned"
    return $true
}

function Test-EngineReady {
    if (-not (Test-HuddleEngine)) { Write-Bad "distro '$ENGINE_DISTRO' does not exist - run with -Setup"; return $false }
    # No embedded double quotes: PowerShell has no backslash escaping, and
    # `docker info` already lists the runtimes in its plain output.
    $rc = Invoke-Engine -Quiet -Command 'command -v sysbox-runc >/dev/null 2>&1 && docker info 2>/dev/null | grep -q sysbox-runc'
    if ($rc -ne 0) { Write-Bad "engine exists but sysbox-runc is not registered - run with -Setup"; return $false }
    Write-Ok "engine '$ENGINE_DISTRO' ready (docker + sysbox-runc)"
    return $true
}

# Full setup: distro -> systemd -> docker+sysbox -> verify.
function Initialize-HuddleEngine {
    param([string]$RepoRoot = $PSScriptRoot)
    if (-not (Test-Wsl)) { return $false }
    if (-not (Test-HuddleEngine)) {
        if (-not (New-HuddleEngineDistro)) { return $false }
        if (-not (Set-EngineWslConf)) { return $false }
    } else {
        Write-Ok "distro '$ENGINE_DISTRO' already exists"
        Set-EngineWslConf | Out-Null
    }
    if (-not (Install-EngineStack -RepoRoot $RepoRoot)) { return $false }
    Start-EngineKeepalive | Out-Null
    return (Test-EngineReady)
}


# WSL tears a distro down once no client is attached to it. huddle.ps1 drives the
# engine with short-lived `wsl.exe` calls, so seconds after `huddle init` returns
# the distro (systemd, dockerd, and the gateway with it) is stopped again - the
# "Huddle starts, then exits" symptom. The next wsl.exe call boots it back up,
# which is why the log shows the gateway starting over and over and why dockerd's
# journal shows repeated "Starting docker.service".
#
# A hidden, long-lived client keeps the distro alive. It is idempotent and costs
# one sleeping process.
function Start-EngineKeepalive {
    $marker = 'huddle-engine-keepalive'
    if ((Invoke-Engine -Quiet -Command "pgrep -f $marker >/dev/null 2>&1") -eq 0) {
        Write-Ok "keepalive already running (distro stays up)"
        return $true
    }
    # Start-Process joins -ArgumentList with spaces WITHOUT quoting, so an element
    # containing spaces is split into separate arguments: passing
    #   'bash','-c','exec -a marker sleep infinity'
    # made bash run the command string "exec" and exit instantly - which is why
    # the keepalive never appeared. Verified by dumping argv from a child process.
    # So: install a launcher in the distro (Invoke-Engine handles quoting via
    # base64) and start it with arguments that contain no spaces at all.
    $installer = @(
        'printf "%s\n" "#!/bin/bash" "exec -a ' + $marker + ' sleep infinity" > /usr/local/bin/huddle-keepalive',
        'chmod +x /usr/local/bin/huddle-keepalive'
    ) -join ' && '
    if ((Invoke-Engine -Quiet -Command $installer) -ne 0) {
        Write-Host "  [i] could not install the keepalive launcher" -ForegroundColor DarkGray
        return $false
    }
    Start-Process -FilePath 'wsl.exe' `
        -ArgumentList @('-d', $ENGINE_DISTRO, '-u', 'root', '--', '/usr/local/bin/huddle-keepalive') `
        -WindowStyle Hidden | Out-Null
    foreach ($i in 1..10) {
        Start-Sleep -Seconds 1
        if ((Invoke-Engine -Quiet -Command "pgrep -f $marker >/dev/null 2>&1") -eq 0) {
            Write-Ok "keepalive started - '$ENGINE_DISTRO' stays up while you work"
            return $true
        }
    }
    # Not fatal: the gateway has --restart unless-stopped, so it returns with the
    # daemon. Only the idle teardown/restart cycle is not suppressed.
    Write-Host "  [i] no keepalive process; the distro may stop when idle." -ForegroundColor DarkGray
    Write-Host "      Huddle restarts with dockerd, or keep a shell open: wsl -d $ENGINE_DISTRO" -ForegroundColor DarkGray
    return $false
}

function Stop-EngineKeepalive {
    Invoke-Engine -Quiet -Command "pkill -f huddle-engine-keepalive" | Out-Null
    Write-Ok "keepalive stopped"
}

# Start Huddle ON the engine host, in Sysbox mode. Everything (gateway image
# build, `huddle init`, devcontainers) runs inside the distro; the portal is
# reachable from Windows on localhost via WSL's port forwarding.
function Start-HuddleOnEngine {
    param(
        [string]$RepoRoot = $PSScriptRoot,
        [int]$Port = $(if ($env:HUDDLE_PORT) { [int]$env:HUDDLE_PORT } else { 3000 }),
        [string]$Image = 'huddle',
        [switch]$SkipBuild
    )
    if (-not (Test-EngineReady)) { return $false }
    Start-EngineKeepalive | Out-Null
    $repo = ConvertTo-EnginePath $RepoRoot

    if (-not $SkipBuild) {
        Write-Step "building the gateway image inside the engine"
        if ((Invoke-Engine -Command "cd '$repo' && BUILDKIT_PROGRESS=plain docker build -t $Image ./gateway") -ne 0) {
            Write-Bad "gateway image build failed"; return $false
        }
        Write-Ok "gateway image '$Image' built"

        Write-Step "building the CLI inside the engine"
        if ((Invoke-Engine -Command "cd '$repo/cli' && npm install --no-audit --no-fund && npx tsc") -ne 0) {
            Write-Bad "CLI build failed"; return $false
        }
        Write-Ok "CLI built"
    }

    # Stop the previous gateway FIRST. `huddle init` removes it anyway, but the
    # port preflight below runs before init - without this, the previous gateway
    # holds the port, the preflight refuses, and a re-init can never succeed.
    Invoke-Engine -Quiet -Command 'docker rm -f huddle >/dev/null 2>&1; true' | Out-Null

    # Preflight: WSL2 distros SHARE one network namespace, so a huddle container
    # on Docker Desktop's daemon (e.g. left over from a classic init) still owns
    # the port even after the engine-side container is gone. The engine's new
    # container then cannot bind it and exits immediately with an empty log.
    if ((Invoke-Engine -Quiet -Command "ss -tln 2>/dev/null | grep -q ':$Port '") -eq 0) {
        Write-Bad "port $Port is still in use inside the WSL network namespace after removing the engine's gateway."
        Write-Host "  Holder:" -ForegroundColor Yellow
        Invoke-Engine -Command "ss -tlnp 2>/dev/null | grep ':$Port '" | Out-Null
        Write-Host "  WSL2 distros share one netns, so this is usually a huddle container on" -ForegroundColor Yellow
        Write-Host "  Docker Desktop's daemon. Stop it (or quit Docker Desktop) and retry:" -ForegroundColor Yellow
        Write-Host "    docker rm -f huddle        # in a Windows terminal (Docker Desktop)" -ForegroundColor Yellow
        Write-Host "  Or pick another port BEFORE starting huddle.ps1:" -ForegroundColor Yellow
        Write-Host "      `$env:HUDDLE_PORT = '3100'   # then re-run .\huddle.ps1" -ForegroundColor Yellow
        return $false
    }

    Write-Step "huddle init (HUDDLE_SYSBOX=1) on the engine"
    $initCmd = "cd '$repo' && HUDDLE_SYSBOX=1 HUDDLE_IMAGE=$Image HUDDLE_NO_PULL=1 HUDDLE_PORT=$Port node cli/dist/index.js init"
    if ((Invoke-Engine -Command $initCmd) -ne 0) { Write-Bad "'huddle init' failed on the engine"; return $false }

    # The gateway logs live on the engine, not in this terminal. Wait for it to
    # actually answer, then show the tail - otherwise a container that dies in
    # its first seconds looks like "it started and then nothing happened".
    Write-Step "waiting for the gateway to come up"
    $up = $false
    foreach ($i in 1..30) {
        if ((Invoke-Engine -Quiet -Command "docker inspect -f '{{.State.Running}}' huddle 2>/dev/null | grep -q true") -eq 0) { $up = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $up) {
        Write-Bad "the huddle container is not running. Last output:"
        Invoke-Engine -Command 'docker ps -a --filter name=huddle --format "{{.Names}} {{.Status}}"; echo "--- logs ---"; docker logs --tail 40 huddle 2>&1' | Out-Null
        return $false
    }
    Write-Step "gateway log (last lines)"
    Invoke-Engine -Command 'docker logs --tail 15 huddle 2>&1' | Out-Null
    Write-Ok "Huddle running in Sysbox mode - portal: http://localhost:$Port"
    Write-Host "  (the gateway logs '[api] listening on 127.0.0.1:3000' - that is the port INSIDE" -ForegroundColor DarkGray
    Write-Host "   the container; it is published on the host as $Port)" -ForegroundColor DarkGray
    Write-Host "  Follow the log:  wsl -d $ENGINE_DISTRO -- docker logs -f huddle" -ForegroundColor DarkGray
    Write-Host "  Container state: wsl -d $ENGINE_DISTRO -- docker ps -a" -ForegroundColor DarkGray
    Write-Host "  Devcontainers live on the engine's docker daemon. To attach an IDE:" -ForegroundColor DarkGray
    Write-Host "    VS Code : Remote-WSL into '$ENGINE_DISTRO', then 'Dev Containers: Attach to Running Container'" -ForegroundColor DarkGray
    Write-Host "    JetBrains: Gateway -> Docker server -> WSL/SSH pointing at '$ENGINE_DISTRO'" -ForegroundColor DarkGray
    return $true
}


# Everything needed to explain a gateway that will not stay up, in one paste.
function Get-EngineDiagnostics {
    if (-not (Test-HuddleEngine)) { Write-Bad "distro '$ENGINE_DISTRO' does not exist"; return $false }
    $script = @(
        'echo "== distro ==" ; uname -r ; uptime ; echo "pid1=$(ps -p 1 -o comm=)"',
        'echo "== wsl.conf ==" ; cat -A /etc/wsl.conf 2>/dev/null | head -20',
        'echo "== docker ==" ; docker version --format "client={{.Client.Version}} server={{.Server.Version}}" 2>&1 ; systemctl is-active docker',
        'echo "== runtimes ==" ; docker info 2>/dev/null | grep -iA2 runtime | head -10',
        'echo "== containers ==" ; docker ps -a --format "{{.Names}} | {{.Status}} | {{.Image}}"',
        'echo "== huddle inspect ==" ; docker inspect huddle --format "state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}} restarts={{.RestartCount}} policy={{.HostConfig.RestartPolicy.Name}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}" 2>&1',
        'echo "== huddle logs (tail 50) ==" ; docker logs --tail 50 huddle 2>&1',
        'echo "== dockerd journal (tail 30) ==" ; journalctl -u docker --no-pager -n 30 2>&1 | tail -30',
        'echo "== sysbox units ==" ; systemctl is-active sysbox sysbox-mgr sysbox-fs 2>&1 | tr "\n" " " ; echo',
        'echo "== sysbox-fs journal (tail 30) ==" ; journalctl -u sysbox-fs --no-pager -n 30 2>&1 | tail -30',
        'echo "== sysbox-mgr journal (tail 30) ==" ; journalctl -u sysbox-mgr --no-pager -n 30 2>&1 | tail -30',
        'echo "== sysbox smoke ==" ; docker run --rm --runtime=sysbox-runc alpine sh -c "head -1 /proc/self/uid_map" 2>&1 | tail -3',
        'echo "== kernel (oom?) ==" ; dmesg 2>/dev/null | tail -15',
        'echo "== apparmor / fuse (sysbox-fs needs fusermount3) ==" ; aa-enabled 2>&1 | head -1 ; ls /sys/module/apparmor/parameters/enabled >/dev/null 2>&1 && cat /sys/module/apparmor/parameters/enabled ; which fusermount fusermount3 2>&1 ; ls -l /etc/apparmor.d/ 2>/dev/null | grep -i fuse ; sysctl kernel.apparmor_restrict_unprivileged_userns 2>&1 | head -1',
        'echo "== port 3000 ==" ; ss -tlnp 2>/dev/null | grep -E ":3000|:80 " ; echo "(empty = nothing listening)"',
        'echo "== memory ==" ; free -m | head -2'
    ) -join ' ; '
    Invoke-Engine -Command $script | Out-Null
    return $true
}



# Bring everything back after the distro (or Windows) restarted, without a
# full re-init: boot the distro, keepalive, dockerd, then the gateway itself.
function Start-EngineStack {
    if (-not (Test-HuddleEngine)) { Write-Bad "distro '$ENGINE_DISTRO' does not exist - run -Setup"; return $false }
    Write-Step "starting the engine stack"
    Invoke-Engine -Quiet -Command 'true' | Out-Null      # boots the distro if it is down
    Start-EngineKeepalive | Out-Null
    if ((Invoke-Engine -Quiet -Command 'systemctl is-active --quiet docker') -ne 0) {
        Invoke-Engine -Quiet -Command 'systemctl start docker' | Out-Null
        foreach ($i in 1..15) {
            Start-Sleep -Seconds 1
            if ((Invoke-Engine -Quiet -Command 'docker info >/dev/null 2>&1') -eq 0) { break }
        }
    }
    if ((Invoke-Engine -Quiet -Command 'docker info >/dev/null 2>&1') -ne 0) { Write-Bad "dockerd is not responding on the engine"; return $false }
    Write-Ok "dockerd up"

    if ((Invoke-Engine -Quiet -Command 'docker inspect huddle >/dev/null 2>&1') -ne 0) {
        Write-Bad "no huddle container on the engine - run .\huddle.ps1 and pick 4 to init"
        return $false
    }
    Invoke-Engine -Quiet -Command 'docker start huddle >/dev/null 2>&1; true' | Out-Null
    foreach ($i in 1..20) {
        Start-Sleep -Seconds 1
        if ((Invoke-Engine -Quiet -Command "docker inspect -f '{{.State.Running}}' huddle | grep -q true") -eq 0) {
            Write-Ok "huddle is running"
            Invoke-Engine -Command 'docker ps --format "  {{.Names}}  {{.Status}}"' | Out-Null
            return $true
        }
    }
    Write-Bad "huddle did not come up. Last log:"
    Invoke-Engine -Command 'docker logs --tail 30 huddle 2>&1' | Out-Null
    return $false
}

# VS Code / JetBrains attach helpers. The devcontainers live on the ENGINE's
# docker daemon, so an IDE running on Windows (talking to Docker Desktop) sees
# nothing. VS Code must run INSIDE the distro (Remote-WSL); its server then uses
# the engine's docker.
function Open-EngineInVsCode {
    param([string]$Folder = '/root')
    if (-not (Test-HuddleEngine)) { Write-Bad "distro '$ENGINE_DISTRO' does not exist"; return $false }
    $code = Get-Command code -ErrorAction SilentlyContinue
    if (-not $code) { Write-Bad "'code' not on PATH - open VS Code and use 'WSL: Connect to WSL using Distro...' -> $ENGINE_DISTRO"; return $false }
    Write-Step "opening VS Code in '$ENGINE_DISTRO'"
    & code --remote "wsl+$ENGINE_DISTRO" $Folder
    Write-Ok "VS Code opening. Then: F1 -> 'Dev Containers: Attach to Running Container'"
    Write-Host "  The container list now comes from the engine daemon, not Docker Desktop." -ForegroundColor DarkGray
    return $true
}

function Show-AttachHelp {
    Write-Step "attaching an IDE to a devcontainer on '$ENGINE_DISTRO'"
    Invoke-Engine -Command 'docker ps --format "  {{.Names}}  ({{.Status}})"' | Out-Null
    Write-Host ""
    Write-Host "  VS Code:" -ForegroundColor White
    Write-Host "    .\huddle-engine.ps1 -Code        (or: F1 -> WSL: Connect to WSL using Distro -> $ENGINE_DISTRO)" -ForegroundColor DarkGray
    Write-Host "    then F1 -> Dev Containers: Attach to Running Container" -ForegroundColor DarkGray
    Write-Host "  JetBrains Gateway:" -ForegroundColor White
    Write-Host "    Gateway -> Dev Containers -> '...' -> add a Docker server on WSL ($ENGINE_DISTRO)" -ForegroundColor DarkGray
    Write-Host "  Why: the IDE on Windows talks to Docker Desktop; these containers live on the engine." -ForegroundColor DarkGray
}

# Standalone entry points. Strict mode only applies when this script is RUN,
# not when huddle.ps1 dot-sources it.
if ($Setup -or $Check -or $Shell -or $Diagnose -or $Code -or $Attach -or $Up) { $ErrorActionPreference = 'Stop' }
if ($Setup) { if (Initialize-HuddleEngine -RepoRoot $PSScriptRoot) { exit 0 } else { exit 1 } }
if ($Check) { if (Test-EngineReady) { exit 0 } else { exit 1 } }
if ($Shell) { & wsl.exe -d $ENGINE_DISTRO; exit $LASTEXITCODE }
if ($Diagnose) { if (Get-EngineDiagnostics) { exit 0 } else { exit 1 } }
if ($Code)     { if (Open-EngineInVsCode) { exit 0 } else { exit 1 } }
if ($Attach)   { Show-AttachHelp; exit 0 }
if ($Up)       { if (Start-EngineStack) { exit 0 } else { exit 1 } }
