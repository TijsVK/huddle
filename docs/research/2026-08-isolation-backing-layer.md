# Research: a stronger backing layer for Huddle

**Status:** research + one executed spike — no code, no decision taken.
**S2′ has been run:** Sysbox 0.7.1 on this WSL2 host passes — unprivileged Docker-in-Docker,
every DinD-red-test escape vector blocked, and compose/buildx/dind²/kind all working. Results:
[`2026-08-S2-sysbox-spike-results.md`](2026-08-S2-sysbox-spike-results.md).
**Date:** 2026-08-04. **Base:** `main` @ `8ec8c6c`.
**Question:** keep Huddle's firewall + devcontainer workflow, drop the "precise Docker
controls" baggage, and make the host↔devcontainer wall much stronger than a hand-rolled
Docker socket filter.

---

## 0. Constraints, and the verdict they produce

The survey in §4 was written *before* constraints were stated, against assumptions inferred
from the repo (Windows-first, x86, self-hosted, cross-platform parity, untrusted-attacker
threat bar). Several dismissals were therefore assumption-driven, not evidence-driven. The
constraints as given on 2026-08-04:

| Constraint | Value |
|---|---|
| Hosts | Windows 11 + WSL2 laptops **and** native Linux **and** macOS Apple Silicon — same UX on all three |
| Threat bar | contain **supply-chain malware and a runaway agent**; *not* "survive a determined attacker hunting a kernel escape" |
| Vendor posture | self-hosted OSS strongly preferred; a vendor CLI may be considered |
| Must keep | JetBrains Gateway + VS Code attach; **Docker usable inside the sandbox** |
| Not required | MITM path-level rules / body logging; portal container snapshots |

**Two of those flip the ranking.** The lowered threat bar means a hypervisor is no longer
mandatory — a per-container **user namespace** with virtualized `/proc`, `/sys` and no host
device/socket access already contains malware and a runaway agent. And three-platform parity
punishes anything that only exists on one OS.

**Verdict under these constraints:**

| Option | Verdict | Decided by |
|---|---|---|
| **Sysbox** (`--runtime=sysbox-runc`) | **Primary.** OSS (Apache-2.0), actively maintained (v0.7.1, 2026-07-31), amd64 + arm64, Docker-native, and its headline feature is exactly "run Docker inside an unprivileged container". | matches every constraint |
| Kata Containers | **Optional upgrade** where KVM exists (native Linux hosts, or a Win11 host with nested virt) — buy a real VM boundary later without changing Huddle's model. | not needed at this threat bar; Linux-only |
| Docker `sbx` | **Benchmark / fallback**, not primary: vendor CLI, owns the sandbox lifecycle, audit logs are a paid tier, and IDE attach is unproven. It does cover all three OSes with a real microVM, so keep measuring it. | vendor posture |
| gVisor | Keep on the bench. Stronger than Sysbox, but nested Docker needs the tmpfs-`/var/lib/docker` workaround and the syscall tax lands on IDE/build loops. | cost, not correctness |
| WSL-distro-per-devcontainer / `wslc` | Still out, but now for a *different* reason: Windows-only (fails parity) and `wslc` can't nest. Not because the boundary is "too weak" — at this threat bar it might have sufficed. | parity |
| Cleanroom / SporeVM | Out: x86-64 is an experimental 512 MiB one-shot profile. Would be a top contender on an ARM-only fleet. | Windows/Linux x86 in scope |
| Sysbox via Docker Desktop **ECI** | Out as the mechanism (Desktop-only, Business tier), but it is the same runtime — so the compatibility story is commercially well-trodden. | OSS preference |
| Apple `container` | Out on fact: no Docker API, so devcontainers/compose/Testcontainers don't work. | "Docker usable inside" |

**Shape of the primary design:** a controlled Linux **engine host** per platform — native on
Linux, a dedicated WSL2 distro on Windows, a Lima VM on macOS — running `dockerd` with the
Sysbox runtime. Devcontainers stay ordinary Docker containers (so IDE attach, labels, exec and
`docker commit` all keep working), but each one is user-namespaced and can run its **own
Docker daemon unprivileged** — which deletes the `--privileged` sidecar, the authz plugin, the
bind allowlist and the `nosymfollow` remount in one go. Egress stays host-side (§5).

Free bonus, explicitly *not* claimed as a boundary: on Windows and macOS the engine host is
already a VM, so an escape lands there rather than on the user's OS. On native Linux it lands
on the developer's machine — that is the weakest deployment and the place to add Kata (or a
Lima VM) if parity of claims matters.

