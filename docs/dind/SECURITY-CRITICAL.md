# CRITICAL: DinD privileged host escape (finding C1)

**Status: MITIGATED (2026-07-18) — host-escape filter enforced on the private
daemon. Escape red test `gateway/test/dind-compat/e2e-escape.sh` is GREEN.**

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
A lean per-container **host-escape filter** (`gateway/src/dind-filter.ts`) sits
between the devcontainer and its private daemon:

- Socket topology: the sidecar `dockerd` listens on `inner.sock`; the gateway
  serves `docker.sock` (the filter) in the shared dir `/tmp/dc-sockets/<name>`
  (mounted `/var/run/dind` in both sidecar and devcontainer). The devcontainer's
  `DOCKER_HOST` points at the **filter**, never `inner.sock` directly.
- It is a real streaming HTTP/1.1 proxy: it parses **every** request on a keep-
  alive connection (so a privileged create pipelined after a benign request can't
  be smuggled past inspection) and forwards each unmodified. On a hijack
  (interactive exec/attach) it raw-tunnels the rest, preserving **half-open**
  (docker's exec streams half-close stdin then read output — without half-open the
  output is silently dropped: the bug the manual Aspire probe surfaced).
- On `POST /containers/create` it runs `validateDindEscape(HostConfig)` and denies
  with `403` only the **device/kernel/namespace** vectors: `Privileged`,
  `Devices`/`DeviceCgroupRules`/`DeviceRequests`, `CapAdd`, host `PidMode`/
  `IpcMode`/`UsernsMode`/`CgroupnsMode`/`UTSMode`, `CgroupParent`, `Sysctls`,
  unconfined `SecurityOpt`, per-device Blkio limits.
- **Binds/Mounts/VolumesFrom stay ALLOWED** — in DinD a bind source resolves
  against the *disposable sidecar* fs, not the host, so compose/testcontainers
  workspace mounts work. The one exception: a bind whose source reaches the
  daemon's own control socket dir (`/var/run/dind`, `/run/dind`, or any ancestor
  like `/var/run` / `/run` / `/`) is denied — that would let a nested container
  talk to the UNFILTERED `inner.sock` and bypass the filter.

Net effect: the escape is closed **and** the tool-compat wins the classic socket-
proxy broke (inspect, networks, port-publish, archive/CopyFile, exec, build,
non-privileged run, host-path binds) all work. This is strictly better than the
classic proxy on compat while matching it on host-escape safety.

## Cost / known limitation
Tools that need a genuinely `--privileged` nested container (kind/k3d/minikube
worker nodes, dind-in-dind, some nested-systemd setups) are refused in DinD mode.
Everything else works, including **Testcontainers with its Ryuk reaper**: binding
the FILTER socket (`/var/run/dind/docker.sock`) into a nested container is allowed
because that container then talks THROUGH the filter and still cannot create a
privileged/escaping container (verified live in `e2e-escape.sh`). Only the
UNFILTERED `inner.sock` / the socket dir / its ancestors are refused. Aspire,
compose, buildx (default builder), Testcontainers all work.

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
- `gateway/test/dind-compat/e2e-escape.sh` — live red test: privileged/device
  escape refused, host fs unreachable, socket-dir bypass closed, benign bind still
  forwarded.
- `gateway/test/dind-filter.test.ts` — unit + socket-level: create inspection,
  hijack half-open output delivery, pipelining, `validateDindEscape` edge cases.
- `gateway/test/dind-compat/tools/privileged.sh` — compat-battery variant.
