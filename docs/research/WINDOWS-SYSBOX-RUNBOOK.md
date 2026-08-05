# Windows runbook — Huddle in Sysbox mode via `huddle.ps1`

Target: the classic developer start (`.\huddle.ps1`) on Windows 11, but every devcontainer is a
**Sysbox sandbox with its own Docker daemon** — no socket-proxy, no DinD sidecar, no authz plugin.

## Why an engine distro

Sysbox installs on the **Docker host**. On Windows that host cannot be Docker Desktop's own WSL
distro (Docker manages it; the equivalent there is Enhanced Container Isolation, which is
Business-tier and Desktop-only). So Huddle provisions and owns a WSL2 distro — the *engine host* —
that runs `dockerd` + `sysbox-runc`. Everything (gateway image, CLI, devcontainers) runs there;
the portal stays reachable from Windows on `http://localhost:3000` through WSL's port forwarding.

```
Windows
 ├─ huddle.ps1                      thin front-end; drives the engine over wsl.exe
 └─ WSL2 distro "huddle-engine"     ← the Docker host
     ├─ dockerd + sysbox-runc
     ├─ huddle gateway container    portal :3000, proxy :80, rules/audit
     └─ devcontainer (sysbox-runc)  own dockerd inside → Aspire, compose, Testcontainers, kind
```

## One-time setup

```powershell
cd <repo>
$env:HUDDLE_SYSBOX = '1'      # or pick menu option 6 first
.\huddle.ps1                  # menu → 6  (set up / verify the Sysbox engine host)
```

Menu option 6 (`Initialize-HuddleEngine`) does:

1. `wsl --install Ubuntu-24.04 --name huddle-engine --no-launch` (needs WSL 2.4+; falls back to
   printing the `wsl --import` command).
2. Writes `/etc/wsl.conf` with `[boot] systemd=true` and terminates the distro so systemd starts
   (Sysbox ships systemd units).
3. Runs `scripts/huddle-engine-install.sh` inside the distro: verifies kernel ≥ 5.19, `/dev/fuse`,
   cgroup v2, user namespaces and systemd; installs `docker-ce`, Node 24 and `sysbox-ce`;
   registers the `sysbox-runc` runtime; smoke-tests a user-namespaced container.
4. Verifies the result (`-Check` re-runs only the verification).

Then menu option **4** builds the gateway image and runs `huddle init` **on the engine** with
`HUDDLE_SYSBOX=1`.

Standalone equivalents:

```powershell
.\huddle-engine.ps1 -Setup    # provision
.\huddle-engine.ps1 -Check    # verify
.\huddle-engine.ps1 -Shell    # shell into the engine
```

## Devcontainer images need a Docker engine

The shipped images carry only the docker **CLI**. Build them with the engine baked in:

```powershell
docker build --build-arg HUDDLE_DOCKER_ENGINE=1 -t base-devimage        -f base-devimage/Dockerfile .
docker build -t base-devimage-vscode -f base-devimage-vscode/Dockerfile .
```

(The build arg is off by default so classic/DinD images stay slim. Verified on Linux: the vscode
image with the engine is ~6.3 GB.)

## Attaching an IDE

The devcontainers live on the **engine's** daemon, not Docker Desktop's:

- **VS Code** — Remote-WSL into `huddle-engine`, then *Dev Containers: Attach to Running
  Container*.
- **JetBrains Gateway** — add a Docker server pointing at the WSL distro (or over SSH), then
  *Dev Containers → attach*.

This is the part still **unverified** (spike S8): Huddle discovers the JetBrains gateway link by
grepping the backend log inside the container, and that path has not been exercised against a
remote/WSL Docker endpoint.

## Verification checklist on the Windows box

```powershell
.\huddle-engine.ps1 -Check                                   # engine: docker + sysbox-runc
wsl -d huddle-engine -- docker info --format '{{json .Runtimes}}'   # must list sysbox-runc
# after `huddle init`:
curl http://localhost:3000                                    # portal from Windows
wsl -d huddle-engine -- docker inspect <devcontainer> --format '{{.HostConfig.Runtime}}'   # sysbox-runc
wsl -d huddle-engine -- docker exec -u vscode <devcontainer> docker version                # inner daemon
wsl -d huddle-engine -- bash -lc 'cd <repo> && bash gateway/test/dind-compat/e2e-sysbox-firewall.sh'
```

## What is proven, and where

Measured on Linux/WSL2 (see the other docs in this folder): Sysbox 0.7.1 works on the WSL2 kernel;
devcontainer under `sysbox-runc` with unprivileged in-container `dockerd`; every DinD-red-test
escape vector blocked; firewall 14/14 including the live approve loop; Aspire project+SqlServer
E2E 9/9; compose, buildx, dind², kind all working.

