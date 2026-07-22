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

### Both hard blockers SOLVED (2026-07-22, round 2)
- **✅ Nested networking — fixed with `--security-opt systempaths=unconfined`.**
  Root cause was NOT ipv6 per se: `/proc/sys` is mounted **read-only** in the
  non-privileged sidecar (runc default masking), so dockerd can't write ANY net
  sysctl (the ipv6 disable/forwarding just happened to be first). `systempaths=
  unconfined` unmasks `/proc` without going privileged → nested bridge
  networking works: `BRIDGE-OK` 172.17.0.2, egress ok, nested `--privileged` ok.
- **✅ Shared-netns published-ports-on-localhost — WORKS.** rootless sidecar with
  `--network container:<devcontainer>`: an inner `nginx -p 8080:80` is reachable
  as `curl localhost:8080 → 200` from the devcontainer's netns, listening on the
  shared netns. rootlesskit did not hide it behind its own netns. This is exactly
  the Aspire DCP model — the make-or-break test, passed.
- **✅ Breakout containment holds even with `systempaths=unconfined`.** Nested
  `--privileged`: mount host disk DENIED, no host block devices, host sysctl
  write denied, sees only its own PIDs. Sidecar dockerd runs as host **uid 1000,
  not root** — a breakout lands unprivileged (vs host-root today).

### Remaining ⚠️
- **Per-sidecar uid for solid inter-devcontainer isolation.** All rootless
  sidecars run as the SAME host uid (1000). A breakout to uid 1000 could
  ptrace/signal a *peer* devcontainer's sidecar (same uid, VM init pidns). Fix:
  give each sidecar a distinct host uid (per-devcontainer uid, or host
  userns-remap). Still strictly better than the current privileged model
  (breakout = host root). Needs design.
- **No cgroup delegation** → no CPU/memory limits on nested containers
  (`Cgroup Driver: none`; needs systemd-in-sidecar). Minor.
- **`systempaths=unconfined` unmasks /proc** — acceptable under a userns (writes
  hit the userns-owned netns; /proc/kcore needs real caps), but note the reduced
  hardening.

## BUILT + validated (2026-07-22, round 3)

Wired into the gateway behind `HUDDLE_DIND_ROOTLESS=1` (`dind.ts`
`createRootlessSidecar`, `cli/init.ts` env passthrough). Validated live through
the REAL gateway:
- sidecar `docker:28-dind-rootless`, **privileged=false**, MaskedPaths/
  ReadonlyPaths emptied (API form of `systempaths=unconfined`).
- devcontainer → rootless dockerd OK; **dockerd pulls through the MITM proxy**
  (CA via `SSL_CERT_DIR`, no trust-store write).
- nested published port → 200 from the devcontainer loopback (Aspire model +
  docker0/br+ egress fix).
- nested `--privileged` runs (allow-all) yet host mount DENIED / no host disk
  (contained; breakout = unprivileged uid).
- **Full Aspire project→SqlServer E2E GREEN** (`e2e-aspire-project-ef.sh` with
  `HUDDLE_DIND_ROOTLESS=1`): build via proxy, EF DB round-trip `count:1`,
  dashboard http, no gRPC UntrustedRoot. All 7 assertions pass.

API gotcha: `--security-opt systempaths=unconfined` is CLI sugar — the Docker
API needs `HostConfig.MaskedPaths=[]` + `ReadonlyPaths=[]` (a `systempaths=...`
SecurityOpt entry is rejected 500).

### Follow-ups before this replaces the privileged model
- Real dashboard validation (Blazor circuit / resource-service gRPC at runtime,
  not log-greps) — user reports the dashboard "does not work"; needs their exact
  error. e2e only greps logs today.
- Per-sidecar distinct host uid for airtight inter-devcontainer isolation (all
  rootless sidecars share host uid 1000 → a breakout could ptrace a peer
  sidecar). Still strictly better than privileged=host-root.
- No cgroup delegation → no nested resource limits (minor).
- Delete `dind-authz.ts` / `host-config-policy.ts` / socket-proxy HostConfig path
  once rootless graduates from experiment to default.

## Verdict — GREEN to build

Rootless-dind delivers the security shape we want (non-privileged sidecar,
contained breakout, allow-all → delete the control surface) AND both hard
integration blockers (nested networking, shared-netns published ports) are
solved on WSL2. Required sidecar flags: `--security-opt seccomp=unconfined
--security-opt apparmor=unconfined --security-opt systempaths=unconfined
--device /dev/fuse --device /dev/net/tun`, image `docker:<ver>-dind-rootless`,
socket `/run/user/1000/docker.sock`.

Build plan: (1) wire a rootless sidecar variant into `dind.ts` behind
`HUDDLE_DIND_ROOTLESS`; (2) run the Aspire + nested-published-port E2Es against
it, incl. REAL dashboard validation (resource-service gRPC + Blazor circuit, not
just log-greps); (3) with rootless proven, gate/remove the authz/HostConfig
control surface (no longer the isolation boundary); (4) design per-sidecar uid
for inter-devcontainer isolation.

Egress firewall stays regardless: `dc-net-<name>` is `Internal: true`
(`docker.ts:317`), host-enforced, untouchable from inside, unaffected by
allow-all.

The egress firewall is orthogonal and stays regardless: `dc-net-<name>` is
`Internal: true` (`docker.ts:317`), so the devcontainer has no internet route
except the huddle proxy — enforced by the host engine, untouchable from inside,
unaffected by allow-all.
