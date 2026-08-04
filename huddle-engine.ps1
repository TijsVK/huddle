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
    [switch]$Shell
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
    # Out-Host (or $null) keeps the command's OUTPUT out of the pipeline: this
    # function must return only the exit code. Without it the caller gets an
    # array of every printed line plus the code, and `-ne 0` is then always true.
    if ($Quiet) {
        & wsl.exe -d $ENGINE_DISTRO @userArgs -- bash -lc $Command *> $null
    } else {
        # NO 2>&1 here: merging stderr into the pipeline turns every stderr line
        # into an ErrorRecord, so ordinary progress output (docker/buildkit writes
        # its progress to stderr) is rendered as a NativeCommandError with a
        # "At line:.. char:.." banner. Unredirected stderr goes straight to the
        # console instead. Out-Host keeps stdout out of the return value.
        & wsl.exe -d $ENGINE_DISTRO @userArgs -- bash -lc $Command | Out-Host
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
    # Only rewrite + restart when the config is actually wrong: terminating the
    # distro kills the running gateway and every devcontainer, and menu option 6
    # is also used as a plain "check my engine" action.
    $needed = 'systemd=true'
    if ((Invoke-Engine -Quiet -Command 'grep -q "^systemd=true" /etc/wsl.conf 2>/dev/null') -eq 0) {
        Write-Ok "systemd already enabled in '$ENGINE_DISTRO' (left running)"
        return $true
    }
    Write-Step "enabling systemd in '$ENGINE_DISTRO' (Sysbox ships systemd units)"
    # One-liner with printf instead of a here-doc: this .ps1 is checked out with
    # CRLF on Windows, and a here-doc's terminator line would carry a \r (so bash
    # never sees 'CONF') while every written line would keep its \r (so wsl fails
    # with "Expected '=' in /etc/wsl.conf"). printf %s\n takes each line as an
    # argument, so no embedded newlines exist to be mangled.
    $cmd = "printf '%s\n' '[boot]' 'systemd=true' '' '[interop]' 'enabled=true' 'appendWindowsPath=false' > /etc/wsl.conf && sed -i 's/\r$//' /etc/wsl.conf"
    if ((Invoke-Engine -Command $cmd) -ne 0) { Write-Bad "could not write /etc/wsl.conf"; return $false }
    & wsl.exe --terminate $ENGINE_DISTRO | Out-Null
    Write-Ok "systemd enabled (distro terminated so it restarts with systemd)"
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
    return (Test-EngineReady)
}

# Start Huddle ON the engine host, in Sysbox mode. Everything (gateway image
# build, `huddle init`, devcontainers) runs inside the distro; the portal is
# reachable from Windows on localhost via WSL's port forwarding.
function Start-HuddleOnEngine {
    param(
        [string]$RepoRoot = $PSScriptRoot,
        [int]$Port = 3000,
        [string]$Image = 'huddle',
        [switch]$SkipBuild
    )
    if (-not (Test-EngineReady)) { return $false }
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

    Write-Step "huddle init (HUDDLE_SYSBOX=1) on the engine"
    $initCmd = "cd '$repo' && HUDDLE_SYSBOX=1 HUDDLE_IMAGE=$Image HUDDLE_NO_PULL=1 HUDDLE_PORT=$Port node cli/dist/index.js init"
    if ((Invoke-Engine -Command $initCmd) -ne 0) { Write-Bad "'huddle init' failed on the engine"; return $false }

    Write-Ok "Huddle running in Sysbox mode - portal: http://localhost:$Port"
    Write-Host "  Devcontainers live on the engine's docker daemon. To attach an IDE:" -ForegroundColor DarkGray
    Write-Host "    VS Code : Remote-WSL into '$ENGINE_DISTRO', then 'Dev Containers: Attach to Running Container'" -ForegroundColor DarkGray
    Write-Host "    JetBrains: Gateway -> Docker server -> WSL/SSH pointing at '$ENGINE_DISTRO'" -ForegroundColor DarkGray
    return $true
}

# Standalone entry points. Strict mode only applies when this script is RUN,
# not when huddle.ps1 dot-sources it.
if ($Setup -or $Check -or $Shell) { $ErrorActionPreference = 'Stop' }
if ($Setup) { if (Initialize-HuddleEngine -RepoRoot $PSScriptRoot) { exit 0 } else { exit 1 } }
if ($Check) { if (Test-EngineReady) { exit 0 } else { exit 1 } }
if ($Shell) { & wsl.exe -d $ENGINE_DISTRO; exit $LASTEXITCODE }
