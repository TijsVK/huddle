# ──────────────────────────────────────────────────────────────────────────────
#  Huddle CLI  --  DMZ Devcontainer Manager
# ──────────────────────────────────────────────────────────────────────────────

$HUDDLE_CONTAINER = "huddle"
$HUDDLE_IMAGE     = if ($env:HUDDLE_IMAGE) { $env:HUDDLE_IMAGE } else { "huddle" }
# Port: overridable with $env:HUDDLE_PORT (was hard-coded, so setting the env var
# did nothing - and Initialize-Huddle even overwrote it with the hard-coded value).
$HUDDLE_PORT      = if ($env:HUDDLE_PORT) { [int]$env:HUDDLE_PORT } else { 3000 }

# Sysbox-modus (experiment): elke devcontainer draait onder sysbox-runc met een
# EIGEN dockerd erin — geen socket-proxy, geen dind-sidecar, geen authz-plugin.
# Op Windows kan dat niet op de Docker Desktop-VM: sysbox moet op de docker-HOST
# geinstalleerd worden, dus Huddle krijgt zijn eigen WSL2-distro als engine host.
# Zet HUDDLE_SYSBOX=1 (env) of kies menu-optie 6.
$SYSBOX_MODE = ($env:HUDDLE_SYSBOX -eq '1')
$engineHelper = Join-Path $PSScriptRoot 'huddle-engine.ps1'
if (Test-Path $engineHelper) { . $engineHelper }

# Per-IDE base images. Elke IDE heeft een eigen base-devimage-<ide>/ folder met
# een Dockerfile en draagt LABEL com.devcontainer.ide=<ide>. Snapshots inheriten
# datzelfde label zodat de spawn-flow ze per IDE kan filteren.
$IDE_DEFS = @(
    [PSCustomObject]@{ Key = 'rider';    Display = 'Rider';    Backend = 'Rider';    Image = 'ghcr.io/infosupport/base-devimage-rider';    Folder = 'base-devimage-rider' }
    [PSCustomObject]@{ Key = 'intellij'; Display = 'IntelliJ'; Backend = 'IntelliJ'; Image = 'ghcr.io/infosupport/base-devimage-intellij'; Folder = 'base-devimage-intellij' }
    # VS Code installeert zijn eigen backend (VS Code Server) in de container bij
    # het attachen — er hoeft dus geen IDE-distro gedownload te worden zoals bij JB.
    [PSCustomObject]@{ Key = 'vscode';   Display = 'VS Code';  Backend = 'VSCode';   Image = 'ghcr.io/infosupport/base-devimage-vscode';   Folder = 'base-devimage-vscode' }
)

$TempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR.TrimEnd('/') } else { '/tmp' }

# ── Container runtime (Docker of Podman) ──────────────────────────────────────

# Spiegelt cli/src/runtime.ts: 'info' slaagt alleen als de daemon/machine ook
# echt bereikbaar is.
function Test-Runtime {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { return $false }
    & $Name info *>$null 2>&1
    return ($LASTEXITCODE -eq 0)
}

# Bepaalt de ECHTE engine achter een commando, of $null als die niet bereikbaar
# is. Vertrouw niet op de commandonaam: `docker` is vaak een symlink/shim naar
# Podman (podman-docker) en Podman emuleert dan zelfs `docker --version`.
# Podman's `info` kent wél het veld Host.ServiceIsRemote; Docker's schema niet.
function Get-TrueEngine {
    param([string]$Command)
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { return $null }
    $probe = & $Command info --format '{{.Host.ServiceIsRemote}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $probe) { return 'podman' }
    & $Command info *>$null 2>&1
    if ($LASTEXITCODE -eq 0) { return 'docker' }
    return $null
}

# Bepaalt de te gebruiken runtime: expliciete keuze (HUDDLE_RUNTIME) wint, anders
# automatisch — eerst achter `docker` kijken (kan een Podman-shim zijn), dan
# `podman`. Zelfde logica als de CLI, zodat het script en de gedelegeerde
# `huddle init` dezelfde engine kiezen.
function Resolve-Runtime {
    $explicit = $env:HUDDLE_RUNTIME
    if ($explicit) {
        $name = $explicit.Trim().ToLower()
        if ($name -ne 'docker' -and $name -ne 'podman') {
            Write-Host "  [FAIL] Onbekende HUDDLE_RUNTIME '$explicit' -- kies docker of podman." -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Runtime $name)) {
            Write-Host "  [FAIL] Container runtime '$name' is niet beschikbaar. Draait de daemon/machine?" -ForegroundColor Red
            exit 1
        }
        return $name
    }
    $engine = Get-TrueEngine 'docker'
    if (-not $engine) { $engine = Get-TrueEngine 'podman' }
    if ($engine) { return $engine }
    Write-Host "  [FAIL] Geen werkende container runtime gevonden. Installeer en start Docker of Podman," -ForegroundColor Red
    Write-Host "         of kies er expliciet een met de env-var HUDDLE_RUNTIME=<docker|podman>." -ForegroundColor Red
    exit 1
}