**Not yet run on a Windows host:** the PowerShell front-end in this document. `huddle-engine.ps1`
and the `huddle.ps1` changes are written but **not executed on Windows** (this work happened in a
Linux WSL distro with no Windows filesystem or `wsl.exe` access, so PowerShell could not even be
syntax-checked). Treat the first run as spike **S7** and expect small fixes.

## Known Windows wrinkles

- **WSL2 distros share one network namespace.** The engine's `dockerd` coexists with Docker
  Desktop's but shares netfilter and published ports — expect port/subnet clashes. Simplest
  mitigation: quit Docker Desktop while using Sysbox mode, or pin non-overlapping
  `default-address-pool`s. The engine installer prints an advisory when Sysbox's preferred pools
  (`172.20.0.1/16`, `172.25.0.0/16`) collide, which it did on the dev box used here.
- **Repo location.** `/etc/wsl.conf` is written with `interop.appendWindowsPath=false` but
  automount stays on, so the repo is visible at `/mnt/c/...` inside the engine. That is convenient
  and slow; for real work keep sources inside the distro. Note this also means engine root can read
  `C:` — the engine is trusted infrastructure, the devcontainer is not.
- **Sysbox install is disruptive**: it restarts `dockerd` and refuses to run while containers
  exist. Engine setup is a provisioning step, never a live migration.

## Verified on Linux since this runbook was written

- **Shipped image path (S9 core): 14/14.** The full firewall E2E was re-run against
  `base-devimage-vscode-sysbox` — the real `base-devimage` chain built with
  `--build-arg HUDDLE_DOCKER_ENGINE=1` (6.29 GB) — not the purpose-built harness image:
  `e2e-sysbox-firewall-realimage.sh`, all checks pass including the live approve loop.
- **Per-devcontainer `/var/lib/docker` volume** (`huddle-sysbox-docker-<name>`) is created for the
  in-container daemon and removed with the devcontainer, so nested images no longer land in the
  sandbox's writable layer (no overlay-on-overlay, no snapshot bloat). No leftover volumes after
  the run.
- **Supervised inner dockerd**: `/usr/local/bin/huddle-dockerd-supervise` restarts the daemon if
  it dies and truncates its log past 20 MB, instead of a bare `nohup dockerd`.
- **Engine verifier runs green on a WSL2 host**: `scripts/huddle-engine-install.sh --check` reports
  kernel 6.6, `/dev/fuse`, cgroup v2, user namespaces, systemd PID 1, docker 29.6.2, sysbox 0.7.1
  active, `sysbox-runc` registered.

## Validating the PowerShell before shipping it

PowerShell parses fine on Linux via `pwsh`, so there is no excuse for shipping a script that
does not even parse:

```bash
pwsh -NoProfile -Command '
  $e=$null;$t=$null
  foreach ($f in @("huddle.ps1","huddle-engine.ps1")) {
    $null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f),[ref]$t,[ref]$e)
    if ($e.Count -eq 0) { "PARSE OK  $f" } else { "PARSE FAIL $f"; $e | % { "  line $($_.Extent.StartLineNumber): $($_.Message)" } }
  }'
```

Two rules that bit here:
- **PowerShell has no backslash escaping.** `"... --format \"{{json .Runtimes}}\" ..."` terminates
  the string at the first `\"`; the parse error then surfaces dozens of lines later. Use a
  single-quoted string, or avoid embedded quotes entirely.
- **Keep `huddle-engine.ps1` pure ASCII.** The repo's `.ps1` files have no BOM, and Windows
  PowerShell 5.1 reads BOM-less files as ANSI, so em dashes and arrows render as mojibake.


---

# Field notes from the first real Windows run (2026-08-04)

Everything below was found on an actual Windows 11 + WSL2 box, not inferred. The engine,
gateway, firewall path, ports and status reporting now work there; the remaining blocker at the
time of writing is `fusermount3`.

## Prerequisites that are NOT optional

1. **`fuse3` on the engine.** sysbox-fs virtualizes `/proc` and `/sys` over FUSE and shells out
   to `fusermount3`. The sysbox package only depends on `fuse` (FUSE 2), so a stock Ubuntu engine
   has `/usr/bin/fusermount` and no `fusermount3`, and then **every** container fails with:
   ```
   failed to pre-register with sysbox-fs ... Initialization error for container-id ...
   # sysbox-fs journal: fusermount: exec: "fusermount3": executable file not found in $PATH
   ```
   `scripts/huddle-engine-install.sh` now installs it unconditionally and restarts sysbox.
   Reproduced both directions on a working engine (hide `fusermount3` -> identical error; restore
   -> containers start with a shifted uid_map).

