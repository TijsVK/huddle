# Sysbox mode

Every devcontainer runs under the **Sysbox** runtime: a user namespace with virtualized `/proc`
and `/sys`, and its **own unprivileged Docker daemon inside**. No socket-proxy in the path, no
per-action Docker policy — the tools that the filtering proxy breaks (Aspire, compose,
Testcontainers, kind, `act`, the Dev Containers CLI) work as they do on a laptop.

The egress firewall is unchanged: `dc-net-*` is still created `Internal: true`, all outbound
HTTP(S) still goes through the Huddle proxy, and the request→approve loop still applies — to the
devcontainer *and* to the containers it starts inside itself.

Enable with `HUDDLE_SYSBOX=1`. Off by default; classic mode is untouched.

## What changes per mode

| | classic | sysbox |
|---|---|---|
| Docker for the devcontainer | filtered socket-proxy, per-action grants | own daemon inside the sandbox, unrestricted |
| Isolation | container on the shared kernel | user namespace, virtualized `/proc`+`/sys`, container root ≠ host root |
| Nested `--privileged` | refused | allowed; it sees the sandbox, not the host |
| "Docker permissions" UI | shown | hidden (the toggles cannot enforce anything) |
| Devcontainer image | docker **CLI** | needs a docker **engine** (`--build-arg HUDDLE_DOCKER_ENGINE=1`) |

## Requirements

Sysbox installs on the **Docker host**, needs kernel ≥ 5.19 (ID-mapped mounts), `/dev/fuse`,
cgroup v2, user namespaces, and systemd.

- **Linux:** install Sysbox on the host that runs dockerd — `sudo bash scripts/huddle-engine-install.sh`
  (`--check` verifies without changing anything).
- **Windows:** Docker Desktop's own WSL distro cannot host Sysbox, so Huddle provisions its own
  WSL2 distro as the *engine host*. See below.
- **macOS:** the same idea with a Lima VM. Not yet exercised.

## Windows

```powershell
$env:HUDDLE_SYSBOX = '1'
.\huddle.ps1
#  6  set up / verify the engine host   (one time, ~10 min)
#  3  build base images                 (on the engine, with the docker engine baked in)
#  4  build gateway + huddle init       (on the engine)
#  2  start a devcontainer
```

The portal stays on `http://localhost:<HUDDLE_PORT>` through WSL's port forwarding.

```
Windows
 ├─ huddle.ps1 / huddle-engine.ps1   thin front-end, drives the engine over wsl.exe
 └─ WSL2 distro "huddle-engine"      ← the Docker host
     ├─ dockerd + sysbox-runc
     ├─ huddle gateway container     portal, proxy :80, rules/audit
     └─ devcontainer (sysbox-runc)   own dockerd inside
```

`huddle-engine.ps1` standalone actions: `-Setup`, `-Check`, `-Up` (bring the stack back after a
restart), `-Keepalive`, `-Diagnose` (one paste with everything), `-VsCode [-Apply]`, `-Attach`,
`-IsolatePath`, `-Shell`.

### Attaching an IDE

Devcontainers live on the **engine's** daemon, so a stock VS Code on Windows (which talks to
Docker Desktop) lists nothing. `.\huddle-engine.ps1 -VsCode -Apply` compiles
`scripts/huddle-docker.cs` into `%LOCALAPPDATA%\huddle\huddle-docker.exe` and points
`dev.containers.dockerPath` at it; the extension then sees the engine's containers and
*Dev Containers: Attach to Running Container* works from the VS Code you already have.

It must be an `.exe`, not a `.cmd`: `cmd.exe` prints `UNC paths are not supported…` on **stdout**
before a batch file runs whenever its working directory is a UNC path (which is what VS Code uses
for remote/attached windows), and the extension parses `docker version --format {{json .}}` as JSON.

JetBrains Gateway: add a Docker server on the WSL distro. Untested.

## Operational notes

- **WSL tears the distro down** when no client is attached, taking dockerd and the containers with
  it. `-Keepalive` holds one client open. Gateway and devcontainers carry `--restart unless-stopped`
  so they return with dockerd either way.
- **Keep other Docker CLIs off the engine's PATH.** Rancher Desktop's WSL integration puts its
  `docker` and a `docker-credential-secretservice` there; the latter cannot load `libsecret` in a
  headless distro and makes **every image pull and build** fail with
  `error getting credentials - err: exit status 127`. Use `-IsolatePath`.
- **Address pools:** Sysbox's installer wants `172.20.0.1/16` / `172.25.0.0/16` and skips them when
  they overlap existing subnets; reconcile with Huddle's `dc-net-*` if devcontainers cannot reach
  the gateway.
- **Installing Sysbox restarts dockerd** and refuses to run while containers exist — it is a
  provisioning step, never a live migration.
- `/proc/uptime` inside a WSL distro is the shared utility VM's uptime, not the distro's.

## Tests

`gateway/test/sysbox/` needs a Linux host with Sysbox installed, so these are manual, not CI:

```bash
# build the test base image once (or set BASE_IMAGE to a real base-devimage)
docker build -t huddle-e2e-base -f gateway/test/sysbox/Dockerfile.e2e-base gateway/test/sysbox
printf 'FROM huddle-e2e-base\nRUN apt-get update && apt-get install -y --no-install-recommends docker-ce containerd.io\n' \
  | docker build -t huddle-e2e-base-sysbox -f - .

bash gateway/test/sysbox/e2e-firewall.sh        # 14 checks: allow/deny, approve loop, nested egress, bypass attempts
bash gateway/test/sysbox/e2e-aspire.sh          # Aspire AppHost + SqlServer + EF round-trip, dashboard
bash gateway/test/sysbox/e2e-aspire-volume.sh   # SqlServer with a persistent data volume
BASE_IMAGE=ghcr.io/infosupport/base-devimage-vscode bash gateway/test/sysbox/e2e-firewall.sh
```

## Measured

On a Linux/WSL2 host with Sysbox 0.7.1, and on a Windows 11 box through the engine distro:

- devcontainer under `sysbox-runc`, `uid_map 0 100000 65536`, unprivileged Docker inside;
- escape matrix vs plain `runc --privileged`: host block devices absent, disk mount denied,
  `core_pattern` write denied, module load denied, `/proc/kcore` and `/dev/mem` denied,
  `--pid=host`/`--network=host` refused by the runtime, and a **privileged nested container** sees
  the sandbox rather than the host;
- firewall E2E 14/14 including live approval on a running devcontainer;
- Aspire project + SqlServer E2E 9/9 (DB round-trip, dashboard boots, no gRPC cert errors);
- compose, buildx, docker-in-docker-in-docker, and kind (kind needs
  `KubeletInUserNamespace` in a kubeadm patch, since kubelet opens `/dev/kmsg`);
- stock VS Code on Windows attaching to a devcontainer on the engine.
