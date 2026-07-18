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
- The plugin decodes the request body and inspects it with **case-insensitive**
  keys — dockerd's Go JSON decoder matches struct fields case-insensitively, so
  `{"hostconfig":{"privileged":true}}` would otherwise slip past a case-sensitive
  check while dockerd still applies it (finding #1, verified live). All keys are
  deep-lowercased before inspection.
- On `POST /containers/create` `validateDindEscape` denies (`403`) the
  **device/kernel/namespace** vectors: `Privileged`, `Devices`/`DeviceCgroupRules`/
  `DeviceRequests`, `CapAdd`, host `PidMode`/`IpcMode`/`UsernsMode`/`CgroupnsMode`/
  `UTSMode`, `CgroupParent`, `Sysctls`, per-device Blkio limits, non-default
  `SecurityOpt` (any custom seccomp/apparmor, not just literal `unconfined` —
  finding #8), and any **MaskedPaths/ReadonlyPaths that is not a superset of runc's
  defaults** (an unmask of `/proc/kcore`, `/sys/firmware`, `/proc/sysrq-trigger`, …
  — findings #3/#4; `null`/omitted is fine, the daemon applies defaults).
- **Host-kernel binds are denied** (finding #3): the sidecar is `--privileged`, so
  its `/proc`, `/sys`, `/dev` are the HOST's *writable* kernel interfaces. A
  nested `-v /proc/sys:/x` then `echo … > /x/kernel/core_pattern` sets the host's
  core-dump handler → **host root** (verified live). The plugin refuses any bind
  whose source is `/proc`, `/sys`, `/dev` or `/`. Ordinary binds (workspace, `/etc`,
  the authz-guarded `docker.sock` for Ryuk) stay allowed.
- On `POST /containers/{id}/exec` it runs `validateExecEscape` (privileged/CapAdd
  exec — finding #7). The request path is normalized (version prefix, `//`,
  percent-encoding) before matching so a crafted create path can't dodge
  inspection (finding #6).

### Residual (known limitation)
The host-kernel-bind deny is by **lexical source path**. A devcontainer that has a
writable *shared* mount (its workspace) could plant a symlink there pointing at
`/proc/sys` and bind the symlink, which dockerd resolves on the sidecar fs — the
plugin sees only the (allowed) symlink path. Closing this fully needs either
dropping host-path binds entirely (breaks compose workspace mounts) or mounting the
shared workspace `nosymfollow` into the sidecar — tracked as future hardening. The
DIRECT bind attack (the practical exploit) is closed.

The plugin dir is mounted **read-only** into the sidecar: dockerd only connects to
the socket, never writes there. Without this, a nested container (binds are
allowed) could `-v /run/docker/plugins:/x` and delete/replace `huddle-authz.sock`
with an allow-all plugin — root bypasses dir perms, but a read-only mount blocks
the write at the VFS level even through a parent/root bind (recursive-bind
preserves the ro). Verified live: `rm` fails "Read-only file system" via
`/run/docker/plugins`, `/run`, and `/`.

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
