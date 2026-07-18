# CRITICAL: DinD privileged host escape (finding C1)

**Status: OPEN — do NOT use HUDDLE_DIND=1 for UNTRUSTED devcontainers until fixed.**

## The issue
In DinD mode each devcontainer gets an unrestricted private Docker daemon whose
sidecar (`dind-<name>`) runs `--privileged`. A privileged nested container inside
a privileged sidecar **sees the host's block devices and kernel**, so an untrusted
devcontainer can take over the host with zero operator interaction:

```
docker run --rm --privileged alpine sh -c 'mount -o ro /dev/sdg /m; cat /m/etc/shadow'
```

**Verified on the live env (2026-07-18):** a nested `--privileged` container saw
`/dev/sda`–`/dev/sdh` (sizes matching the host `/proc/partitions`), mounted host
disk `/dev/sdg`, read the real host `/etc/hostname` (`ISNL-HBJ7BH4`), the host
`os-release` (Debian 13), and **read `/etc/shadow`**. From there: the CA private
key, operator token, DB, every peer devcontainer, the host itself.

The design premise ("only the sidecar is privileged, isolation preserved") is
**wrong**: `--privileged` is not a boundary against an attacker who controls what
runs inside the daemon. This *adds* risk vs the classic socket-proxy (which
hard-denies `Privileged`/`Devices`/host-binds) — the opposite of the goal.

## Fix options (evaluated)
- **Rootless dind** (unprivileged, user-namespaced daemon) — the proper boundary,
  but **incompatible with the shared-netns model** (rootlesskit needs its own
  netns; `ip tuntap add tap0` fails under `--network container:<dc>`), and that
  shared netns is what makes published ports land on the devcontainer's localhost
  (the Aspire fix). Would require redesigning networking.
- **userns-remap on the sidecar daemon** — Docker **disables userns for
  `--privileged` containers**, so it does NOT stop the escape.
- **Non-privileged sidecar with curated caps + no host `/dev`** — dockerd starts
  but nested `docker run` fails (runc/cgroup fifo errors); needs more work.
- **Re-impose host-escape HostConfig denials on the private daemon** (block
  `Privileged`/`Devices`/`DeviceCgroupRules`/sensitive host-binds/unconfined
  `SecurityOpt`) via a filter co-located with the sidecar, while keeping
  everything the socket-proxy wrongly blocked (inspect/networks/ports/volumes-from/
  archive) OPEN. This closes the escape and preserves the tool-compat wins
  (Aspire, Testcontainers, compose, …). Cost: `--privileged`-requiring tools
  (kind/k3d/minikube nodes) would be blocked in DinD mode unless an operator opts
  a devcontainer into "trusted/privileged" explicitly. **This is the chosen
  mitigation.**

## Interim guidance
Until the mitigation lands: `HUDDLE_DIND=1` is safe ONLY for TRUSTED workloads.
The default classic socket-proxy model is unaffected (it hard-denies these
vectors). Red test: `gateway/test/dind-compat/e2e-escape.sh`.
