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

- **Stop devcontainers before the engine goes down — use `.\huddle-engine.ps1 -Down`.**
  Sysbox shifts a container's rootfs either by chowning a clone under `/var/lib/sysbox` (on disk,
  survives a reboot) or with an ID-mapped mount (a kernel mount, gone after one) — and it picks per
  container. Kill the host while an ID-mapped container is *running* and it comes back with the
  whole image owned by `nobody:nogroup`: no `sudo`, no `apt`, broken setuid binaries. `sysbox-mgr`
  says so itself on the way out — *"The following containers are active and will stop operating
  properly"*. A stop/start does **not** repair it; only recreating the container does. A container
  that was stopped first always comes back fine. Measured: `wsl --terminate` does not run systemd
  shutdown, so no unit inside the distro can save you — the stop has to happen from Windows first.
  Native Linux is mostly safe here, since a normal reboot stops docker cleanly.
- **You should never have to deal with this.** Starting a devcontainer probes `/bin/sh`'s owner;
  if the shift is gone, the gateway recreates the container and puts the data back before handing
  it over (`gateway/src/sysbox-heal.ts`). Press start, get your container, with everything you
  installed and wrote still in it.
  How, and why the obvious routes do not work: the *image* layers are broken in the affected
  container but correct in a fresh one, while the *writable* layer is still readable with correct
  uids **inside** the broken container. So: fresh container from the original image, then copy the
  writable layer across inside-to-inside so each container applies its own shift. `docker commit`
  is the wrong tool — it bakes one container's shifted uids into the image and the next container
  has a different subuid base, so everything lands on `nobody` again (measured). The copy takes the
  changed paths from `docker diff`, minus anything at, under, **or above** a mount point: the
  workspace bind, the inner daemon's `/var/lib/docker` volume and sysbox's read-only
  `/lib/modules` are not writable-layer state, and an *ancestor* of a mount would make `tar`
  recurse into it (143 MB of kernel modules instead of 900 KB).
  Manual rescue, if you ever want it: `docker cp <name>:/home/vscode/.claude ./rescue/` — that
  works too, and the files are also readable host-side under `/proc/<pid>/root/`.
- Upstream considers surviving a reboot to be intended: on nestybox/sysbox#757, the same "mount
  lost its `idmapped` attribute" symptom got *"this should definitely work, there must be a bug
  somewhere"*. So the heal above is a workaround for an upstream bug, not a permanent design.
  Sysbox's own troubleshooting guide meanwhile states that after sysbox-fs/sysbox-mgr restarts you
  are "expected to recreate ... all the active Sysbox containers" — which is exactly why the
  `-Down` rule above matters.
- **WSL tears the distro down** when no client is attached, taking dockerd and the containers with
  it. `-Keepalive` holds one client open. The gateway carries `--restart unless-stopped`;
  devcontainers deliberately do not, since a restart policy would silently bring them back in the
  broken state described above.
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