$RUNTIME = Resolve-Runtime
# Geef de gekozen engine door aan `huddle init` (en verdere CLI-calls) zodat die
# exact dezelfde runtime gebruikt als waarmee dit script images bouwt/inspecteert.
$env:HUDDLE_RUNTIME = $RUNTIME

function Write-Banner {
    Clear-Host
#     Write-Host ""
#     Write-Host "  ██╗  ██╗██╗   ██╗██████╗ ██████╗ ██╗     ███████╗" -ForegroundColor Cyan
#     Write-Host "  ██║  ██║██║   ██║██╔══██╗██╔══██╗██║     ██╔════╝" -ForegroundColor Cyan
#     Write-Host "  ███████║██║   ██║██║  ██║██║  ██║██║     █████╗  " -ForegroundColor Cyan
#     Write-Host "  ██╔══██║██║   ██║██║  ██║██║  ██║██║     ██╔══╝  " -ForegroundColor Cyan
#     Write-Host "  ██║  ██║╚██████╔╝██████╔╝██████╔╝███████╗███████╗" -ForegroundColor Cyan
#     Write-Host "  ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚══════╝" -ForegroundColor Cyan
#     Write-Host ""
    Write-Host "  DMZ Portal  --  Secure dev environments" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Status {
    # In sysbox-modus draait de gateway op de ENGINE HOST (WSL2-distro), niet op
    # de lokale docker. Deze status-regel keek altijd naar de lokale daemon en
    # meldde daarom "gestopt" terwijl Huddle prima draaide op de engine.
    if ($SYSBOX_MODE -and (Get-Command Invoke-Engine -ErrorAction SilentlyContinue)) {
        $rc = Invoke-Engine -Quiet -Command "docker ps --filter name=^${HUDDLE_CONTAINER}`$ --format '{{.Names}}' | grep -q ."
        if ($rc -eq 0) {
            Write-Host "  [ON]  Huddle draait op de engine  -->  http://localhost:${HUDDLE_PORT}" -ForegroundColor Green
            # Zonder keepalive breekt WSL de distro af zodra er geen client meer
            # hangt: dockerd en de gateway gaan mee, en bij het volgende commando
            # start alles opnieuw ("Up 1 second" bij elke refresh).
            if ((Get-Command Test-EngineKeepalive -ErrorAction SilentlyContinue) -and -not (Test-EngineKeepalive)) {
                Write-Host "  [!]   geen keepalive: WSL sloopt de distro tussen commando's door" -ForegroundColor Yellow
                Write-Host "        herstel met: .\huddle-engine.ps1 -Keepalive" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  [OFF] Huddle is gestopt (engine '$(if ($env:HUDDLE_ENGINE_DISTRO) { $env:HUDDLE_ENGINE_DISTRO } else { 'huddle-engine' })')" -ForegroundColor Red
        }
        Write-Host ""
        return
    }

    $running = & $RUNTIME ps --filter "name=^${HUDDLE_CONTAINER}$" --format "{{.Names}}"
    if ($running) {
        Write-Host "  [ON]  Huddle draait  -->  http://localhost:${HUDDLE_PORT}" -ForegroundColor Green
    } else {
        Write-Host "  [OFF] Huddle is gestopt" -ForegroundColor Red
    }
    Write-Host ""
}

function Show-Menu {
    Write-Banner
    Write-Status
    if ($SYSBOX_MODE) {
        Write-Host "   modus: SYSBOX (engine host '$(if ($env:HUDDLE_ENGINE_DISTRO) { $env:HUDDLE_ENGINE_DISTRO } else { 'huddle-engine' })')" -ForegroundColor Yellow
    }
    Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
    Write-Host "   1  Snapshot maken van draaiende container" -ForegroundColor White
    Write-Host "   2  Devcontainer starten (IDE -> standaard of snapshot)" -ForegroundColor White
    Write-Host "   3  Base image bouwen per IDE (of alle parallel)" -ForegroundColor White
    Write-Host "   4  Huddle bouwen en herinitialiseren (CLI, no-pull)" -ForegroundColor White
    Write-Host "   5  Tests draaien (unit + e2e)" -ForegroundColor White
    Write-Host "   6  Sysbox engine host opzetten/controleren (WSL2)" -ForegroundColor White
    Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
    Write-Host "   r  Status verversen (Enter doet hetzelfde)" -ForegroundColor White
    Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
    Write-Host "   0  Afsluiten" -ForegroundColor DarkGray
    Write-Host ""
}

# ── Reset-keuze bij opstarten ─────────────────────────────────────────────────

# Multiselect: welke onderdelen opnieuw gebouwd/geïnstalleerd moeten worden
# voordat we via de CLI initialiseren. Retourneert een array met een subset van
# 'huddle-image', 'devimages' en 'cli'; Enter zonder keuze = niets resetten.
function Select-ResetComponents {
    Write-Host "  Wat wil je resetten? (meerdere mogelijk, komma-gescheiden)" -ForegroundColor DarkCyan
    Write-Host "   1)  Huddle image  (gateway-image opnieuw bouwen)"
    Write-Host "   2)  Devimages     (base + per-IDE images opnieuw bouwen)"
    Write-Host "   3)  CLI           (huddle-cli opnieuw installeren vanaf ./cli)"
    Write-Host "   a)  Alles"
    Write-Host "   Enter = niets resetten, alleen initialiseren" -ForegroundColor DarkGray
    $answer = Read-Host "`n  Keuze (bv. 1,3)"

    if (-not $answer) { return @() }
    if ($answer.Trim().ToLower() -eq 'a') { return @('huddle-image', 'devimages', 'cli') }

    $selected = @()
    foreach ($part in ($answer -split ',')) {
        switch ($part.Trim()) {
            '1' { $selected += 'huddle-image' }
            '2' { $selected += 'devimages' }
            '3' { $selected += 'cli' }
            default { if ($part.Trim()) { Write-Host "  Onbekende keuze '$($part.Trim())' -- genegeerd." -ForegroundColor Yellow } }
        }
    }
    return $selected | Select-Object -Unique
}

# ── CLI installeren ───────────────────────────────────────────────────────────

# Bouwt en installeert de huddle-CLI globaal vanaf ./cli (npm run install-global
# = tsc build + npm install -g .). Retourneert $true bij succes.
function Install-HuddleCli {
    $cliDir = Join-Path $PSScriptRoot 'cli'
    Write-Host "  Huddle CLI installeren vanaf $cliDir..." -ForegroundColor DarkCyan
    Push-Location $cliDir
    try {
        npm install
        if ($LASTEXITCODE -ne 0) { Write-Host "  [FAIL] npm install mislukt." -ForegroundColor Red; return $false }
        npm run install-global
        if ($LASTEXITCODE -ne 0) { Write-Host "  [FAIL] CLI-installatie mislukt." -ForegroundColor Red; return $false }
        Write-Host "  [OK] Huddle CLI geinstalleerd." -ForegroundColor Green
        return $true
    } finally {
        Pop-Location
    }
}

# ── Initialiseren via de CLI ──────────────────────────────────────────────────

# Alle opstartlogica (volume, intern netwerk, dc-sockets, container-run) zit in
# `huddle init`; dit script levert alleen de lokaal gebouwde image aan via
# HUDDLE_IMAGE + HUDDLE_NO_PULL zodat er niets uit het register gepulld wordt.
function Initialize-Huddle {
    # Sysbox: alles (image-build, CLI, gateway, devcontainers) draait OP de engine
    # host (WSL2-distro), niet op Docker Desktop. De portal blijft op
    # http://localhost:<port> bereikbaar via WSL-portforwarding.
    if ($SYSBOX_MODE) {
        if (-not (Get-Command Start-HuddleOnEngine -ErrorAction SilentlyContinue)) {
            Write-Host "  [FAIL] huddle-engine.ps1 niet gevonden naast huddle.ps1." -ForegroundColor Red
            return $false
        }
        Write-Host "  Sysbox-modus: initialiseren op de engine host..." -ForegroundColor DarkCyan
        return (Start-HuddleOnEngine -RepoRoot $PSScriptRoot -Port $HUDDLE_PORT -Image $HUDDLE_IMAGE)
    }

    if (-not (Get-Command huddle -ErrorAction SilentlyContinue)) {
        Write-Host "  [FAIL] 'huddle' CLI niet gevonden. Kies de reset-optie 'CLI' om hem te installeren." -ForegroundColor Red
        return $false
    }

    & $RUNTIME image inspect $HUDDLE_IMAGE *>$null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Image '${HUDDLE_IMAGE}' niet gevonden -- eerst bouwen..." -ForegroundColor DarkCyan
        Build-HuddleImage
        if ($LASTEXITCODE -ne 0) { return $false }
    }

    Write-Host "  Initialiseren via 'huddle init' (runtime '${RUNTIME}', HUDDLE_NO_PULL=1, image '${HUDDLE_IMAGE}')..." -ForegroundColor DarkCyan
    # Remember what the CALLER set: the cleanup below used to Remove-Item these
    # unconditionally, so a user's `$env:HUDDLE_PORT = '3100'` was wiped after the
    # first init and every later run silently fell back to 3000.
    $prevImage  = $env:HUDDLE_IMAGE
    $prevNoPull = $env:HUDDLE_NO_PULL
    $prevPort   = $env:HUDDLE_PORT
    $env:HUDDLE_IMAGE   = $HUDDLE_IMAGE
    $env:HUDDLE_NO_PULL = '1'
    $env:HUDDLE_PORT    = "$HUDDLE_PORT"
    try {
        huddle init
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [FAIL] 'huddle init' mislukt." -ForegroundColor Red
            return $false
        }
        return $true
    } finally {
        # Restore, don't delete.
        if ($null -ne $prevImage)  { $env:HUDDLE_IMAGE = $prevImage }   else { Remove-Item Env:HUDDLE_IMAGE -ErrorAction SilentlyContinue }
        if ($null -ne $prevNoPull) { $env:HUDDLE_NO_PULL = $prevNoPull } else { Remove-Item Env:HUDDLE_NO_PULL -ErrorAction SilentlyContinue }
        if ($null -ne $prevPort)   { $env:HUDDLE_PORT = $prevPort }     else { Remove-Item Env:HUDDLE_PORT -ErrorAction SilentlyContinue }
    }
}

