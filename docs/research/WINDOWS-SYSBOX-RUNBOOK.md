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
