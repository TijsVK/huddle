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
    [switch]$Up,
    [switch]$Keepalive,
    [switch]$VsCode,
    [switch]$Apply,
    [switch]$IsolatePath
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
    # --cd / on EVERY call: wsl translates the caller's Windows directory and
    # enters it as the target user. After switching the default user away from
    # root that fails with "chdir(2) failed.: Permission denied" for anything
    # started from a Windows path, which breaks every engine command.
    if ($Quiet) {
        & wsl.exe -d $ENGINE_DISTRO @userArgs --cd / -- bash -lc $wrapped *> $null
    } else {
        # NO 2>&1: merging stderr into the pipeline turns every stderr line into
        # an ErrorRecord, so ordinary progress output (docker/buildkit writes its
        # progress to stderr) is rendered as a NativeCommandError. Out-Host keeps
        # stdout out of the return value.
        & wsl.exe -d $ENGINE_DISTRO @userArgs --cd / -- bash -lc $wrapped | Out-Host
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
    # Preserve the [user] default line if the installer already set one - rewriting
    # wsl.conf wholesale would silently put every session back to root.
    # Single-quoted PowerShell string: the payload is bash and must not be touched.
    $cmd = 'u=$(sed -n "s/^default=//p" /etc/wsl.conf 2>/dev/null | head -1); ' +
           'printf "%s\n" "[boot]" "systemd=true" "" "[interop]" "enabled=true" "appendWindowsPath=true" > /etc/wsl.conf; ' +
           'if [ -n "$u" ]; then printf "%s\n" "" "[user]" "default=$u" >> /etc/wsl.conf; ' +
           'printf "%s\n" "" "[automount]" "enabled=true" "options=metadata,uid=$(id -u $u),gid=$(id -g $u),umask=022" >> /etc/wsl.conf; fi; ' +
           'sed -i "s/\r$//" /etc/wsl.conf; true'
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

function Test-EngineKeepalive {
    return ((Invoke-Engine -Quiet -Command 'pgrep -f huddle-engine-keepalive >/dev/null 2>&1') -eq 0)
}

function Start-EngineKeepalive {
    param([switch]$Verbose2)
    $marker = 'huddle-engine-keepalive'
    $launcher = '/usr/local/bin/huddle-keepalive'
    if (Test-EngineKeepalive) { Write-Ok "keepalive already running (distro stays up)"; return $true }

    # 1. the launcher itself (space-free path, so Start-Process cannot split it)
    $installer = 'printf "%s\n" "#!/bin/bash" "exec -a ' + $marker + ' sleep infinity" > ' + $launcher + ' && chmod +x ' + $launcher
    Invoke-Engine -Quiet -Command $installer | Out-Null
    if ((Invoke-Engine -Quiet -Command "test -x $launcher") -ne 0) {
        Write-Bad "could not install $launcher on the engine"
        Invoke-Engine -Command "ls -l $launcher 2>&1; id; mount | grep -c ' / '" | Out-Null
        return $false
    }
    if ($Verbose2) { Write-Host "  launcher installed: $launcher" -ForegroundColor DarkGray }

    # 2. attempt A - Start-Process (detached, hidden)
    $out = Join-Path $env:TEMP 'huddle-keepalive.out'
    $err = Join-Path $env:TEMP 'huddle-keepalive.err'
    $proc = $null
    try {
        $proc = Start-Process -FilePath 'wsl.exe' `
            -ArgumentList @('-d', $ENGINE_DISTRO, '-u', 'root', '--cd', '/', '--', $launcher) `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    } catch {
        Write-Host "  [i] Start-Process failed: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 2
    if ($proc -and $proc.HasExited) {
        Write-Host "  [i] wsl.exe exited immediately (exit $($proc.ExitCode))" -ForegroundColor DarkGray
        foreach ($f in @($out, $err)) {
            if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) {
                Write-Host "      $(Split-Path $f -Leaf): $((Get-Content $f -Raw).Trim())" -ForegroundColor DarkGray
            }
        }
    }
    foreach ($i in 1..8) {
        if (Test-EngineKeepalive) { Write-Ok "keepalive started (Start-Process) - '$ENGINE_DISTRO' stays up"; return $true }
        Start-Sleep -Seconds 1
    }

    # 3. attempt B - cmd's own detacher, in case Start-Process/PowerShell reaps it
    Write-Host "  [i] retrying via 'cmd /c start /b'" -ForegroundColor DarkGray
    & cmd.exe /c "start `"huddle-keepalive`" /b wsl.exe -d $ENGINE_DISTRO -u root --cd / -- $launcher" | Out-Null
    foreach ($i in 1..8) {
        if (Test-EngineKeepalive) { Write-Ok "keepalive started (cmd start /b) - '$ENGINE_DISTRO' stays up"; return $true }
        Start-Sleep -Seconds 1
    }

    # 4. give up with facts, not a shrug
    Write-Host "  [i] no keepalive process could be held open." -ForegroundColor DarkGray
    Invoke-Engine -Command "echo 'launcher:'; ls -l $launcher; echo 'processes:'; pgrep -af sleep || echo '(no sleep processes)'; echo 'distro uptime:'; cat /proc/uptime" | Out-Null
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
        'echo "== keepalive ==" ; pgrep -af huddle-engine-keepalive || echo "NOT RUNNING - the distro will be torn down between commands" ; ls -l /usr/local/bin/huddle-keepalive 2>&1',
        'echo "== distro uptime (resets on every distro restart) ==" ; cat /proc/uptime',
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




# Let the STOCK VS Code on Windows attach to devcontainers that live on the engine.
# The Dev Containers extension shells out to a docker CLI; point it at a shim that
# forwards to the engine's daemon over wsl.exe. No TCP socket, no sshd, no
# Remote-WSL window needed.

function Set-VsCodeDockerShim {
    param([switch]$Apply)
    $shim = Join-Path $PSScriptRoot 'scripts\huddle-docker.cmd'
    if (-not (Test-Path $shim)) { Write-Bad "shim not found at $shim"; return $false }
    Write-Step "VS Code docker shim"
    Write-Host "  shim: $shim" -ForegroundColor DarkGray

    # Run the exact probes the Dev Containers extension runs, and check them the
    # way it does. 'docker returned an error / make sure the docker daemon is
    # running' usually means stray text (a wsl.exe warning) landed in stdout where
    # the extension expects pure JSON.
    # The template must stay ONE argument: unquoted, cmd splits it at the space and
    # docker reports "'docker version' accepts no arguments".
    $probe = & cmd.exe /c "`"$shim`" version --format `"{{json .}}`"" 2>&1
    $probeText = ($probe | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "the shim could not reach the engine (exit $LASTEXITCODE):"
        Write-Host "    $probeText" -ForegroundColor DarkGray
        return $false
    }
    if (-not $probeText.StartsWith('{')) {
        Write-Bad "the shim returned non-JSON output - this is what breaks the extension:"
        $probeText -split "`n" | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host "  Anything printed before the JSON (wsl warnings, motd, shell rc output) must go." -ForegroundColor Yellow
        return $false
    }
    try {
        $ver = $probeText | ConvertFrom-Json
        Write-Ok "shim speaks docker: server $($ver.Server.Version), client $($ver.Client.Version)"
    } catch {
        Write-Bad "the shim's JSON did not parse: $($_.Exception.Message)"
        Write-Host "    $probeText" -ForegroundColor DarkGray
        return $false
    }
    # Which docker does the distro actually resolve? With appendWindowsPath=true a
    # Windows CLI (Rancher Desktop, Docker Desktop) can shadow /usr/bin/docker and
    # silently point at the wrong daemon - and it is also what makes VS Code in a
    # WSL window offer to "install Docker in WSL".
    $which = (Invoke-Engine -Quiet -Command 'which -a docker > /tmp/hd-which 2>&1') | Out-Null
    $whichOut = & cmd.exe /c "wsl.exe -d $ENGINE_DISTRO --cd / -- cat /tmp/hd-which" 2>&1
    $whichText = ($whichOut | Out-String).Trim()
    if ($whichText -match '/mnt/[a-z]/') {
        Write-Host "  [!] the distro's PATH also resolves a Windows docker:" -ForegroundColor Yellow
        $whichText -split "`n" | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        Write-Host "      The shim calls /usr/bin/docker explicitly, so it is unaffected." -ForegroundColor DarkGray
        Write-Host "      A VS Code window running INSIDE the distro can pick that one instead. Fix with either:" -ForegroundColor Yellow
        Write-Host "        rdctl api /v1/settings -X PUT -b '{\"WSL\":{\"integrations\":{\"$ENGINE_DISTRO\":false}}}'" -ForegroundColor Yellow
        Write-Host "          (the 'rdctl set --WSL.integrations.<distro>' flag only exists in some versions)" -ForegroundColor DarkGray
        Write-Host "        .\huddle-engine.ps1 -IsolatePath                       (drop the Windows PATH entirely)" -ForegroundColor Yellow
    }
    $names = & cmd.exe /c "`"$shim`" ps --format `"{{.Names}}`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "'docker ps' through the shim failed:"
        Write-Host "    $(($names | Out-String).Trim())" -ForegroundColor DarkGray
        return $false
    }
    Write-Ok "shim reaches the engine (containers: $((($names | Where-Object { $_ }) -join ', ')))"
    $ms = (Measure-Command { & cmd.exe /c "`"$shim`" version --format `"{{.Server.Version}}`"" | Out-Null }).TotalMilliseconds
    Write-Host ("  one docker call through the shim: {0:N0} ms" -f $ms) -ForegroundColor DarkGray
    if ($ms -gt 2500) {
        Write-Host "  That is slow for a single call; the Dev Containers extension makes many." -ForegroundColor Yellow
    }

    $settings = Join-Path $env:APPDATA 'Code\User\settings.json'
    # JSON needs each backslash doubled. Plain .NET Replace - a -replace regex here
    # is how the printed value ended up with four backslashes.
    $escaped = $shim.Replace('\', '\\')
    $line = '"dev.containers.dockerPath": "' + $escaped + '"'
    Write-Host ""
    Write-Host "  Setting for VS Code settings.json ($settings):" -ForegroundColor White
    Write-Host "      $line" -ForegroundColor Yellow
    Write-Host "  Then: F1 -> Developer: Reload Window, and F1 -> Dev Containers: Attach to Running Container" -ForegroundColor DarkGray
    Write-Host "  (Undo later by removing that setting; Docker Desktop is untouched.)" -ForegroundColor DarkGray

    if (-not $Apply) {
        Write-Host ""
        Write-Host "  Re-run with -Apply to write that setting automatically." -ForegroundColor DarkGray
        return $true
    }
    if (-not (Test-Path $settings)) { Write-Bad "settings.json not found at $settings - add the line manually"; return $false }

    # Edit as TEXT, not via ConvertFrom-Json: VS Code settings are JSONC (comments,
    # trailing commas), which the JSON parser rejects ("Invalid JSON primitive"),
    # and a re-serialise would strip the user's comments and ordering anyway.
    try {
        $raw = Get-Content $settings -Raw
        Copy-Item $settings "$settings.huddle-backup" -Force
        $pattern = '"dev\.containers\.dockerPath"\s*:\s*"(?:[^"\\]|\\.)*"'
        if ([regex]::IsMatch($raw, $pattern)) {
            $new = [regex]::Replace($raw, $pattern, { param($m) $line })
            $what = 'updated existing setting'
        } else {
            $idx = $raw.IndexOf('{')
            if ($idx -lt 0) { Write-Bad "settings.json has no JSON object - add the line manually"; return $false }
            $new = $raw.Insert($idx + 1, "`r`n    $line,")
            $what = 'added setting'
        }
        Set-Content -Path $settings -Value $new -Encoding UTF8
        Write-Ok "$what in settings.json (backup: $settings.huddle-backup)"
        Write-Host "  Reload the VS Code window, then attach." -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Bad "could not edit settings.json ($($_.Exception.Message)) - add the line manually"
        return $false
    }
}


# Cut the Windows PATH out of the engine distro. Another Windows docker CLI on
# that PATH (Rancher Desktop, Docker Desktop) is what makes a VS Code window
# running INSIDE the distro talk to the wrong daemon - and Rancher's GUI does not
# always offer a per-distro integration toggle.
#
# Cost: `code`, `docker.exe` and other Windows binaries are no longer callable
# from inside the distro. The Windows-side flow does not need them: -Code launches
# VS Code from Windows (code --remote wsl+<distro>), and the shim calls
# /usr/bin/docker by absolute path.
function Disable-EngineWindowsPath {
    if (-not (Test-HuddleEngine)) { Write-Bad "distro '$ENGINE_DISTRO' does not exist"; return $false }
    Write-Step "removing the Windows PATH from '$ENGINE_DISTRO'"
    $cmd = 'u=$(sed -n "s/^default=//p" /etc/wsl.conf 2>/dev/null | head -1); ' +
           'printf "%s\n" "[boot]" "systemd=true" "" "[interop]" "enabled=true" "appendWindowsPath=false" > /etc/wsl.conf; ' +
           'if [ -n "$u" ]; then printf "%s\n" "" "[user]" "default=$u" >> /etc/wsl.conf; ' +
           'printf "%s\n" "" "[automount]" "enabled=true" "options=metadata,uid=$(id -u $u),gid=$(id -g $u),umask=022" >> /etc/wsl.conf; fi; ' +
           'sed -i "s/\r$//" /etc/wsl.conf; true'
    if ((Invoke-Engine -Command $cmd) -ne 0) { Write-Bad "could not write /etc/wsl.conf"; return $false }
    & wsl.exe --terminate $ENGINE_DISTRO | Out-Null
    Write-Ok "done - restart the stack with: .\huddle-engine.ps1 -Up"
    Write-Host "  Verify afterwards:  wsl -d $ENGINE_DISTRO -- which -a docker   (only /usr/bin/docker)" -ForegroundColor DarkGray
    Write-Host "  If Rancher Desktop still injects itself, disable its integration for this distro:" -ForegroundColor DarkGray
    Write-Host "      rdctl api /v1/settings -X PUT -b '{\"WSL\":{\"integrations\":{\"$ENGINE_DISTRO\":false}}}'" -ForegroundColor DarkGray
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
    Write-Host "  If VS Code offers to 'install Docker in WSL' (or points at Rancher), set this in the" -ForegroundColor Yellow
    Write-Host "  Remote [WSL] settings scope so it uses the engine's own CLI:" -ForegroundColor Yellow
    Write-Host "      `"dev.containers.dockerPath`": `"/usr/bin/docker`"" -ForegroundColor Yellow
    Write-Host "  The container list now comes from the engine daemon, not Docker Desktop." -ForegroundColor DarkGray
    return $true
}

function Show-AttachHelp {
    Write-Step "what an IDE can attach to on '$ENGINE_DISTRO'"
    $running = Invoke-Engine -Quiet -Command "docker ps --format '{{.Names}}' | grep -v '^huddle$' | grep -q ."
    Invoke-Engine -Command 'echo "  running:"; docker ps --format "    {{.Names}}  ({{.Status}})"; echo "  not running:"; docker ps -a --filter status=exited --filter status=created --format "    {{.Names}}  ({{.Status}})"' | Out-Null
    Write-Host ""
    if ($running -ne 0) {
        Write-Bad "no devcontainer is RUNNING - that is why the attach list is empty."
        Write-Host "  VS Code can only attach to running containers. Start one from the portal," -ForegroundColor Yellow
        Write-Host "  and if it exits immediately check:  .\huddle-engine.ps1 -Diagnose" -ForegroundColor Yellow
        Write-Host ""
    }
    Write-Host "  VS Code:" -ForegroundColor White
    Write-Host "    .\huddle-engine.ps1 -Code    (or F1 -> WSL: Connect to WSL using Distro -> $ENGINE_DISTRO)" -ForegroundColor DarkGray
    Write-Host "    then F1 -> Dev Containers: Attach to Running Container" -ForegroundColor DarkGray
    Write-Host "    The window must say 'WSL: $ENGINE_DISTRO' bottom-left; a plain Windows window" -ForegroundColor DarkGray
    Write-Host "    talks to Docker Desktop and will always be empty." -ForegroundColor DarkGray
    Write-Host "  JetBrains Gateway:" -ForegroundColor White
    Write-Host "    Gateway -> Dev Containers -> '...' -> Docker server on WSL ($ENGINE_DISTRO)" -ForegroundColor DarkGray
    Write-Host "  Docker access for the user VS Code runs as:" -ForegroundColor White
    Invoke-Engine -AsUser -Command 'echo "    user=$(whoami)"; docker ps >/dev/null 2>&1 && echo "    docker access: OK" || echo "    docker access: DENIED - run: sudo usermod -aG docker $(whoami), then reopen the WSL session"' | Out-Null
}

# Standalone entry points. Strict mode only applies when this script is RUN,
# not when huddle.ps1 dot-sources it.
if ($Setup -or $Check -or $Shell -or $Diagnose -or $Code -or $Attach -or $Up -or $Keepalive -or $VsCode -or $IsolatePath) { $ErrorActionPreference = 'Stop' }
if ($Setup) { if (Initialize-HuddleEngine -RepoRoot $PSScriptRoot) { exit 0 } else { exit 1 } }
if ($Check) { if (Test-EngineReady) { exit 0 } else { exit 1 } }
if ($Shell) { & wsl.exe -d $ENGINE_DISTRO --cd ~; exit $LASTEXITCODE }
if ($Diagnose) { if (Get-EngineDiagnostics) { exit 0 } else { exit 1 } }
if ($Code)     { if (Open-EngineInVsCode) { exit 0 } else { exit 1 } }
if ($Attach)   { Show-AttachHelp; exit 0 }
if ($VsCode)   { if (Set-VsCodeDockerShim -Apply:$Apply) { exit 0 } else { exit 1 } }
if ($IsolatePath) { if (Disable-EngineWindowsPath) { exit 0 } else { exit 1 } }
if ($Up)       { if (Start-EngineStack) { exit 0 } else { exit 1 } }
if ($Keepalive) {
    if (Start-EngineKeepalive -Verbose2) {
        Invoke-Engine -Command 'pgrep -af huddle-engine-keepalive' | Out-Null
        exit 0
    }
    Write-Bad "keepalive could not be started - without it WSL tears the distro down between commands"
    Write-Host "  Workarounds:" -ForegroundColor Yellow
    Write-Host "    1. keep one shell open:  wsl -d $ENGINE_DISTRO" -ForegroundColor Yellow
    Write-Host "    2. stop WSL idling the VM: add to %USERPROFILE%\.wslconfig" -ForegroundColor Yellow
    Write-Host "         [wsl2]" -ForegroundColor Yellow
    Write-Host "         vmIdleTimeout=315360000000   # ~10 years in ms (-1 is not accepted everywhere)" -ForegroundColor Yellow
    Write-Host "       then: wsl --shutdown  (and start Huddle again)" -ForegroundColor Yellow
    exit 1
}
