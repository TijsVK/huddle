# CRITICAL: DinD privileged host escape (finding C1)

**Status: MITIGATED (2026-07-18) — enforced by a dockerd AUTHORIZATION PLUGIN on
the private daemon. Escape red test `gateway/test/dind-compat/e2e-escape.sh` is
GREEN.**

> **History:** the first mitigation was a socket-proxy *filter* in front of an
> `inner.sock`. Adversarial review found it bypassable two ways — (1) the
> devcontainer mounted the dir holding both the filter socket AND the raw
> `inner.sock`, so `curl --unix-socket inner.sock` skipped the filter; (2) even
> split, a nested container could symlink a shared workspace path to the sidecar's
> socket dir and bind through it (dockerd follows symlink bind sources; a lexical
> guard can't stop it). Both verified live. The fix below (an authz plugin) removes
> the unfiltered socket entirely, so neither bypass exists.

## The issue
In DinD mode each devcontainer gets an unrestricted private Docker daemon whose
sidecar (`dind-<name>`) runs `--privileged`. A privileged nested container inside
a privileged sidecar **sees the host's block devices and kernel**, so an untrusted
devcontainer could take over the host with zero operator interaction:

```
docker run --rm --privileged alpine sh -c 'mount -o ro /dev/sdg /m; cat /m/etc/shadow'
```

**Verified on the live env (2026-07-18, pre-fix):** a nested `--privileged`
container saw `/dev/sda`–`/dev/sdh` (sizes matching host `/proc/partitions`),
mounted host disk `/dev/sdg`, read the real host `/etc/hostname` (`ISNL-HBJ7BH4`),
host `os-release`, and **read `/etc/shadow`**. From there: the CA private key,
operator token, DB, every peer devcontainer, the host itself.

The design premise ("only the sidecar is privileged, isolation preserved") was
**wrong**: `--privileged` is not a boundary against an attacker who controls what
runs inside the daemon.

## The mitigation (implemented)
The sidecar dockerd runs with **`--authorization-plugin=huddle-authz`**
(`gateway/src/dind-authz.ts`). dockerd calls the plugin for EVERY API request
before executing it, so the guard is enforced on the daemon's single socket —
there is no second, unfiltered path to reach.

- Socket topology: the sidecar `dockerd` listens on its own `docker.sock` (in
  `/tmp/dc-sockets/<name>/outer`, mounted `/var/run/dind` in the sidecar AND the
  devcontainer); the gateway serves the plugin socket
  `/tmp/dc-sockets/<name>/plugin/huddle-authz.sock`, mounted into the sidecar at
  `/run/docker/plugins` (dockerd's plugin-discovery path). There is **no
  `inner.sock`** — the devcontainer talks to `docker.sock` directly and dockerd
  enforces authz on it. The plugin socket speaks the authz protocol only (useless
  as a docker client), so reaching it grants nothing.
- On `POST /containers/create` the plugin runs `validateDindEscape(HostConfig)`
  and denies (`403`) the **device/kernel/namespace** vectors: `Privileged`,
  `Devices`/`DeviceCgroupRules`/`DeviceRequests`, `CapAdd`, host `PidMode`/
  `IpcMode`/`UsernsMode`/`CgroupnsMode`/`UTSMode`, `CgroupParent`, `Sysctls`,
  per-device Blkio limits, non-default `SecurityOpt` (any custom seccomp/apparmor,
  not just literal `unconfined` — finding #8), and an **unmask of the default
  MaskedPaths/ReadonlyPaths** (`/proc/kcore`, `/proc/sysrq-trigger` — finding #3).
- On `POST /containers/{id}/exec` it runs `validateExecEscape` (privileged/CapAdd
  exec — finding #7). The request path is normalized (version prefix, `//`,
  percent-encoding) before matching so a crafted create path can't dodge
  inspection (finding #6).
- **Binds/Mounts/VolumesFrom are fully ALLOWED** — under authz there is no
  unfiltered socket, so binding the docker socket (Testcontainers Ryuk / docker-
  outside-of-docker) just yields another authz-guarded client, and a host-path
  bind resolves against the disposable sidecar fs. No bind guard is needed.

Because dockerd handles the request stream natively, the old proxy's hijack/
half-open/chunked-parsing complexity is gone (findings #4/#5/#6 dissolve).

Net effect: the escape is closed **and** all tool-compat works — inspect,
networks, port-publish, archive/CopyFile, exec (streams), build (incl. BuildKit
default builder), non-privileged run, host-path binds, Testcontainers Ryuk.

## Cost / known limitation
Tools that need a genuinely `--privileged` nested container (kind/k3d/minikube
worker nodes, dind-in-dind, some nested-systemd setups) are refused in DinD mode.
If the gateway process is down, dockerd fails requests closed until the plugin
reconnects (the plugin is re-established on gateway restart, before the sidecar is
(re)started). Aspire, compose, buildx (default builder), Testcontainers all work.

## Rejected alternatives
- **Rootless dind** — incompatible with the shared-netns model (rootlesskit needs
  its own netns; `ip tuntap add tap0` fails under `--network container:<dc>`), and
  that shared netns is what makes published ports land on the devcontainer's
  localhost (the Aspire fix).
- **userns-remap on the sidecar** — Docker disables userns for `--privileged`
  containers, so it does NOT stop the escape.
- **Non-privileged sidecar** — dockerd starts but nested `docker run` fails
  (runc/cgroup fifo errors).

## Tests
- `gateway/test/dind-compat/e2e-escape.sh` — live red test: no `inner.sock`; raw
  privileged create over `docker.sock` is authz-denied (403); privileged/device
  refused; host fs unreachable; no unfiltered socket reachable by a nested bind;
  docker.sock passthrough stays authz-guarded; MaskedPaths unmask refused; benign
  bind still works.
- `gateway/test/dind-authz.test.ts` — unit: `authorize()` create/exec inspection,
  path-normalization, fail-closed, and `validateDindEscape`/`validateExecEscape`
  edge cases (findings #3/#6/#7/#8).
- `gateway/test/dind-compat/tools/privileged.sh` — compat-battery variant (runs the
  real authz plugin via `authz-runner.mjs`).
