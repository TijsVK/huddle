# Research: Huddle as a native Rust binary, microVM devcontainers, Tauri portal

Date: 2026-08-18
Status: feasibility investigation — no code written, no decision taken
Baseline: `origin/main` @ `e16b4d6` (all line counts and file names below are main's, not the
`experiment/dind*` branches)
Related (both on branch `worktree-research-isolation-backing-layer`):
`docs/research/2026-08-isolation-backing-layer.md`, `docs/research/2026-08-S2-sysbox-spike-results.md`

## 0. The question, restated

Rework Huddle so that:

1. Huddle itself is a **Rust binary running natively on Windows** — not a container, not a
   process inside a WSL2 distro.
2. Devcontainers become **microVMs**, spawned through
   [**microsandbox**](https://github.com/superradcompany/microsandbox) (Super Rad Company,
   ex-Zerocore AI; Apache-2.0; Rust; libkrun-based).
3. The operator UI ships as a **Tauri** desktop app, ideally reusing the existing Angular SPA.

This supersedes the compute-plane part of the earlier backing-layer research, which concluded
"Sysbox-primary" **under the assumption that the VMM would have to live inside the WSL2 distro**.
Running Huddle natively on Windows removes that assumption, and with it the blocker that decided
against VMs. §8 reconciles the two verdicts.

## 1. Verdict

**Feasible, and architecturally a large simplification — with one hard external gate, one product
question, and one dependency risk.**

- The gate: `HypervisorPlatform` (WHP) is **not enabled** on this laptop and enabling it needs
  elevation plus a reboot (§2). Everything else about the platform story is already in place.
- The product question: a per-laptop desktop app makes the developer the operator. Huddle's threat
  bar (contain supply-chain malware and runaway agents — not the developer) survives that, but the
  "central portal in control" claim in the README does not, unless a signed central policy feed is
  added (§6.4).
