# Spike: rootless-dind sidecar (real isolation → drop the Docker control surface)

Branch: `experiment/dind-rootless` (off `experiment/dind`). Date: 2026-07-22.

## Why

Current DinD = `--privileged` sidecar + authz/HostConfig policy. The sidecar
shares the host kernel, so the policy (bind-allowlist, kernel-escape checks —
5 review rounds) is the *only* thing stopping a nested `--privileged` container
from escaping to the host VM. That reproduces the socket-proxy limitations
(nested privileged / kind / k3d refused) — the "worst of both" the user flagged.

Goal: make the **sidecar itself** the isolation boundary so we can `allow-all`
Docker ops and **delete** `host-config-policy.ts` / `dind-authz.ts` / the
socket-proxy HostConfig path. sysbox is out (Windows/WSL2 hosts). Rootless-dind
is the only WSL2-viable candidate. The egress firewall is unaffected either way
(it's the `--internal` dc-net, enforced by the host engine — see below).

## What the spike tested (host: WSL2, kernel 6.6, cgroup v2, userns on)

Ran `docker:28-dind-rootless` as a **non-privileged** container:
`--security-opt seccomp=unconfined --security-opt apparmor=unconfined --device /dev/fuse --device /dev/net/tun`.

### Works ✅
- **Runs non-privileged.** dockerd comes up, `overlay2` (native, not fuse),
  rootless, cgroupns, listens on `/run/user/1000/docker.sock`.
- **Breakout containment.** dockerd runs as unprivileged user `rootless`; an
  escape from the daemon lands as an unprivileged VM uid (subuid-mapped), not
  root. This is the inter-devcontainer isolation we want — a breakout would need
  a kernel LPE to touch a peer, vs today's "just pass `--privileged`".
- **allow-all runtime.** Nested containers run; nested `--privileged` runs
  (`CapEff=000001ffffffffff` inside the userns). So the control surface could be
  deleted — the runtime no longer needs policing.
- **Shared netns.** `--network container:<other>` — rootless dockerd still
  initializes inside a joined netns (didn't reject it).

### Blockers ❌ / open ⚠️
- **❌ Nested bridge networking fails on WSL2.** rootlesskit's userns netns has
  **read-only** `/proc/sys/net/ipv6/*`. dockerd fails both paths:
  - v4-only network → `failed to disable IPv6 on container's interface eth0`
  - v6 network → `failed to set IP forwarding .../ipv6/conf/default/forwarding: read-only file system`
  ipv6 is enabled+writable on the WSL2 *host*; the restriction is specific to the
  rootless userns netns (known rootless limitation). Outer `--sysctl
  net.ipv6.conf.all.disable_ipv6=1` did not help; `--network none` works but is
  useless for real workloads. **This blocks Aspire/compose/testcontainers** and
  must be solved before rootless is viable. Fixes are non-trivial (dockerd can't
  currently skip the ipv6 sysctl write; needs a rootlesskit/kernel or upstream
  change).
- **⚠️ Shared-netns published-ports-on-localhost — UNVALIDATED.** Aspire needs a
  nested container's published port to land on the devcontainer's `localhost`
  (current privileged design gets this via shared netns). Rootless-dind normally
  inserts a rootlesskit/slirp port-driver layer; how published ports surface in a
  *joined* netns is untested (blocked behind the ipv6 issue). This is the second
  hard integration question.
- **⚠️ No cgroup delegation** → no CPU/memory limits on nested containers
  (`Cgroup Driver: none`; needs systemd-in-sidecar). Minor.

## Verdict

Rootless-dind delivers exactly the security shape we want (non-privileged
sidecar, contained breakout, allow-all → delete the control surface). But it is
**not a drop-in on WSL2**: nested networking is broken by the rootlesskit ipv6
sysctl restriction, and the shared-netns published-port model — the thing Aspire
depends on — is unproven and likely needs rework. Both are real engineering, not
config flips.

Options:
1. **Invest**: solve the WSL2 rootless networking (ipv6 skip + port model),
   validate Aspire/compose end-to-end, then delete the control surface. Medium
   effort, some upstream-dependency risk.
2. **Defer**: keep the validated `--privileged` + authz model (works today, full
   E2E green) and revisit rootless when the networking work can be scheduled.

The egress firewall is orthogonal and stays regardless: `dc-net-<name>` is
`Internal: true` (`docker.ts:317`), so the devcontainer has no internet route
except the huddle proxy — enforced by the host engine, untouchable from inside,
unaffected by allow-all.