2. **A keepalive, or WSL will recycle the distro.** WSL tears a distro down once no client is
   attached. Since `huddle.ps1` drives the engine with short-lived `wsl.exe` calls, the distro —
   systemd, dockerd and the gateway with it — goes down seconds after each command, and the next
   call boots it again. The symptom is a gateway that is always `Up 1 second`, a dockerd journal
   full of `Starting docker.service`, and occasionally catching the boot itself
   (`Failed to start the systemd user session`, missing `/var/run/docker.sock`).
   `.\huddle-engine.ps1 -Keepalive` holds one hidden `wsl.exe` client open. If that ever fails,
   either keep a `wsl -d huddle-engine` window open, or stop WSL idling the VM:
   ```ini
   # %USERPROFILE%\.wslconfig
   [wsl2]
   vmIdleTimeout=315360000000
   ```
   This is an inherited property of the "Huddle owns a WSL2 distro" design, not a Huddle bug — a
   Hyper-V VM engine would not behave this way, at the cost of managing a real VM.

3. **`--restart unless-stopped` on the gateway** (now set by `cli/src/init.ts`) so it returns
   whenever dockerd does.

## Commands

| Command | Purpose |
|---|---|
| `.\huddle-engine.ps1 -Setup` | create/provision the engine distro (idempotent) |
| `.\huddle-engine.ps1 -Check` | verify docker + sysbox-runc |
| `.\huddle-engine.ps1 -Up` | bring the stack back after a distro/Windows restart, without re-init |
| `.\huddle-engine.ps1 -Keepalive` | (re)start the client that stops WSL recycling the distro |
| `.\huddle-engine.ps1 -Diagnose` | one paste: distro, wsl.conf, docker, sysbox units + journals, keepalive, containers, gateway inspect + logs, fuse/apparmor, ports, memory |
| `.\huddle-engine.ps1 -Code` | open VS Code inside the distro (see below) |
| `.\huddle-engine.ps1 -Attach` | list devcontainers + IDE attach instructions |
| `.\huddle.ps1` -> `r` or Enter | refresh status; in sysbox mode also lists the engine's containers |

## IDE attach

The devcontainers run on the **engine's** docker daemon, so a stock VS Code on Windows (which
talks to Docker Desktop) lists nothing. Two ways to fix that; the first keeps the normal
"open the VS Code you already have" flow.

### 1. Stock VS Code on Windows, via the docker shim (preferred)

```powershell
.\huddle-engine.ps1 -VsCode          # verifies the shim, prints the setting
.\huddle-engine.ps1 -VsCode -Apply   # writes it to settings.json (with a backup)
# then: F1 -> Developer: Reload Window
#       F1 -> Dev Containers: Attach to Running Container
```

`scripts/huddle-docker.cmd` forwards every docker command to the engine over `wsl.exe`, and
VS Code is pointed at it with `"dev.containers.dockerPath"`. No TCP socket, no sshd, no
Remote-WSL window; Docker Desktop stays untouched for everything else. Measured on a real
Windows box: **136 ms per docker call**, which is fine for the extension's polling.

Two details the shim gets right, both learned the hard way — the extension parses
`docker version --format {{json .}}` as JSON, so *anything* printed before it breaks the attach
with "docker returned an error / make sure the docker daemon is running":

- no `-u root`, because WSL prints `Failed to start the systemd user session for 'root'` on that
  path (hence the installer putting the distro's default user in the `docker` group);
- `--cd /`, so `wsl.exe` never translates the caller's Windows working directory (a UNC or
  network path makes it warn).

### 2. VS Code running inside the distro (fallback)

`.\huddle-engine.ps1 -Code` opens `code --remote wsl+huddle-engine`. The window must show
`WSL: huddle-engine` bottom-left. This needs `appendWindowsPath=true` in `/etc/wsl.conf` (an
earlier version set it to `false`, which removes `code` from the PATH inside the distro).

### JetBrains Gateway

Add a Docker server on WSL (`huddle-engine`) under Dev Containers. Not yet verified.

## Gotchas that cost time here

- The gateway logs `[api] listening on 127.0.0.1:3000` — that is the port **inside** the
  container. The published port is whatever `$env:HUDDLE_PORT` says.
- `$env:HUDDLE_PORT` was ignored (hard-coded 3000) and then *deleted* by the classic init path.
  Both fixed; the caller's value is now read and restored.