# ── Image bouwen op de JUISTE daemon ─────────────────────────────────────────
# Klassiek/DinD: de lokale docker (Docker Desktop).
# Sysbox: de ENGINE HOST (WSL2-distro). Daar draaien de devcontainers, dus daar
# moeten de images ook staan — en de base image heeft dan een echte docker-engine
# nodig (HUDDLE_DOCKER_ENGINE=1), niet alleen de CLI.
function Invoke-ImageBuild {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Dockerfile,   # pad op Windows
        [Parameter(Mandatory)][string]$Context,      # pad op Windows
        [switch]$WithDockerEngine
    )
    if ($SYSBOX_MODE) {
        if (-not (Get-Command Invoke-Engine -ErrorAction SilentlyContinue)) {
            Write-Host "  [FAIL] huddle-engine.ps1 niet geladen; kan niet op de engine bouwen." -ForegroundColor Red
            return $false
        }
        $df  = ConvertTo-EnginePath $Dockerfile
        $ctx = ConvertTo-EnginePath $Context
        $arg = if ($WithDockerEngine) { '--build-arg HUDDLE_DOCKER_ENGINE=1 ' } else { '' }
        # BUILDKIT_PROGRESS=plain: the default progress renderer uses carriage
        # returns and ANSI, which becomes an unreadable staircase once it crosses
        # the wsl.exe -> PowerShell console boundary.
        $rc = Invoke-Engine -Command "cd '$ctx' && BUILDKIT_PROGRESS=plain docker build ${arg}-t $Tag -f '$df' '$ctx'"
        return ($rc -eq 0)
    }
    & $RUNTIME build -t $Tag -f $Dockerfile $Context --no-cache
    return ($LASTEXITCODE -eq 0)
}