- The dependency risk: microsandbox is **beta** (v0.6.9, 2026-08-15; README says "expect breaking
  changes"). Mitigate by keeping a compute-plane trait with the Docker/Sysbox path behind it, not
  by hedging on the design.

The single most valuable finding: **microsandbox already implements, host-side and unbypassable,
the majority of what `gateway/src` hand-rolls** — deny-by-default egress policy over
domains/CIDRs/ports, DNS control, TLS interception with guest trust-store injection, host-side
secret injection, port publishing, bind mounts, snapshots, nested Docker, and SSH without an sshd
in the guest. The rework is therefore less "port main's 6 981 lines of TypeScript to Rust" and more
"delete about half of it, and keep the policy/approval/audit/portal plane that is actually
Huddle's product."

## 2. Measured on this machine (2026-08-18)

| Check | Result | Meaning |
|---|---|---|
| `ls /dev/kvm` in WSL2 | absent | no KVM inside the distro |
| `modprobe kvm_intel` | `kvm_intel: VMX not supported by CPU 13` | the utility VM is not given VMX |
| `.wslconfig` | `[wsl2] nestedVirtualization=true`, dated 2026-05-28 | the opt-in is present and predates this boot, so this is **not** a "forgot to restart WSL" case |
| WSL / kernel | 2.7.3.0, kernel 6.6.114.1-1, `CONFIG_KVM=m` | kernel supports KVM, the hardware exposure is what is missing |
| Windows | 11 Enterprise 26200.9106 | — |
| CPU | Intel Core Ultra 7 265H | supports VT-x/EPT; the WMI `VirtualizationFirmwareEnabled=False` reading is the usual artefact of Hyper-V already owning the CPU |
| VBS / Device Guard | `VBSStatus=2` (running), `SecurityServicesRunning=1,2,3,4,7` | Credential Guard + HVCI active; this is the known antagonist of nested virtualisation ([microsoft/WSL#5030](https://github.com/microsoft/WSL/issues/5030)) |
| `VirtualMachinePlatform` | Enabled | WSL2/Docker Desktop path |
| `Microsoft-Hyper-V-Hypervisor` | Enabled | the hypervisor is already running |
| **`HypervisorPlatform` (WHP)** | **Disabled** | **the one thing microsandbox needs on Windows** |
| `%USERPROFILE%\.microsandbox` | absent | msb not installed yet |

Two conclusions follow.

**(a) The native-Windows framing is not a preference, it is the only path on this hardware.**
A microVM plane *inside* WSL2 is dead here: no VMX reaches the distro, and the likely cause
(VBS/Credential Guard, corporate-managed) is not ours to switch off. WHP, by contrast, is a
**root-partition** API on top of the already-running Hyper-V hypervisor — it needs no nested
virtualisation, so the VBS conflict does not apply to it. That is exactly why microsandbox's own
docs stress that `HypervisorPlatform` is a *different* feature from the `VirtualMachinePlatform`
that WSL2 and Docker Desktop enable.

**(b) The first spike is a one-line elevated command plus a reboot:**

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart
# reboot, then:
msb doctor
```

Unknown until tried: whether corporate policy permits it, and whether WHP + VBS coexist cleanly on
this image. Everything downstream in this document is blocked on that check, so run it first.

## 3. What microsandbox actually provides

Verified against [docs.microsandbox.dev](https://docs.microsandbox.dev) (fetched 2026-08-18) and
the repo (7 586 stars, Apache-2.0, Rust, last push 2026-08-18, v0.6.9 released 2026-08-15).

| Capability | Detail | Huddle equivalent today |
|---|---|---|
| Boundary | microVM per sandbox via **libkrun**: KVM on Linux, Hypervisor.framework on Apple Silicon, **WHP on Windows** (preview) | Linux namespaces + a per-container filtered Docker socket (`socket-proxy.ts`) |
| Images | pulls **standard OCI images** from any registry; boots them directly as the VM rootfs | `ghcr.io/infosupport/base-devimage-*` — already OCI, already published |
| Egress policy | host-enforced: `default_egress: allow\|deny` + ordered first-match rules over `public`/`private`/`host` groups, IPs, CIDRs, **domains**, port ranges. Private/loopback/link-local/cloud-metadata denied by default | `proxy.ts` + `rules.ts` + in-container iptables |
| DNS | pinned nameservers, domain blocking, rebinding protection | `dns-egress.ts` |
| TLS | interception with an auto-generated CA **added to the guest trust store**, per-host bypass list, URL policy checks, request logging | `tls-ca.ts` + CA baked into images (and the recurring nested-CA breakage) |
| Secrets | credential stays on the host; guest gets a placeholder that is swapped for the real value **at the network boundary**, only for allow-listed hosts | tokens handed into the container |
| Ports | `-p 8080:80`, binds `127.0.0.1` by default | `docker run -p` + published-port DNAT gymnastics |
| Host reach | `host.microsandbox.internal`, denied unless the `host` group is allowed | `dc-net-*` + gateway IP |
| Files | **bind mounts of host dirs over virtiofs** with `ro,noexec,nosuid,nodev,host-perms=private\|mirror`; named volumes (virtiofs or ext4/virtio-blk); disk images; tmpfs | docker volumes/binds |
| Nested Docker | documented: `docker:dind` in a sandbox, with `--root-disk flat:10G` or a disk-backed volume for `/var/lib/docker`; host daemon untouched | on main: not supported — demanding tools break against the socket-proxy policy; the `experiment/dind` branch tried to fix that with a `--privileged` sidecar plus an authz plugin |
| SSH | SSH spoken **host-side**, no sshd in the guest: native sessions, a `127.0.0.1:2222` TCP listener, or `--stdio` for `ProxyCommand`; shells, exec, SFTP, `-L`/`-D` forwarding | `terminal.ts` + `pty-manager.ts` via docker exec |
| Snapshots | writable layer captured to a portable artefact; **sandbox must be stopped** | `docker commit` on a running container |
| Lifecycle | detached/long-running, `modify()` with a change plan labelling each field `live` / `next start` / `requires restart` / `unsupported`, idle timers, ping/touch | docker start/stop |
| Embedding | Rust SDK: `Sandbox::builder(..).create()` boots the VM as a **child process** — no daemon, no server | Docker Engine API over a socket |
| Rate limits | per-direction bandwidth and packet-rate token buckets | none |
| Boot | claimed <100 ms average; third-party measurement ~320 ms for a full VM | container start |

Two gaps matter (both revisited in §7):

- **Network policy is not in the documented `modify()` set** (CPUs, memory, env, labels, workdir,
  secrets are). Approving a new domain may therefore require a restart — which would break
  Huddle's core interaction, where an operator approves a request and the blocked call succeeds on
  retry.
- **No documented decision hook or audit stream** for policy verdicts. Huddle needs "this request
  was denied, ask the operator, then allow it" as a live event, not a static config.

## 4. Target architecture

```
Windows host (native, no WSL2 in the path)
│
├─ huddle.exe            Rust, single binary, Tauri shell + embedded services
│   ├─ WebView2 → Angular SPA (unchanged app code)
│   ├─ axum        REST + WebSocket API (localhost, token-authed)  → browser mode still works
│   ├─ rules engine + SQLite (rusqlite)                             → audit, grants, approvals
│   ├─ MITM proxy (hyper + rustls + rcgen)                          → the policy chokepoint
│   └─ compute plane trait
│        ├─ MicroVm(microsandbox Rust SDK)   ← primary
│        └─ Docker/Sysbox (legacy, optional) ← escape hatch, same interface
│
└─ per workspace: one microVM (libkrun/WHP)
     ├─ rootfs = ghcr.io/infosupport/base-devimage-<ide>  (OCI, unchanged)
     ├─ bind mount: C:\...\workspace → /workspaces/<name>  (virtiofs)
     ├─ network: default_egress=deny; allow host:<proxy port>; allow DNS
     ├─ nested dockerd on a flat root disk / disk-backed volume  → Aspire, Testcontainers, kind
     └─ SSH (host-side, 127.0.0.1:<port>)                        → JetBrains Gateway, VS Code
```

### 4.1 The one design decision that de-risks everything

**Keep Huddle's own proxy as the policy chokepoint; use microsandbox's network policy only as a
static floor.**

Set each sandbox to `default_egress: deny` with exactly two allowances: DNS, and TCP to
`host.microsandbox.internal` on the Huddle proxy port. Then:

- every dynamic decision — per-domain rules, time-bound grants, path-level rules, the
  approve/deny/request UX, the audit log, the live WebSocket push — stays in Huddle, unchanged in
  behaviour, and needs no beta-stage feature from microsandbox;
- the static floor never changes at runtime, so the missing live-policy-update path (§3) stops
  being on the critical path;
- the boundary claim gets *stronger* than today: there is no L3 route out of the VM except the
  proxy, enforced host-side, so guest root cannot bypass it — this is the "no route but the proxy"
  chokepoint the earlier research ranked strongest, now with a hardware boundary under it;
- `localhost` semantics become trivial again inside a VM, which deletes the shared-netns
  contortions the `experiment/dind` branch needed (and the nested-published-port DNAT bug they caused).

Migrating later to microsandbox-native policy + secret injection + TLS interception is then a
second, optional step — worth taking once live policy updates and a decision/audit stream exist
upstream (a plausible contribution: Apache-2.0 upstream, GPL-3.0 downstream, compatible direction).

## 5. Codebase impact

**Baseline: `origin/main` @ `e16b4d6`** — not the `experiment/dind*` branches. On main,
`gateway/src` is **6 981 LOC** TypeScript (tests 3 665; Angular frontend 7 700; `cli/src` 2 179;
`huddle.ps1` 587). The DinD experiment's files (`dind.ts`, `dind-authz.ts`,
`host-config-policy.ts`, `root-grant.ts`) do **not** exist on main; main's equivalent controls are
`socket-proxy.ts`, `docker-actions.ts` and `sudo-grant.ts`.

**Deleted outright** — the runtime boundary makes them meaningless. This is the Sysbox takeaway
carried over verbatim: *once the boundary is the runtime, the Docker-API policy engine is not
needed*. That conclusion was reached for Sysbox and holds identically, and more strongly, for a
microVM.

| File (main) | LOC | Why it dies |
|---|---|---|
| `socket-proxy.ts` | 1 158 | no filtered Docker window, no label isolation, no per-container socket — the VM has its own daemon |
| `docker-actions.ts` | 215 | the action allowlist and its time-limited grant timers, plus the portal page driving them |
| `dns-egress.ts` | 154 | DNS policy is runtime-owned (pinned resolvers, rebinding protection) |
| `sudo-grant.ts` | 135 | the locked `noot` admin account and its one-shot passwords: root inside your own disposable VM is not a privilege boundary (see §6.4) |
| **subtotal** | **1 662** | ≈ 24 % of `gateway/src` |

Plus, in `docker.ts`: the 20 in-container `iptables` call sites demote from boundary to
UX/defence-in-depth.

**Never needs to be built** — work that exists only on the experiment branches and is superseded
rather than merged: `dind.ts` (469), `host-config-policy.ts` (235), `dind-authz.ts` (156),
`root-grant.ts` (89) ≈ **949 LOC**, together with the `--privileged` sidecar, the dockerd
authorization plugin, the bind-source allowlist, the `nosymfollow` remount, the shared-netns
`localhost` contortions and the nested-published-port DNAT fix. The still-unpatched
case-insensitive `HostConfig` bypass class disappears with the surface that hosts it.

**Replaced** (same responsibility, different mechanism):

| File (main) | LOC | Becomes |
|---|---|---|
| `docker.ts` | 1 102 | compute-plane trait + microsandbox SDK calls; the JetBrains/VS Code bootstrap scripts survive as guest-side provisioning |
| `terminal.ts` + `pty-manager.ts` | 299 | microsandbox exec/SSH streams instead of docker exec |
| `tls-ca.ts` | 125 | `rcgen` (or microsandbox's CA) |
| **subtotal** | **1 526** | |

**Ported to Rust, semantics unchanged** — this is the product: `api.ts` (1 033), `proxy.ts` (956),
`db.ts` (562), `rules.ts` (423), `extensions/` (291), `workspace-flow/` (169), `auth.ts` (149),
`index.ts` (92), `token-exchange.ts` (63), `worktree.ts` (48), `events.ts` (7) = **3 793 LOC**
of TypeScript → Rust. Mechanical but real, and main's **3 665 LOC of tests** are the specification
to port alongside them.

(1 662 deleted + 1 526 replaced + 3 793 ported = 6 981, the whole of `gateway/src`.)

**New work** (the honest cost):

- compute-plane trait + microsandbox implementation, with capability reporting so the portal can
  state which mode a workspace runs in;
- IDE attach over SSH for both JetBrains Gateway and VS Code, replacing today's
  attach-to-running-container path, including gateway-link discovery;
- devcontainer semantics (§6.3);
- image supply on a machine with no host Docker (§6.5);
- Windows packaging, code signing, updater (§6.2);
- snapshot semantics against a stop-required snapshot model.

## 6. The Rust + Tauri side

### 6.1 Crate mapping

| Today | Rust |
|---|---|
| Fastify | `axum` (+ `tower-http` for static/SPA fallback) |
| `ws` | `axum::extract::ws` / `tokio-tungstenite` |
| `better-sqlite3` | `rusqlite` (bundled SQLite) |
| `node-forge` + custom CA | `rcgen` + `rustls` |
| HTTP/CONNECT MITM proxy | `hyper` + `rustls` + `rcgen` |
| `adm-zip` | `zip` |
| Docker Engine API | `bollard` (only for the legacy compute plane) |
| PTY | microsandbox exec/SSH; `portable-pty` only if a host-side PTY is ever needed |
| Docker-in-Docker orchestration | *gone* |

### 6.2 Tauri

- The Angular 21 SPA is reusable **as-is**: Tauri v2 serves a static SPA build, and the app already
  talks to `/api/...` over HTTP + WebSocket. Keep the axum server bound to loopback and let the
  webview talk to it — that keeps browser mode working for shared/server deployments and avoids
  rewriting the frontend against Tauri IPC. `@xterm/xterm` works unchanged in WebView2.
- Frontend changes are small and localised: the login/token flow (`auth.interceptor.ts`,
  `auth.service.ts`) can pull the operator token from the Tauri app instead of a browser prompt,
  and the CSP must allow `ws://127.0.0.1:<port>`.
- Distribution: one signed `.exe` + MSI/NSIS bundle replaces the Docker image, `huddle.ps1`
  (587 LOC) and the Node CLI (1 273 LOC). New obligations: Authenticode signing, an updater story,
  SmartScreen/AV reputation, and an Intune-friendly installer. Note also the documented Windows
  Defender Firewall prompt on the first published port.
- microsandbox can be embedded two ways: link the **Rust SDK** (preferred — VMs are child
  processes of `huddle.exe`, no daemon) or ship `msb.exe` as a Tauri `externalBin` sidecar
  (useful early, for `msb doctor --fix` and for the interactive attach flows the docs say want a
  real console).

### 6.3 devcontainer semantics

"MicroVMs as devcontainers" splits into two designs; they can coexist:

- **Native mapping** — Huddle reads `devcontainer.json` and maps image, mounts, ports, env,
  lifecycle hooks and `customizations.jetbrains` onto a sandbox. Fast, no nesting, covers Huddle's
  own base images (which is what the portal offers today). Does not cover Features, Compose-based
  devcontainers, or `postCreate` semantics in full.
- **Full fidelity** — boot the VM with nested `dockerd` and run the upstream Dev Containers CLI
  *inside* it. Everything in the spec works, at the cost of one extra layer and a slower first
  start. This is the same nesting the DinD experiment wanted, except an escape now lands in a guest
  kernel rather than on the host.

Recommendation: native mapping as the default path, nested-CLI as an opt-in per workspace.

### 6.4 Who is the operator

If Huddle is a desktop app on the developer's laptop, the developer can approve their own firewall
rules. That is consistent with the stated threat bar (malware and runaway agents, not the
developer) but it is *not* what the README currently claims. Decide explicitly:

- **Local authority** (simplest): the developer approves; the audit log is local; Huddle's value is
  containment and visibility. State it plainly in the docs.
- **Central policy feed** (later): a signed org-level allow/deny set fetched from a server, with
  local additions logged and optionally reported. Needs signing, refresh and tamper-evidence
  design — not a v1.

The same call has to be made about main's third security principle, **"No root user"**. Today it is
implemented by `sudo-grant.ts`: a locked `noot` admin account that the operator unlocks with a
fresh one-shot password for a bounded window. Inside a disposable microVM, guest root buys an
attacker nothing the VM does not already grant — the boundary is host-side and the workspace is
throwaway — so the mechanism stops being a boundary. Restate the principle as **"root is confined
to the VM"** and keep, at most, a no-sudo-by-default UX to slow accidental damage. Do not keep the
grant timers, the password issuance or the audit weight attached to them.

### 6.5 Images without a host Docker

`docker.ts` currently falls back to building `base-devimage-*` locally from a mounted Dockerfile.
On a native Windows host there is no Docker to build with. Options: rely on the already-published
`ghcr.io/infosupport/base-devimage-*` (CI publishes them today — the cheapest answer), or build
inside a microVM with nested `dockerd` when a local build is genuinely needed. Registry pull volume
per VM argues for a host-side pull-through cache, as the earlier research noted.

## 7. Risks and the spikes that settle them

Ordered by how much they can change the plan. Each has a pass/fail.

| # | Risk | Spike | Pass |
|---|---|---|---|
| S1 | WHP unavailable or policy-blocked on managed laptops | enable `HypervisorPlatform`, reboot, `msb doctor` | doctor green with VBS still on |
| S2 | Huddle's base image does not boot as a microVM rootfs | `msb run ghcr.io/infosupport/base-devimage-vscode` | shell, correct user, tools present |
| S3 | **Live policy updates**: approving a domain needs a VM restart | `msb modify` / SDK `modify()` on a network field; read the returned change plan | either `live`, or the §4.1 design confirmed as the answer |
| S4 | Egress chokepoint leaks | deny-all + allow host proxy port only; from guest root try direct IP, UDP, DNS tunnel, alternate ports | only the proxy path works |
| S5 | virtiofs performance on a Windows host dir | `dotnet restore` + `npm ci` on a real repo, bind-mounted from NTFS; also git case-sensitivity and `host-perms` | within ~2× of native; git clean |
| S6 | IDE attach | JetBrains Gateway + VS Code Remote-SSH against `msb ssh serve` (TCP listener), idle timeout disabled | both attach, backend starts, ports forward |
| S7 | Nested Docker workloads | port the existing `docs/dind` compat battery: Aspire E2E (incl. the real-browser dashboard harness), Testcontainers, kind, `act` | same or better than the DinD branch |
| S8 | Memory footprint | 3 concurrent workspaces, each with an IDE backend + nested dockerd | fits a 32 GB laptop |
| S9 | Snapshot regression | snapshot requires a stopped sandbox | portal flow adapted, or `docker commit` inside the VM used instead |
| S10 | Beta churn / project risk | pin versions; keep the compute-plane trait; track upstream releases | breaking change absorbable in days, not weeks |
| S11 | Windows Terminal/PTY fidelity for the portal's xterm | exec/SSH stream through axum WS into xterm, resize + signals | interactive shell usable |

S1 → S2 → S6 → S4 → S7 is the critical chain; S3 and S5 decide how much design work is needed
around the chokepoint and the workspace mount.

## 8. Reconciling with the Sysbox verdict

**What carries over unchanged is the conclusion, not the runtime.** The Sysbox spike established
that once the boundary is the *runtime*, Huddle no longer needs to police the Docker API at all:
the filtered socket, the action allowlist, the label isolation and the time-limited Docker grants
exist only because a container shares the host kernel and a host daemon. That reasoning is
runtime-agnostic and a microVM satisfies it more strongly than Sysbox does — so main's
`socket-proxy.ts` + `docker-actions.ts` (1 373 LOC, §5) come out under either plane, and the
`experiment/dind` attempt to make Docker-in-Docker safe by *adding* policy (authz plugin,
`HostConfig` allowlist) is superseded rather than merged.

What changed is only *which* runtime: the earlier research picked Sysbox because a microVM would
have had to live inside the WSL2 distro, where there is no KVM (§2 re-confirms this, now with the
`VMX not supported` line and the VBS context). Native-Windows Huddle removes that constraint, and
microsandbox additionally covers macOS (Hypervisor.framework) and Linux (KVM) with one API — which
is what the three-platform requirement asked for.

Proposed positioning:

- **Primary:** microsandbox microVMs — Windows (WHP), macOS (Apple Silicon), Linux (KVM).
- **Fallback:** the existing Docker plane, ideally with `sysbox-runc` (already installed and
  spike-verified on this box), for hosts with no hardware virtualisation — VDI, WSL2-only setups,
  CI. Label it honestly as "shared kernel" in the portal.
- **Dropped in both worlds:** the Docker-API policy engine on main, and the `--privileged` sidecar
  plus dockerd authz plugin on the experiment branch.

The Sysbox work is not wasted: it is the fallback plane, and it keeps the compute-plane trait
honest by forcing two implementations from day one.

## 9. Phasing

1. **Gate** (hours): S1 + S2. If WHP cannot be enabled on the fleet's laptops, stop — everything
   else is moot, and Sysbox-primary stands.
2. **Thin vertical slice** (1–2 weeks): a `huddle.exe` that boots one workspace microVM from the
   published base image, binds a workspace dir, applies the static deny-all + proxy-only floor,
   proxies egress through a minimal Rust MITM proxy, and attaches VS Code over SSH. No portal, no
   DB, no rules UI. Settles S4, S5, S6.
3. **Compute-plane trait + Rust port of the policy plane** (the bulk): rules, db, api, proxy, auth,
   events, extensions, with the existing test suite ported alongside.
4. **Tauri shell** with the Angular SPA reused, plus packaging and signing.
5. **Nested-Docker compatibility** (S7) using the `docs/dind` battery from the experiment branch as
   the acceptance suite — the tests are worth keeping even though the implementation is not.
6. **Snapshots, worktrees, extensions, CLI parity**, then delete main's Docker-control plane
   (`socket-proxy.ts`, `docker-actions.ts`, `sudo-grant.ts`, `dns-egress.ts`) and close the
   `experiment/dind*` branches unmerged.
7. **Optional:** move policy/secrets/TLS to microsandbox-native, upstreaming live policy updates and
   an audit stream if they are still missing.

## 10. What I would do first

Run S1. It is one elevated command, a reboot and `msb doctor`, and it is the only finding in this
document that can invalidate the whole direction.

## Sources

- [superradcompany/microsandbox](https://github.com/superradcompany/microsandbox) — repo, README, releases
- [microsandbox docs](https://docs.microsandbox.dev) — networking overview, DNS, TLS interception, host sockets, volumes, SSH, lifecycle, secrets, snapshots, configuration, Windows troubleshooting, Docker-in-a-sandbox
- [Your Container Is Not a Sandbox: The State of MicroVM Isolation in 2026](https://emirb.github.io/blog/microvm-2026/)
- [libkrun/krunvm](https://github.com/libkrun/krunvm), [Running Linux microVMs on macOS](https://www.sinrega.org/running-microvms-on-m1/)
- [Firecracker host filesystem sharing (#1180)](https://github.com/firecracker-microvm/firecracker/issues/1180) — no virtio-fs, block devices only
- [Cloud Hypervisor](https://www.cloudhypervisor.org/), [microsoft/openvmm](https://github.com/microsoft/OpenVMM), [hcs-rs](https://lib.rs/crates/hcs-rs) — alternatives considered, none needed if libkrun/WHP holds
- [Tauri v2: frontend configuration](https://v2.tauri.app/start/frontend/), [embedding external binaries](https://v2.tauri.app/develop/sidecar/)
- [microsoft/WSL#5030](https://github.com/microsoft/WSL/issues/5030) — Hyper-V/VBS vs nested virtualisation