- The menu's status line queried the local docker in sysbox mode, so it printed
  `[OFF] Huddle is gestopt` while the gateway was serving happily on the engine.
- A re-init could not replace a running gateway: the port preflight ran before `huddle init` and
  refused because the *previous* gateway held the port.
- PowerShell specifics that bit repeatedly: no backslash escaping in strings; `Start-Process`
  joins `-ArgumentList` **without quoting**, so any element containing spaces is split;
  `$ErrorActionPreference = 'Stop'` in a dot-sourced file leaks into the caller and turns native
  stderr into terminating errors; `2>&1` on a native command turns ordinary progress output into
  ErrorRecords. Payloads to `wsl.exe` are now base64-encoded to sidestep quoting entirely.
- Parse-check before shipping: `pwsh` runs on Linux, so
  `[System.Management.Automation.Language.Parser]::ParseFile()` catches syntax errors without a
  Windows box.


---

# Windows bring-up: WORKING (2026-08-05)

Verified on a real Windows 11 box, driven end to end:

| Piece | State |
|---|---|
| Engine distro (`huddle-engine`, Ubuntu 24.04) | docker 29.7.1 + sysbox-ce 0.7.1, systemd, user `huddle` in docker group |
| Gateway | container `huddle`, `--restart unless-stopped`, portal on `http://localhost:3000` |
| Devcontainer | `runtime=sysbox-runc`, `restart=unless-stopped`, `uid_map 0 100000 65536` |
| Docker inside the devcontainer | **29.7.1, unprivileged, own `/var/lib/docker` volume** |
| VS Code (stock, on Windows) | attaches, installs its server inside the sandbox, loads extensions |
| Docker permissions UI | hidden in sysbox/dind mode (redundant by design) |

## The two things that made the IDE attach work

1. **The docker shim must be an `.exe`, not a `.cmd`.** `cmd.exe` writes
   ```
   'x' CMD.EXE was started with the above path as the current directory.
   UNC paths are not supported.  Defaulting to Windows directory.
   ```
   to **stdout, before the batch file runs**, whenever its working directory is a UNC path — which is
   what VS Code uses for remote/attached windows. Dev Containers parses
   `docker version --format {{json .}}` and `docker inspect` as JSON, so that preamble produced
   "docker returned an error / make sure the docker daemon is running". A batch file cannot suppress
   its own interpreter's output. `scripts/huddle-docker.cs` is compiled by the `csc.exe` that ships
   with Windows (`-VsCode` does it into `%LOCALAPPDATA%\huddle`) and pumps stdio, since VS Code
   spawns it without a console.
2. **`/etc/environment` must be writable by the container user.** Under sysbox it appears owned by
   `nobody:nogroup` (ID-mapped image layer) and VS Code patches it as the non-root user; the first
   attach failed, and only succeeded on retry because VS Code had written its
   `.patchEtcEnvironmentMarker`. The config script now fixes the ownership.

## Rancher Desktop is actively hostile to this setup

With `appendWindowsPath=true`, Rancher's Linux bin dir joins the engine's PATH and brings
`docker-credential-secretservice`, which cannot load `libsecret` in a headless distro — so **every
image pull and build fails** with `error getting credentials - err: exit status 127`. Its `docker`
also shadows `/usr/bin/docker` for anything running inside the distro. Fix:
`.\huddle-engine.ps1 -IsolatePath` (sets `appendWindowsPath=false`). `-Setup` preserves that
value now; an earlier version reset it to `true` and silently undid the fix.

## Operational notes

- The engine distro is torn down by WSL whenever no client is attached; `-Keepalive` holds one open.
  Both the gateway and the devcontainers carry `--restart unless-stopped`, so they return when
  dockerd does, but the portal will blink during the cycle.
- `/proc/uptime` inside a distro is the shared **utility VM's** uptime, not the distro's — it does
  not reset when the distro restarts, so it cannot be used to detect a cycle.
- `git` refuses the Windows checkout as root inside the engine until
  `git config --global --add safe.directory <path>`.

## Still open

- First-attach-without-retry (the `/etc/environment` fix) is committed but not yet re-verified from a
  clean devcontainer.
- Aspire and kind have not been run on the Windows engine (both pass on Linux).
- JetBrains Gateway attach is untested.
- `huddle migrate` / `needsMigration()` do not know about the sysbox mode yet.
- Splitting the control plane (portal/API/DB) onto Windows while the proxy stays in the engine —
  discussed, not started; the internal `dc-net-*` chokepoint is why the proxy must stay next to the
  devcontainers.