# ── Build Huddle image ────────────────────────────────────────────────────────

function Build-HuddleImage {
    $scriptDir = $PSScriptRoot
    Write-Host "  Image '${HUDDLE_IMAGE}' bouwen..." -ForegroundColor DarkCyan
    $gwDir = Join-Path $scriptDir "gateway"
    $built = Invoke-ImageBuild -Tag $HUDDLE_IMAGE -Dockerfile (Join-Path $gwDir 'Dockerfile') -Context $gwDir
    if ($built) {
        Write-Host "  [OK] Image '${HUDDLE_IMAGE}' klaar." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Build mislukt." -ForegroundColor Red
    }
}

# ── IDE picker (gemeenschappelijk voor build + spawn) ────────────────────────

function Select-Ide {
    Write-Host ""
    Write-Host "  IDE:" -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $IDE_DEFS.Count; $i++) {
        Write-Host ("   {0})  {1}" -f ($i + 1), $IDE_DEFS[$i].Display)
    }
    $sel = [int](Read-Host "`n  Kies IDE") - 1
    if ($sel -lt 0 -or $sel -ge $IDE_DEFS.Count) { return $null }
    return $IDE_DEFS[$sel]
}

# Detecteer welke IDE bij een snapshot/image hoort — eerst via het label
# com.devcontainer.ide, dan via fallback op de naam-conventie base-devimage-<ide>.
function Get-ImageIde {
    param([string]$ImageRef)
    $json = & $RUNTIME inspect $ImageRef 2>$null | Out-String
    if ($json) {
        try {
            $label = (ConvertFrom-Json $json)[0].Config.Labels.'com.devcontainer.ide'
            if ($label) { return $label.Trim() }
        } catch {}
    }
    foreach ($ide in $IDE_DEFS) {
        if ($ImageRef -like "*$($ide.Image)*") { return $ide.Key }
    }
    return $null
}