**Prerequisites measured on this WSL2 box (all present):** `systemd` as PID 1, kernel 6.6
(≥ 5.19, so no shiftfs needed), user namespaces enabled (`max_user_namespaces=127249`),
overlayfs on ext4, and `/dev/fuse` (sysbox-fs is FUSE-based). Sysbox's WSL2 issue
(nestybox#32) was closed inconclusively back in 2023 citing WSL kernel limits — on this
kernel the blockers look gone, but **unverified until installed**, and installing restarts
`dockerd`, which kills running devcontainers, so it needs a throwaway distro (S2).

---

## 0b. Initial survey conclusion (assumption-driven — kept for the reasoning)

1. **The wall we want already has a standard shape in 2026:** *one microVM per sandbox,
   with a full unrestricted Docker daemon inside it, and network egress allowlisted by a
   host-side component the guest cannot reach.* That is what Docker's own `sbx`, Buildkite's
   Cleanroom, E2B, Fly Sprites, Vercel Sandbox, Northflank and a dozen OSS agent sandboxes
   converged on. Huddle's DinD experiment converged on the same *shape* but with a
   namespace-only boundary, which is exactly why it needed an authz plugin, bind allowlists
   and `nosymfollow` tricks to stay standing.
2. **The right trade is: buy a hypervisor boundary, sell the Docker policy engine.** Once a
   devcontainer lives in its own VM, `socket-proxy.ts` (889 lines on `main`) and
   `docker-actions.ts` (206) become unnecessary, as do the experiment branch's
   `host-config-policy.ts` (235), `dind-authz.ts` (156) and most of `dind.ts` (469) — plus the
   grant timers, the label-ownership rules, and the "root for the default user" ceremony (root
   in your own VM is uninteresting).
3. **Egress control must move outside the guest, and mostly already is.** `dc-net-*` is
   created `Internal: true` (`gateway/src/docker.ts:300`, host-side, real). The in-container
   `iptables` DNAT/DROP (`docker.ts:150-154`, `:538-542`, `:665-669`) is
   defence-in-depth only. In a VM model the same trick gets *stronger*: give the VM exactly
   one reachable L3 endpoint — the Huddle proxy — and there is no route to bypass, root or
   not. The rules engine, portal, approval loop and network log survive unchanged.
4. **Platform reality is the deciding constraint, not taste.** MicroVM-per-devcontainer needs
   KVM (Linux) or Hyper-V (Windows). Measured on this dev box (WSL2, kernel 6.6.114.1):
   **no `/dev/kvm`, no `vmx`/`svm` in `/proc/cpuinfo`** — so nested-microVM-inside-WSL2 does
   not work here today. Windows can still get a real microVM boundary, but by talking to
   Hyper-V from Windows (which is what `sbx` does — it needs `HypervisorPlatform`, not Docker
   Desktop, not a WSL distro), not by nesting inside the Docker/WSL VM.
5. **Recommended direction:** keep Huddle as the *policy and portal plane* (rules, approvals,
   audit, proxy, IDE glue) and make the *compute plane* pluggable with one interface
   ("give me an isolated box that runs an OCI image, has its own Docker, and whose only
   network path is the proxy"). Then implement that interface twice: **Docker `sbx`** on
   Windows/macOS (fastest path to a real VM boundary, free CLI) and **Kata Containers**
   under the existing Docker orchestration on KVM-capable Linux hosts (near-zero change to
   Huddle's model). Validate with three spikes before committing (§8).

---

## 1. What we are buying and selling

**Keep (non-negotiable, these are the product):**
- Per-domain egress firewall with request→approve→allow loop, per-container and global rules,
  time-bound rules, network log.
- Devcontainer workflow: base images per IDE, JetBrains Gateway / VS Code attach, workspace
  mount, snapshots, portal container management.
- "No direct internet" and "no host compromise" as *claims we can defend*.

**Sell (this is the baggage):**
- Per-Docker-action authorization, label-ownership filtering, HostConfig validation, mount
  allowlists, grant timers — the entire idea that Huddle must *understand and referee* every
  Docker API call.
- The corollaries it drags in: Aspire/Testcontainers/kind breakage, `docker cp` filtering,
  port-publish approval hacks, and (in DinD mode) an authorization plugin that must model
  runc's default masked paths, Go's case-insensitive JSON, symlink-following bind resolution
  and managed-plugin installs to stay safe.

**Explicitly accept as a cost:** more RAM/disk per devcontainer, slower cold start, and a
filesystem boundary (virtiofs/9p or a copy) between host workspace and guest.

---

## 2. Threat model and today's boundary inventory

> **Narrowed by §0:** the adversary below is the *maximal* one. The stated bar is
> supply-chain malware and a runaway agent — an attacker who finds and drives a kernel exploit
> is out of scope on the primary (Sysbox) plane, and in scope only on the optional Kata plane.
> The boundary inventory itself is unaffected.

**Adversary:** code executing inside a devcontainer — an AI agent running unattended, or a
malicious dependency. Assume it is root-capable inside the devcontainer (the experiment
branch grants exactly that), knows Huddle's design, and has full use of whatever Docker
endpoint it is given.

**Wins it is after:** (a) host code execution, (b) reach into peer devcontainers, (c) reach
the Huddle gateway's own secrets — MITM CA private key, operator token, SQLite DB, (d) egress
to a non-allowlisted destination.

**Boundaries today, by strength:**

| Boundary | Mechanism | Enforced where | Strength |
|---|---|---|---|
| Egress to internet | `dc-net-*` created `Internal: true` (`docker.ts:300`) | host daemon → host iptables | Real. Guest root cannot undo it. |
| Egress via proxy only | proxy env + in-container `iptables` DNAT/DROP (`docker.ts:150-154`, `:538-542`) | inside the guest | Weak on its own — a root guest flushes it. Fine as defence-in-depth behind the `--internal` net. |
| Docker API abuse (classic mode) | `socket-proxy.ts` policy (+ `host-config-policy.ts` on the experiment branch) | host-side proxy process | Real *as a filter*, but it is a parser in front of a privileged API — the whole class of bug Huddle keeps finding. |
| Host escape (DinD mode, `experiment/dind`) | `dind-authz.ts` dockerd authorization plugin | host-side plugin, called by dockerd | Currently holding, after four adversarial rounds. Shared kernel + `--privileged` sidecar means *one* missed request shape = host root. |
| Kernel/hypervisor | shared host kernel | — | **None.** All devcontainers and the gateway share one kernel. |

**Two documented facts that should drive the redesign:**

- Huddle's own red test found host takeover from a nested `--privileged` container: it read
  host `/dev/sd*`, mounted host disk, read `/etc/shadow` (see `docs/dind/SECURITY-CRITICAL.md`
  on `experiment/dind`). The stated premise — "only the sidecar is privileged, isolation is
  preserved" — was wrong, and the fix required modelling dockerd's internals precisely. Each
  new Docker/runc feature reopens that work.
- On Windows the "host" that an escape lands on is already a VM — and that VM is *not* a
  hardened boundary. Trend Micro published Docker-Desktop-under-WSL2 escapes that reach the
  Windows host through legitimate mechanisms (internal APIs, config, CLI plugin loading), and
  WSL2 distros are separated by **namespaces inside one shared utility VM**, not by
  virtualization. So "escape only reaches the WSL VM" is not a defence, and neither is
  "put each devcontainer in its own WSL distro" (nor `wslc`, which uses the same shared-kernel
  confinement).

---

## 3. The design axiom to adopt

> **Every boundary that matters is enforced by something the guest cannot address, and there
> are only two of them: a runtime boundary for compute, and a single network path for egress.**

Under the §0 constraints the compute boundary is a **user namespace with virtualized `/proc`
and `/sys` (Sysbox)** rather than a hypervisor; the rest of this section holds either way,
since what matters is that the enforcement point is not reachable from inside the guest. Read
"VM" below as "isolated box" and the argument is unchanged.

Concretely:

```
                     ┌──── host / Windows side ────────────────────────────┐
                     │  Huddle gateway: rules engine, portal, audit,       │
                     │  MITM proxy :80, credential mediation               │
                     └───────────────▲─────────────────────────────────────┘
                                     │ only reachable endpoint
        ┌────────────────────────────┴─────────────────────────────┐
        │ microVM per devcontainer (own kernel)                     │
        │  ├─ dev environment + IDE backend                         │
        │  └─ full unrestricted dockerd  ← Aspire, Testcontainers,  │
        │        └─ nested containers      compose, kind, act …     │
        └───────────────────────────────────────────────────────────┘
```

Consequences worth stating plainly:
- Inside the VM, *anything goes*: `--privileged`, host binds (of the VM's own fs), devices,
  DinD-in-DinD, root. That is the point — it is the guest's own kernel to break.
- The gateway's secrets are on the other side of a hypervisor, not behind a JSON parser.
- Peer isolation becomes per-VM rather than per-network — stronger and simpler.
- What Huddle must referee shrinks to: **which domains may be reached**, **what the box may
  see of the filesystem**, and **which credentials get brokered in**. All three are
  policy questions with clean seams, not API-shape questions.

---

## 4. Candidate backing layers

### A. Docker Sandboxes (`sbx`) — buy the boundary

Docker's own product for exactly this problem: each sandbox is a **microVM with its own
kernel, its own Docker daemon, its own network**; workspace mounted; deny-by-default egress
policy with three presets (Open / Balanced / Locked Down) and `sbx policy allow network
<domain>` supporting `*.example.com` and `:port`, global or `--sandbox`-scoped; a host-side
proxy that blocks host loopback and **injects credentials** (Anthropic/OpenAI/GitHub) so keys
never enter the guest; editors attach **over SSH** (VS Code, Cursor documented).

- **Host support:** macOS (brew), Windows (winget; needs `HypervisorPlatform`, explicitly
  *not* Docker Desktop and *not* a WSL distro), Linux (KVM group).
- **Licence:** CLI free including commercial use; **org governance (central policy, sign-in
  enforcement, audit logs) is a paid add-on.**
- **Fits Huddle:** microVM + own dockerd + host-side allowlist is precisely §3. `sbx policy
  allow network` is a CLI seam Huddle's approval loop could drive.
- **Risks / unknowns to spike:** performance (one hands-on report calls the hit "crippling"
  for simple projects — must be measured with a real .NET/Aspire repo); whether JetBrains
  Gateway can attach (SSH exists, Dev Containers over remote Docker exists — untested
  together); whether policy changes apply live to a running sandbox (needed for
  request→approve without a restart); whether we get per-request *logging* (Huddle's network
  log wants domain+path+status; a hostname allowlist alone doesn't give that); sandbox
  lifecycle is `sbx`-owned, so Huddle's container list/snapshot/commit features need
  remapping; dependency on Docker Inc. for a governance feature we already have.

### B. Kata Containers under the existing Docker orchestration — minimum diff

Register Kata as a Docker runtime (`"runtimes": {"kata": {"runtimeType":
"io.containerd.kata.v2"}}`, Docker ≥26 needs Kata ≥3.29 go / ≥3.30 rust, tested with QEMU)
and start each devcontainer with `--runtime`. The devcontainer *is* a VM; everything else in
Huddle stays: names, labels, `dc-net-*`, IDE attach via the local Docker daemon, snapshots,
the whole portal.

- **Then the DinD experiment becomes safe as originally designed:** run the privileged
  sidecar (or just `dockerd` inside the devcontainer image) *inside* the Kata VM and **delete
  `dind-authz.ts`** — an escape lands in the guest kernel. Kata also has
  `privileged_without_host_devices = true` so a privileged nested container sees the guest's
  devices, not the host's.
- **Cost:** KVM required on the host; QEMU/Cloud-Hypervisor per devcontainer (~100-300 MB
  kernel/VMM overhead); `--network container:<dc>` netns sharing (the Aspire localhost fix)
  needs re-validation under Kata; virtiofs workspace performance must be measured; Docker's
  `--runtime` support with Kata is a less-travelled path than containerd/CRI.
- **Blocked where there is no KVM:** on this machine, `/dev/kvm` is absent. See §6.

### C. Own VM-per-workspace — build the boundary

Provision a Linux VM per devcontainer (or per developer) and run the *existing* devcontainer
image inside it with a normal dockerd; Huddle talks to that daemon remotely
(`DOCKER_HOST=ssh://…` / mTLS TCP), and IDEs attach through the same remote Docker endpoint —
JetBrains Gateway supports adding Docker servers over SSH, VS Code documents Remote-SSH +
Dev Containers and `docker context create --docker host=ssh://…`.

- **Provisioners:** Hyper-V + cloud-init (Windows, no nesting needed), `podman machine
  --provider hyperv`, Multipass, Lima/Colima, plain QEMU/KVM on Linux, Apple
  Virtualization.framework on macOS.
- **Pros:** total control of the boundary and of egress enforcement (see §5); no vendor; the
  guest can be a bog-standard Docker host so every tool works.
- **Cons:** we own VM lifecycle, images, upgrades, disk growth, snapshot/commit semantics, and
  per-platform provisioning code — a real chunk of work, and the part most likely to
  re-create the complexity we are trying to shed, just one layer down.
- **Note on "one VM per developer" vs "per devcontainer":** per-developer is cheaper but
  weakens the peer-isolation claim to "your own projects share a kernel". Since one
  devcontainer ≈ one project ≈ one IDE backend (already 2-4 GB), per-devcontainer VMs are
  roughly the same footprint plus a kernel — recommend per-devcontainer.

### D. Sysbox / Docker Desktop Enhanced Container Isolation — harden without a VM

Sysbox (Docker-owned since the Nestybox acquisition) is a runc replacement that puts every
container in a user namespace with ID-mapped mounts, and **runs Docker/systemd/K8s inside a
container without `--privileged`**. Docker Desktop's ECI is Sysbox with the sharp edges
removed: `--runtime` is ignored, Docker socket bind-mounts are blocked (with an exception
list for Testcontainers), `--pid=host`/`--network=host` refused, and privileged containers
"run securely" without breaching the Docker Desktop VM.

- **Attraction:** would let Huddle drop the `--privileged` DinD sidecar today, on the existing
  architecture, with no VM anywhere.
- **Why it is not the answer to the question asked:** it is still a **shared kernel**. Sysbox's
  own docs say it "does not (yet) provide the same level of isolation as VM-based alternatives
  or user-space OSes like gVisor". ECI is a Docker Desktop **Business** feature and is
  Desktop-only, so it cannot be Huddle's boundary on a Linux host or in CI. Sysbox CE is
  Linux-only, kernel-picky (ID-mapped mounts ≥5.12, ≥5.19 for full shiftfs replacement) and
  WSL2 support is unconfirmed.
- **Verdict (revised, see §0):** at the stated threat bar Sysbox *is* the wall, and the
  "shared kernel" objection is out of scope rather than fatal. Sysbox CE is Apache-2.0,
  amd64 + arm64 (arm64 since v0.5.0), and shipped v0.7.1 on 2026-07-31, so the OSS path
  does not depend on Docker Desktop or ECI at all. What it buys concretely:
  - Docker/systemd/K8s **inside** an unprivileged container → no `--privileged` sidecar, no
    dockerd authorization plugin, no bind-source allowlist, no `nosymfollow` remount.
  - Per-container exclusive UID mapping with ID-mapped mounts, and virtualized `/proc` and
    `/sys` — so the writable-host-kernel-interface vector that the DinD red test exploited
    is not reachable in the first place.
  - Writes to global kernel settings (module load, BPF settings) return `permission denied`.
  - Docker-native (`--runtime=sysbox-runc`), so Huddle's orchestration, labels, exec, IDE
    attach and `docker commit` are unchanged.
  Open items for the spike: kernel ≥ 5.19 (met), Debian 13 is not on Sysbox's officially
  tested distro list (Bullseye/Buster are; "expected to work with kernel ≥ 5.12"), WSL2
  unverified, some mount types are intercepted (there is an open report about `mount -t cifs`
  failing under Sysbox), and `network_mode: host` interacts badly with `userns-remap` if we
  ever enable that daemon-wide.

### E. gVisor (runsc) — user-space kernel

Strong syscall-level isolation without a hypervisor, and Docker-in-gVisor is supported —
but nested Docker needs a tmpfs `/var/lib/docker` or `--feature containerd-snapshotter=false`
because overlay-on-overlay is refused, and the syscall-interposition tax lands hardest on
exactly our workload (large builds, file-heavy dev loops, IDE indexing). Reasonable for
short-lived tool sandboxes; a poor fit for an all-day IDE environment. Keep as a possible
*inner* layer (stereOS/Modal both do VM+gVisor).

### F. Reference designs worth reading (not adoptable as-is)

- **Buildkite Cleanroom + SporeVM** (MIT): policy-compiled microVM snapshots, deny-by-default
  egress enforced by the VMM "on every resume and fork, regardless of who invokes it", a
  host-side gateway that brokers credentials so secrets never enter the sandbox, provenance
  stamped into the artifact, `services.docker.required: true` for a guest daemon, host-side
  registry cache. **Blocker:** SporeVM's full lifecycle is ARM64-only; Linux/AMD64 is an
  experimental 512 MiB one-shot profile — unusable for an x86 Windows fleet today. Steal the
  *design*: policy→VMM enforcement, credential mediation, host content cache.
- **microsandbox / krunai / boxlite / brood-box** (libkrun microVMs, sub-200 ms boot,
  DNS-aware egress policies), **k7** (Kata-backed), **membrane** (hostname-allowlisted egress
  via eBPF), **iron-proxy / matchlock / wardgate** (MITM egress proxy + secret injection).
  The whole field is catalogued in `bureado/awesome-agent-runtime-security` — useful to mine
  for egress-policy UX and credential-brokering patterns Huddle could copy.
- **Anthropic's sandbox-runtime / Claude Code sandboxing**: bubblewrap + seccomp (deny
  ptrace/process_vm_readv/io_uring, only `AF_UNIX` in restricted-network mode) plus a
  localhost proxy that allowlists by hostname and returns `CONNECT 403` on deny, **without**
  terminating TLS by default. Directly relevant to §5's MITM-vs-SNI question.

### G. Non-starters for the wall

- **WSL2 distro per devcontainer** and **`wslc`**: namespace confinement inside a shared
  utility VM; `wslc` additionally cannot get `/dev/kvm` (microsoft/WSL#40736), so nothing can
  be nested inside it. `wslc`'s *API mode* claims per-app lightweight VMs — worth re-checking
  later, but it is preview-stage and Windows-only.
- **Apple `container`**: per-container VM on macOS, but it deliberately does not implement the
  Docker API, so devcontainers/compose/Testcontainers don't work against it.

### Matrix

| | A. `sbx` | B. Kata | C. own VM | D. Sysbox/ECI | E. gVisor |
|---|---|---|---|---|---|
| Boundary | hypervisor | hypervisor | hypervisor | userns, shared kernel | user-space kernel |
| Full Docker inside | yes | yes | yes | yes (no `--privileged`) | with workarounds |
| Huddle policy code deleted | most | most | most | some | most |
| Windows path | native (HypervisorPlatform) | needs nested virt in WSL2 | Hyper-V | Desktop Business only | via WSL2 |
| Linux path | KVM | KVM | KVM | native | native |
| IDE attach | SSH (untested w/ JetBrains) | unchanged (local Docker) | remote Docker over SSH | unchanged | unchanged |
| Egress control point | `sbx` host firewall | ours (host-side) | ours (host-side) | ours | ours |
| Network log fidelity | unknown, likely hostname-only | unchanged (our proxy) | unchanged | unchanged | unchanged |
| Effort | low-medium | low | high | low | medium |
| Vendor risk | Docker Inc. | none | none | Docker Inc. (ECI) | none |

---

## 5. Egress enforcement in a VM world

The rules engine, portal, approvals and audit log do not change. What changes is *where* the
chokepoint is and how unbypassable it is.

**Chokepoint options, strongest first:**

1. **No route but the proxy.** Attach the VM to an isolated switch/bridge with no NAT and no
   gateway, and expose exactly one host endpoint: Huddle's proxy port. There is no L3 path to
   the internet to bypass — guest root is irrelevant. Windows: internal Hyper-V switch;
   Linux: tap/bridge in a netns with no forwarding. This is the same trick `dc-net-*
   Internal: true` already plays, one layer out.
2. **Host-side packet ACLs as belt-and-braces.** Hyper-V **extended port ACLs**
   (`Add-VMNetworkAdapterExtendedAcl`) are applied by the virtual switch on ingress/egress of
   a specific vNIC — deny-all at low weight, allow the proxy at higher weight, enforced
   outside the guest. Linux equivalent: nftables on the tap device, owned by root on the host.
3. **In-guest iptables / proxy env:** keep as UX (so tools find the proxy) and
   defence-in-depth, never as the boundary. Same posture as today, honestly labelled.

**TLS: MITM or SNI-splice?** Today Huddle MITMs with its own CA, which buys full
request/response logging and path-level rules but costs a CA install in every image, every
nested container, every runtime's trust store (the DinD notes are full of exactly this pain,
including `dockerd`'s own pulls and .NET's `no_proxy` CIDR gap). The alternative is
allowlisting on **SNI/CONNECT hostname without decrypting** (Squid `ssl_bump peek/splice`, or
what Claude Code's proxy does). Trade-off to decide deliberately:

| | MITM CA (today) | SNI/CONNECT allowlist |
|---|---|---|
| Path-level rules, body logging | yes | no (host+port only) |
| CA distribution pain | high, recurring | none |
| Breaks pinned clients | yes | no |
| Legal/consent posture | interception, needs care | passive metadata |

A defensible middle: splice by default, bump only for domains an operator explicitly marks
"inspect". Note the honest limitation Cleanroom documents for hostname rules: they are
enforced from observed DNS answers plus destination IP:port, so **co-hosted services behind
one IP:port are not distinguished** — worth stating in Huddle's own claims too.

**Other must-solve details:** DNS (resolve host-side via the proxy's CONNECT, or run an
allowlisting resolver so a guest can't tunnel over DNS); published ports for the developer's
browser (host→VM forward, per-port, still operator-approved); `localhost` semantics for tools
like Aspire's DCP (inside a VM these become trivially local again — a *simplification* versus
the shared-netns gymnastics on `experiment/dind`); registry pull volume (a host-side content
cache like Cleanroom's, or the pull goes through the proxy per VM); credential brokering
(sbx/Cleanroom/iron-proxy all keep secrets host-side and inject per request — Huddle should
adopt this for the AI keys and git tokens it currently hands into containers).

---

## 6. Platform reality check (KVM — now only gates the optional Kata plane)

Measured on the machine this research ran on:

```
$ ls -l /dev/kvm            → No such file or directory
$ grep -oE 'vmx|svm' /proc/cpuinfo → (no match)
$ cat /proc/version         → 6.6.114.1-microsoft-standard-WSL2
$ docker info               → Debian 13 (trixie), Docker 29.6.2, native dockerd in the distro
```

So: **no hardware virtualization inside this WSL2 guest.** Implications:

- Options B (Kata) and C (own VM) cannot run *inside* the WSL2 distro on this box until
  nested virtualization is enabled — `.wslconfig` `[wsl2] nestedVirtualization=true`, which is
  honoured on Windows 11 hosts whose CPU supports it, and reportedly still absent for `wslc`
  containers (microsoft/WSL#40736, #13262).
- Option A sidesteps this by not living in WSL at all: `sbx` talks to Windows'
  `HypervisorPlatform` directly.
- On a native Linux host with KVM (a shared dev server, or a Linux laptop) B and C are
  straightforward.
- **First fleet question to answer:** how many target machines are Windows 11 with nested virt
  available vs. Windows without it vs. native Linux vs. macOS? The answer picks the primary
  implementation, and the fallback needs an honest, *labelled* weaker mode (e.g. today's
  model, stated as "shared kernel").

---

## 7. What Huddle's codebase gains and loses

**Deletable / drastically shrinkable once the VM boundary exists** (verified line counts;
branch noted because three of these exist only on `experiment/dind`):

| File | Lines | Branch | Fate |
|---|---|---|---|
| `gateway/src/socket-proxy.ts` | 889 | main | delete (no filtered Docker window needed) |
| `gateway/src/docker-actions.ts` | 206 | main | delete (plus its UI page and grant timers) |
| `gateway/src/host-config-policy.ts` | 235 | experiment | delete |
| `gateway/src/dind-authz.ts` | 156 | experiment | delete |
| `gateway/src/dind.ts` | 469 | experiment | mostly delete — no sidecar, no shared netns, no CA-into-sidecar, no `nosymfollow` |
| `gateway/src/root-grant.ts` | 89 | experiment | delete or trivialize (root in own VM is not a grant) |
| in-container `iptables` scripts in `docker.ts` | 20 call sites | main | demote to UX/defence-in-depth |

**Survives unchanged:** `rules.ts`, `proxy.ts`, `db.ts`, `api.ts`, the Angular portal, the
audit log, extensions, the CLI's UX.

**New work required (this is the honest cost):**
- A compute-plane abstraction (`start/stop/snapshot/exec/attach` against "a box") with at
  least two implementations, plus capability reporting so the portal can say what mode a
  devcontainer is in.
- IDE attach through a remote Docker endpoint / SSH, for both JetBrains Gateway and VS Code,
  including the gateway-link discovery Huddle does today by grepping the backend logs.
- Workspace file sharing across the VM boundary and its performance (virtiofs/9p/mount vs
  clone-and-sync), including the `git worktree` flow.
- Snapshot/commit semantics in the new world (docker commit *inside* the VM still works —
  the question is where the image lives and how it is reused).
- Image/rootfs supply: reuse the existing `base-devimage-*` images inside the VM (preferred)
  vs. baking VM images.
- Registry pull cost per VM, and a host-side pull-through cache to make it bearable.

---

## 8. Spikes to run before deciding (each small, each with a pass/fail)

Reuse the harnesses that already exist on `experiment/dind` / `experiment/dind-rootless`:
`gateway/test/dind-compat/` — `battery.sh` + `tools/*.sh` (Aspire, compose, Testcontainers,
buildx, act, kind, playwright), `e2e-aspire-project-ef.sh` (boots the Aspire dashboard and
asserts Blazor markup + zero gRPC/circuit errors, not log-greps), `e2e-escape.sh` (the host
escape red test), `e2e-nested-egress.sh`, `e2e-nested-published-port.sh`, `e2e-toolchain-ca.sh`. The
real-headless-browser harnesses live on `fork/worktree-dashboard-e2e-parity`:
`e2e-aspire-dashboard.sh` (Chromium logs into the Aspire dashboard and asserts resources
render Running) and `e2e-webui-docker-hello.sh` (drives the Huddle portal's own firewall
approval flow, with video + screenshots). Per prior lesson: do **not** accept log-greps as
proof that a UI works.

**Revised order under the §0 constraints: S2′ first, then S3′, then S4/S5. S1 and S2 become
benchmarks, not decisions.**

- **S2′ — Sysbox conformance — ✅ DONE 2026-08-04, passed.** Results and the measured escape
  matrix: [`2026-08-S2-sysbox-spike-results.md`](2026-08-S2-sysbox-spike-results.md). Deviation
  from the plan below: run on *this* host rather than a throwaway distro, because no Windows
  filesystem is mounted here so `wsl.exe` was unreachable; the installer refuses to proceed with
  containers present, so the three Aspire `sqlserver-*` containers were removed (authorised,
  volumes untouched) and `dockerd` restarted. Original plan, for the record: In a **throwaway** WSL2 distro (never the
  working one — installing Sysbox restarts `dockerd`): install Sysbox 0.7.1, run a devcontainer
  with `--runtime=sysbox-runc`, start `dockerd` **inside** it unprivileged, then run the full
  dind-compat battery with `socket-proxy` and `dind-authz` **disabled**, plus `e2e-escape.sh`.
  *Pass:* battery green (Aspire, compose, Testcontainers, buildx, act), inner dockerd needs no
  `--privileged`, and the escape test's device/host-kernel vectors fail at the runtime.
  *Record:* which escape vectors Sysbox does **not** block, so the threat-bar claim stays honest.
- **S3′ — engine host + IDE attach on all three platforms (~2-3 days).** Dedicated WSL2 distro
  (Windows), Lima VM (macOS ARM64), native (Linux). Verify: `docker context` from the host OS,
  JetBrains Gateway attach including the gateway-link discovery Huddle does by grepping backend
  logs, VS Code attach, workspace mount performance and uid/gid behaviour under Sysbox's ID
  mapping, and `huddle` CLI flows end to end.
  *Pass:* identical UX on all three; no per-platform special-casing above the engine-host layer.
- **S1 — `sbx` viability (Windows, ~2 days; now a benchmark).** Create a sandbox on a Win11 box; mount a real
  .NET repo; run the Aspire E2E; attach JetBrains Gateway and VS Code over SSH; add a domain
  to the policy while the sandbox runs and see if it takes effect live; capture what a blocked
  request looks like and whether anything logs it.
  *Pass:* IDE attaches, Aspire E2E green, live policy change works, blocked-domain event
  observable. *Fail-fast signal:* build/index times more than ~2× the current devcontainer.
- **S2 — Kata under Huddle's own orchestration (Linux+KVM, ~2-3 days).** Register the Kata
  runtime, start an existing devcontainer image with `--runtime`, run dockerd inside it, run
  the full dind-compat battery **with `dind-authz` disabled**, and re-run the escape red test
  `e2e-escape.sh` to confirm it now fails at the VM boundary instead of a JSON parser.
  *Pass:* battery green, escape test cannot reach the host, `--network container:` behaviour
  understood.
- **S3 — host-side egress chokepoint (~1-2 days).** Prototype "no route but the proxy" on both
  platforms: internal Hyper-V switch + extended port ACLs, and Linux tap + nftables. Verify
  from inside as root: no DNS exfil, no direct IP egress, proxy reachable, and Huddle's
  approval loop still works end to end.
- **S4 — TLS posture decision (~1 day).** Prototype SNI/CONNECT-only allowlisting and measure
  what the network log loses; list which current features (path-mode rules, body logging,
  extension `ctx.fetch` attribution) depend on MITM.
- **S5 — fleet capability audit (hours, do first).** Script that reports, per target machine:
  Windows edition, HypervisorPlatform/Hyper-V state, nested-virt availability in WSL2,
  `/dev/kvm` presence, CPU/RAM headroom. This decides which of A/B/C is primary.

---

## 9. Recommendation (constraint-driven — supersedes §9b)

1. **Primary: Sysbox on a controlled Linux engine host per platform.** OSS, cross-platform,
   Docker-native, gives unprivileged Docker-in-Docker, and meets the stated threat bar. Run
   **S2′ then S3′** before committing.
2. **Keep the egress chokepoint ours and host-side** (§5). This is plane-independent and is
   where the product's value sits, so it should not be delegated to any backing layer's own
   firewall.
3. **Drop the MITM CA and allowlist on SNI/CONNECT** now that path rules and body logging are
   not required (S5). This removes the CA-into-every-trust-store problem — the single most
   recurring source of DinD breakage — from every plane at once.
4. **Add Kata later, only where KVM exists**, if the claim needs to be "hypervisor boundary" on
   native-Linux installs. Cheap to add precisely because Sysbox and Kata are both just a
   `--runtime` on the same Docker orchestration.
5. **Keep `sbx` as a measured yardstick**, not a dependency; revisit if the threat bar rises or
   if Docker ships an OSS-usable policy surface.
6. **Stop hardening the current model.** No further investment in socket-proxy policy or
   authz-plugin coverage beyond keeping existing tests green.
7. **Show the boundary in the portal per devcontainer** (userns vs hypervisor vs shared kernel)
   so the claim is never stronger than the mechanism.

## 9b. Recommendation from the initial survey (assumption-driven)

1. **Adopt the axiom in §3** and restructure Huddle around a *pluggable compute plane* with a
   *host-side policy plane*. That is the durable decision; everything else is an
   implementation choice per platform.
2. **Run S5 then S1 and S2 in parallel.** They are cheap and they answer the two real
   questions: "can we buy the boundary on Windows today?" and "can we get it on Linux with
   almost no change to Huddle?"
3. **Do not build option C (own VM manager) until A and B are both shown insufficient.** It is
   the largest surface and the most likely to re-create today's complexity one level down.
4. **Treat the current model as the labelled fallback**, not as a thing to keep hardening: no
   further investment in socket-proxy policy or authz-plugin coverage beyond keeping the
   existing tests green. The DinD work is not wasted — inside a VM the sidecar design becomes
   safe *and* the plugin goes away.
5. **Keep the security claims honest in the portal**: per devcontainer, show which boundary is
   actually in force (hypervisor vs shared kernel) and which egress chokepoint applies.

---

## Sources

- [Enhanced Container Isolation | Docker Docs](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/) · [how ECI works](https://docker.qubitpi.org/security/for-admins/hardened-desktop/enhanced-container-isolation/how-eci-works/) · [ECI limitations](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/limitations/)
- [nestybox/sysbox](https://github.com/nestybox/sysbox) (Apache-2.0; v0.7.1, 2026-07-31) · [distro compatibility](https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md) · [arch compatibility (arm64 since v0.5.0)](https://github.com/nestybox/sysbox/blob/master/docs/arch-compat.md) · [ID-mapped mounts issue #535](https://github.com/nestybox/sysbox/issues/535) · [WSL2 support issue #32](https://github.com/nestybox/sysbox/issues/32) · [KinD inside a Sysbox container](https://blog.nestybox.com/2022/01/10/kind-in-sysbox.html) · [Arm's Sysbox install guide](https://learn.arm.com/install-guides/sysbox/)
- [Lima](https://lima-vm.io/docs/installation/) (macOS/Linux VMs, Apple Silicon)
- [Docker Sandboxes docs](https://docs.docker.com/ai/sandboxes/) · [FAQ](https://docs.docker.com/ai/sandboxes/faq/) · [`sbx policy allow network`](https://docs.docker.com/reference/cli/sbx/policy/allow/network/) · [hands-on review (andrewlock.net)](https://andrewlock.net/running-ai-agents-safely-in-a-microvm-using-docker-sandbox/) · [sbx on Windows 11](https://www.ajeetraina.com/running-coding-agents-in-a-secure-microvm-on-windows-with-sbx/)
- [Kata: how to use Kata with Docker](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-kata-with-docker.md) · [Docker alternative runtimes](https://docs.docker.com/engine/daemon/alternative-runtimes/) · [Kata Containers docs](https://katacontainers.io/docs/)
- [Docker in gVisor](https://gvisor.dev/docs/tutorials/docker-in-gvisor/) · [gVisor docs](https://gvisor.dev/docs/)
- [buildkite/cleanroom](https://github.com/buildkite/cleanroom) · [sporevm/sporevm](https://github.com/sporevm/sporevm)
- [bureado/awesome-agent-runtime-security](https://github.com/bureado/awesome-agent-runtime-security) · [List of coding agent sandboxes (2026-05)](https://gist.github.com/wincent/2752d8d97727577050c043e4ff9e386e)
- [How Claude Code and Codex sandbox untrusted code](https://medium.com/@Koukyosyumei/how-claude-code-and-codex-sandbox-untrusted-code-ba39b493046a) · [Claude Code sandboxing docs](https://code.claude.com/docs/en/sandboxing)
- [Trend Micro: Cracking the Isolation — Docker Desktop VM escapes under WSL2](https://www.trendmicro.com/vinfo/us/security/news/virtualization-and-cloud/cracking-the-isolation-novel-docker-desktop-vm-escape-techniques-under-wsl2)
- [WSL advanced settings (`nestedVirtualization`)](https://learn.microsoft.com/en-us/windows/wsl/wsl-config) · [microsoft/WSL#40736 — no nested virt for wslc](https://github.com/microsoft/wsl/issues/40736) · [microsoft/WSL#13262 — missing /dev/kvm](https://github.com/microsoft/WSL/issues/13262)
- [wslc: a native Linux container runtime for Windows](https://www.boxofcables.dev/wslc-a-native-linux-container-runtime-for-windows/)
- [Hyper-V extended port ACLs](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v-virtual-switch/create-security-policies-with-extended-port-access-control-lists) · [`Add-VMNetworkAdapterExtendedAcl`](https://learn.microsoft.com/en-us/powershell/module/hyper-v/add-vmnetworkadapterextendedacl)
- [Squid SslPeekAndSplice](https://wiki.squid-cache.org/Features/SslPeekAndSplice)
- [VS Code: develop on a remote Docker host](https://code.visualstudio.com/remote/advancedcontainers/develop-remote-host) · [JetBrains: FAQ about Dev Containers](https://www.jetbrains.com/help/idea/faq-about-dev-containers.html)
- [Apple `container` review](https://andrew.ooo/posts/apple-container-mac-linux-docker-alternative-review/)
</content>
</invoke>