# ── Snapshot ──────────────────────────────────────────────────────────────────

function New-Snapshot {
    Write-Host ""
    Write-Host "  Draaiende devcontainers:" -ForegroundColor DarkCyan

    $fmt = "{{.ID}}|{{.Names}}|{{.Image}}"
    $rows = @(& $RUNTIME ps --filter 'label=com.intellij.devcontainer.id' --format $fmt |
        ForEach-Object {
            $p = $_ -split '\|'
            [PSCustomObject]@{ ID = $p[0]; Name = $p[1]; Image = $p[2] }
        })

    if (-not $rows) { Write-Host "  Geen draaiende containers." -ForegroundColor Yellow; return }

    for ($i = 0; $i -lt $rows.Count; $i++) {
        Write-Host ("   {0})  {1,-35} {2}" -f ($i + 1), $rows[$i].Name, $rows[$i].Image)
    }

    $sel = [int](Read-Host "`n  Kies container") - 1
    if ($sel -lt 0 -or $sel -ge $rows.Count) { Write-Host "  Ongeldige keuze." -ForegroundColor Red; return }
    $container = $rows[$sel]

    # Detecteer IDE uit het bestaande JB-model-label van de bron-container
    # (`customizations.jetbrains.backend`). Dan kan de spawn-UI dit snapshot
    # filteren als "Rider-snapshot" / "IntelliJ-snapshot".
    $ideKey = $null
    $inspectJson = & $RUNTIME inspect $container.ID 2>$null | Out-String
    if ($inspectJson) {
        try {
            $modelLabel = (ConvertFrom-Json $inspectJson)[0].Config.Labels.'com.intellij.devcontainer.model'
            if ($modelLabel) {
                $backend = (ConvertFrom-Json $modelLabel).customizations.jetbrains.backend
                $ideKey  = ($IDE_DEFS | Where-Object { $_.Backend -eq $backend } | Select-Object -First 1).Key
            }
        } catch {}
    }
    if (-not $ideKey) {
        Write-Host "  Kon IDE niet uit container-labels lezen -- kies handmatig:" -ForegroundColor Yellow
        $picked = Select-Ide
        if (-not $picked) { Write-Host "  Geen IDE gekozen, snapshot afgebroken." -ForegroundColor Red; return }
        $ideKey = $picked.Key
    }

    $defaultName = "snapshot-$($container.Name)"
    $imageName   = Read-Host "  Snapshot naam [$defaultName]"
    if (-not $imageName) { $imageName = $defaultName }

    Write-Host "  Commit $($container.Name) -> $imageName  (IDE: $ideKey)" -ForegroundColor DarkCyan
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    & $RUNTIME commit `
        --change 'LABEL com.devcontainer.snapshot=true' `
        --change "LABEL com.devcontainer.source=$($container.Name)" `
        --change "LABEL com.devcontainer.created=$timestamp" `
        --change "LABEL com.devcontainer.ide=$ideKey" `
        $container.ID $imageName | Out-Null
    Write-Host "  [OK] Snapshot '$imageName' klaar." -ForegroundColor Green
}

# ── Start devcontainer (IDE-first → standaard/snapshot) ──────────────────────

function Start-Devcontainer {
    # Stap 1: IDE kiezen — bepaalt welke base image + welke snapshots in beeld.
    $ide = Select-Ide
    if (-not $ide) { Write-Host "  Ongeldige IDE-keuze." -ForegroundColor Red; return }

    # Stap 2: standaard (per-IDE base image) of een snapshot van die IDE.
    Write-Host ""
    Write-Host "  Beschikbare images voor $($ide.Display):" -ForegroundColor DarkCyan
    $options = @()

    $baseExists = & $RUNTIME image inspect $ide.Image *>$null 2>&1
    if ($LASTEXITCODE -eq 0) {
        $options += [PSCustomObject]@{ Name = $ide.Image; Kind = 'standaard'; Detail = 'base image' }
    } else {
        $options += [PSCustomObject]@{ Name = $ide.Image; Kind = 'standaard'; Detail = '(nog niet gebouwd -- wordt direct gebouwd voor je)' }
    }

    $fmt = "{{.Repository}}:{{.Tag}}|{{.Size}}|{{.CreatedSince}}"
    $snapRows = @(& $RUNTIME images --filter 'label=com.devcontainer.snapshot=true' --filter "label=com.devcontainer.ide=$($ide.Key)" --format $fmt |
        ForEach-Object {
            $p = $_ -split '\|'
            # base-devimage-* zelf óók een snapshot; sla over zodat hij niet dubbel staat.
            if ($p[0] -ne "$($ide.Image):latest" -and $p[0] -ne $ide.Image) {
                [PSCustomObject]@{ Name = $p[0]; Kind = 'snapshot'; Detail = "$($p[1])  $($p[2])" }
            }
        })
    foreach ($r in $snapRows) { $options += $r }

    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-Host ("   {0})  [{1,-9}]  {2,-45}  {3}" -f ($i + 1), $options[$i].Kind, $options[$i].Name, $options[$i].Detail)
    }

    $sel = [int](Read-Host "`n  Kies image") - 1
    if ($sel -lt 0 -or $sel -ge $options.Count) { Write-Host "  Ongeldige keuze." -ForegroundColor Red; return }
    $picked = $options[$sel]

    # Auto-build de standaard-image als die nog niet bestaat.
    if ($picked.Kind -eq 'standaard' -and $LASTEXITCODE -ne 0) {
        Write-Host "  Image '$($picked.Name)' nog niet aanwezig -- bouwen..." -ForegroundColor DarkCyan
        $scriptDir = $PSScriptRoot
        # Build-context = repo-root zodat de Dockerfile `COPY .ai/…` kan; Dockerfile via -f.
        & $RUNTIME build -t $picked.Name -f (Join-Path $scriptDir "$($ide.Folder)/Dockerfile") $scriptDir --no-cache
        if ($LASTEXITCODE -ne 0) { Write-Host "  Build mislukt." -ForegroundColor Red; return }
    }

    $workspaceDir = Read-Host "  Workspace directory"
    if (-not (Test-Path $workspaceDir)) {
        Write-Host "  Directory bestaat niet: $workspaceDir" -ForegroundColor Red; return
    }

    $leafName           = Split-Path $workspaceDir -Leaf
    $containerWorkspace = "/workspaces/$leafName"
    $presentableName    = $leafName
    $workspaceDirFwd    = $workspaceDir.TrimEnd('\', '/') -replace '\\', '/'

    $defaultName   = "devcontainer-$presentableName"
    $containerName = Read-Host "  Containernaam [$defaultName]"
    if (-not $containerName) { $containerName = $defaultName }

    $existing = & $RUNTIME ps -aq --filter "name=^${containerName}$" 2>$null
    if ($existing) {
        $confirm = Read-Host "  Container '$containerName' bestaat al. Verwijderen? [j/N]"
        if ($confirm -ne 'j') { return }
        & $RUNTIME rm -f $containerName | Out-Null
    }

    # De gateway doet alle container-aanmaaklogica: per-container socket-proxy,
    # worktrees, AI-CLI volumes, MCP-config, TLS CA en de firewall-redirect.
    # Het PS1-script delegeert daarom volledig naar de Huddle API.
    Write-Host "  Container starten via Huddle API..." -ForegroundColor DarkCyan

    $body = @{
        imageName     = $picked.Name
        workspaceDir  = $workspaceDirFwd
        containerName = $containerName
        ideName       = $ide.Key
        empty         = $false
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Method Post `
            -Uri "http://localhost:3000/api/docker/start" `
            -ContentType "application/json" `
            -Body $body
        Write-Host "  [OK] Container '$containerName' gestart (ID: $($response.id))." -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] Aanmaken mislukt: $_" -ForegroundColor Red
        Write-Host "  Zorg dat Huddle draait (optie 4 om te herstarten)." -ForegroundColor Yellow
        return
    }

    if ($ide.Key -eq 'vscode') {
        Write-Host "  Verbind via VS Code: 'Dev Containers: Attach to Running Container' -> '$containerName'," -ForegroundColor Cyan
        Write-Host "  open daarna de map '$containerWorkspace'." -ForegroundColor Cyan
        return
    }

    Write-Host "  Verbind via Remote Development > Dev Containers met '$containerName'" -ForegroundColor Cyan
    $link = Invoke-RestMethod -Uri "http://localhost:3000/api/docker/containers/$containerName/ide-link" -ErrorAction SilentlyContinue
    if ($link.link) { Write-Host "  IDE-link: $($link.link)" -ForegroundColor Cyan }
}

# ── Build base image ──────────────────────────────────────────────────────────

# Bouwt de gedeelde base-devimage (sequentieel, want IDE-images hangen ervan af).
function Build-SharedBase {
    param([string]$ScriptDir)
    $dockerfile = Join-Path $ScriptDir 'base-devimage\Dockerfile'
    Write-Host "  Gedeelde base image 'ghcr.io/infosupport/base-devimage' bouwen..." -ForegroundColor DarkCyan
    # Build-context = repo-root zodat de Dockerfile `COPY .ai/…` kan; Dockerfile via -f.
    if (-not (Invoke-ImageBuild -Tag 'ghcr.io/infosupport/base-devimage' -Dockerfile $dockerfile -Context $ScriptDir -WithDockerEngine:$SYSBOX_MODE)) {
        Write-Host "  [FAIL] Build van base-devimage mislukt." -ForegroundColor Red
        return $false
    }
    Write-Host "  [OK] ghcr.io/infosupport/base-devimage klaar." -ForegroundColor Green
    return $true
}

function Build-BaseImage {
    # Eigen picker (niet de gedeelde Select-Ide): naast de losse IDE's ook een
    # 'Alle (parallel)'-keuze die alle base images tegelijk bouwt.
    Write-Host ""
    Write-Host "  IDE:" -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $IDE_DEFS.Count; $i++) {
        Write-Host ("   {0})  {1}" -f ($i + 1), $IDE_DEFS[$i].Display)
    }
    Write-Host ("   {0})  Alle (parallel)" -f ($IDE_DEFS.Count + 1))
    $sel = [int](Read-Host "`n  Kies IDE") - 1
    if ($sel -eq $IDE_DEFS.Count) { Build-AllBaseImages; return }
    if ($sel -lt 0 -or $sel -ge $IDE_DEFS.Count) { Write-Host "  Ongeldige IDE-keuze." -ForegroundColor Red; return }
    $ide = $IDE_DEFS[$sel]

    $scriptDir = $PSScriptRoot
    if (-not (Build-SharedBase -ScriptDir $scriptDir)) { return }

    $buildPath = Join-Path $scriptDir $ide.Folder
    if (-not (Test-Path (Join-Path $buildPath 'Dockerfile'))) {
        Write-Host "  Dockerfile niet gevonden: $buildPath\Dockerfile" -ForegroundColor Red
        return
    }
    Write-Host "  Image '$($ide.Image)' bouwen ($($ide.Display))..." -ForegroundColor DarkCyan
    # Build-context = repo-root zodat de Dockerfile `COPY .ai/…` kan; Dockerfile via -f.
    $built = Invoke-ImageBuild -Tag $ide.Image -Dockerfile (Join-Path $buildPath 'Dockerfile') -Context $scriptDir
    if ($built) {
        Write-Host "  [OK] Image '$($ide.Image)' klaar." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Build mislukt." -ForegroundColor Red
    }
}

# ── Build alle base images parallel ─────────────────────────────────────────────

# Bouwt eerst de gedeelde base-devimage (sequentieel), daarna de IDE-images parallel.
# Output per build gaat naar een eigen logbestand in $env:TEMP (parallelle builds
# door elkaar op de console is onleesbaar); aan het eind volgt een overzicht.
function Build-AllBaseImages {
    $scriptDir = $PSScriptRoot

    if (-not (Build-SharedBase -ScriptDir $scriptDir)) { return }

    Write-Host ""
    Write-Host "  IDE-images parallel bouwen..." -ForegroundColor DarkCyan
    Write-Host ""

    $builds = @()
    foreach ($ide in $IDE_DEFS) {
        $dockerfile = Join-Path (Join-Path $scriptDir $ide.Folder) 'Dockerfile'
        if (-not (Test-Path $dockerfile)) {
            Write-Host "  [SKIP] Dockerfile niet gevonden voor $($ide.Display): $dockerfile" -ForegroundColor Yellow
            continue
        }
        $logOut = Join-Path $TempDir "huddle-build-$($ide.Key).out.log"
        $logErr = Join-Path $TempDir "huddle-build-$($ide.Key).err.log"
        # Build-context = repo-root zodat de Dockerfile `COPY .ai/…` kan; Dockerfile via -f.
        $proc = Start-Process -FilePath $RUNTIME `
            -ArgumentList @('build', '-t', $ide.Image, '-f', $dockerfile, $scriptDir) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $logOut -RedirectStandardError $logErr
        # Forceer het cachen van de proces-handle; zonder dit blijft .ExitCode na
        # afloop leeg (bekende Start-Process -PassThru valkuil).
        try { [void]$proc.Handle } catch {}
        Write-Host "  -> $($ide.Image) ($($ide.Display)) gestart  [pid $($proc.Id)]  log: $logOut" -ForegroundColor DarkGray
        $builds += [PSCustomObject]@{ Ide = $ide; Proc = $proc; LogErr = $logErr }
    }

    if (-not $builds) { Write-Host "  Geen images om te bouwen." -ForegroundColor Yellow; return }

    Write-Host ""
    Write-Host "  Wachten tot $($builds.Count) build(s) klaar zijn..." -ForegroundColor DarkCyan
    foreach ($b in $builds) { $b.Proc.WaitForExit() }

    Write-Host ""
    $allOk = $true
    foreach ($b in $builds) {
        if ($b.Proc.ExitCode -eq 0) {
            Write-Host "  [OK]   $($b.Ide.Image)" -ForegroundColor Green
        } else {
            $allOk = $false
            Write-Host "  [FAIL] $($b.Ide.Image) (exit $($b.Proc.ExitCode)) -- zie $($b.LogErr)" -ForegroundColor Red
            if (Test-Path $b.LogErr) {
                Get-Content $b.LogErr -Tail 15 | ForEach-Object { Write-Host "         | $_" -ForegroundColor DarkGray }
            }
        }
    }
    Write-Host ""
    if ($allOk) {
        Write-Host "  [OK] Alle base images klaar." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Niet alle builds zijn geslaagd." -ForegroundColor Red
    }
}

# ── Tests ────────────────────────────────────────────────────────────────────

function Invoke-Tests {
    $gatewayDir = Join-Path $PSScriptRoot "gateway"
    Write-Host ""
    Write-Host "  Unit testen draaien..." -ForegroundColor DarkCyan
    Push-Location $gatewayDir
    try {
        npm test
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [FAIL] Unit testen mislukt." -ForegroundColor Red
            return
        }
        Write-Host "  [OK] Unit testen geslaagd." -ForegroundColor Green

        Write-Host ""
        Write-Host "  E2E testen draaien..." -ForegroundColor DarkCyan
        $env:HUDDLE_E2E = "1"
        npm run test:e2e
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] E2E testen geslaagd." -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] E2E testen mislukt." -ForegroundColor Red
        }
        $env:HUDDLE_E2E = $null
    } finally {
        Pop-Location
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Opstartflow: vraag (multiselect) welke onderdelen gereset moeten worden, bouw/
# installeer die opnieuw, en initialiseer daarna altijd via de CLI met no-pull.
Write-Banner
$resetOk = $true
$reset = Select-ResetComponents
Write-Host ""

if ($reset -contains 'cli') {
    if (-not (Install-HuddleCli)) { $resetOk = $false }
}
if ($resetOk -and $reset -contains 'huddle-image') {
    Build-HuddleImage
    if ($LASTEXITCODE -ne 0) { $resetOk = $false }
}
if ($resetOk -and $reset -contains 'devimages') {
    Build-AllBaseImages
}

if ($resetOk) {
    Initialize-Huddle | Out-Null
} else {
    Write-Host "  Reset niet volledig gelukt -- initialisatie overgeslagen." -ForegroundColor Red
}
Read-Host "`n  Druk Enter voor het menu"

$running = $true
while ($running) {
    Show-Menu
    $choice = Read-Host "  Keuze"
    Write-Host ""
    switch ($choice) {
        '1' { New-Snapshot;       Read-Host "`n  Druk Enter om terug te gaan" }
        '2' { Start-Devcontainer; Read-Host "`n  Druk Enter om terug te gaan" }
        '3' { Build-BaseImage;    Read-Host "`n  Druk Enter om terug te gaan" }
        '4' { Build-HuddleImage; if ($LASTEXITCODE -eq 0) { Initialize-Huddle | Out-Null }; Read-Host "`n  Druk Enter om terug te gaan" }
        '5' { Invoke-Tests;       Read-Host "`n  Druk Enter om terug te gaan" }
        '6' {
            if (Get-Command Initialize-HuddleEngine -ErrorAction SilentlyContinue) {
                if (Initialize-HuddleEngine -RepoRoot $PSScriptRoot) {
                    $SYSBOX_MODE = $true
                    $env:HUDDLE_SYSBOX = '1'
                    Write-Host "`n  Engine host klaar. Kies 4 om Huddle in sysbox-modus te (her)initialiseren." -ForegroundColor Green
                }
            } else {
                Write-Host "  huddle-engine.ps1 niet gevonden naast huddle.ps1." -ForegroundColor Red
            }
            Read-Host "`n  Druk Enter om terug te gaan"
        }
        '0' { $running = $false }
        { $_ -in @('r', 'R', '') } {
            # Alleen verversen: de lus tekent het menu (incl. Write-Status) opnieuw.
            if ($SYSBOX_MODE -and (Get-Command Invoke-Engine -ErrorAction SilentlyContinue)) {
                Write-Host "  Containers op de engine:" -ForegroundColor DarkCyan
                Invoke-Engine -Command 'docker ps -a --format "  {{.Names}}  |  {{.Status}}"' | Out-Null
                Write-Host ""
                Start-Sleep -Milliseconds 400
            }
        }
        default { Write-Host "  Ongeldige keuze." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
