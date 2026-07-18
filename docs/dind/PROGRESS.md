# Huddle DinD experiment — autonomous build log

> **Dark-factory control doc.** This file is the durable state for a long-running,
> unattended build on branch `experiment/dind`. If context is reset or the session
> resumes after a usage-limit reset, **read this first**, run `git log --oneline main..HEAD`,
> then continue from the first unchecked step.

## Goal (REFRAMED per user)

Primary goal: **broad default compatibility with demanding dev tools that the
socket-proxy filtering currently breaks** — concretely **.NET Aspire** (issues
#12, #61). Give each devcontainer a *real, unrestricted* Docker daemon instead of
a filtered window onto the shared host daemon. Same user-facing features; the
DinD isolation lets us drop the restrictions ("more freedom, no more risk").

### Why the socket-proxy breaks Aspire (issues #12 / #61)
- DCP loopback calls get proxied → `403` from `huddle` proxy tunnel.
- `docker CopyFile` (dev-cert copy into each container) blocked by the proxy.
- Port publishing needs portal approval (`__PORT_CHECK__`) → hangs.
- `InspectContainers` → *"container not owned by this devcontainer"* → health
  checks fail, container stuck in `Unknown`.

A private daemon has none of these filters, so Aspire "just works".

## Architecture — Design N (per-devcontainer DinD sidecar, shared netns)

```
Host Docker daemon
  ├─ huddle gateway            (orchestrator + egress firewall + portal)
  ├─ dc-net-<name> (internal)
  ├─ devcontainer-<name>       (IDE/dev env; DOCKER_HOST → its private daemon)
  └─ dind-<name>               (docker:dind, private daemon, --network container:devcontainer-<name>)
       └─ Aspire/compose/nested containers  (unrestricted; egress via huddle proxy)
```

- Sidecar `dind-<name>` runs a real dockerd, shares the **devcontainer's network
  namespace** (`--network container:devcontainer-<name>`). Devcontainer talks to
  it via a shared socket volume (`DOCKER_HOST=unix:///var/run/dind/docker.sock`).
- Shared netns → nested published ports land on the devcontainer's
  `localhost`/`[::1]` (matches a laptop; what Aspire's DCP expects).
- Egress firewall is *stronger*: sidecar + every nested container share the
  devcontainer's firewalled netns (iptables DNAT→`huddle:80` + proxy env), so
  nested traffic can't bypass the firewall.
- Isolation: the private daemon cannot see the host daemon or peer devcontainers.
  Only the sidecar is privileged; it has no host mounts.
- Gated by `HUDDLE_DIND=1`. Classic socket-proxy model stays the default so the
  existing security tests stay valid.

### Nested-container egress / proxy
Sidecar's docker client config (`~/.docker/config.json` `proxies.default`) +
daemon env inject `http(s)_proxy=http://huddle:80` and the Huddle CA into every
`docker run`/compose/build, so nested traffic is firewalled and TLS-trusted.

### Workspace / DOCKER_HOST
Devcontainer keeps its host workspace bind (unchanged — gateway still on host
daemon). Only docker access changes: `DOCKER_HOST` → the private daemon instead of
the filtering socket-proxy.

## Extra features requested by user (fold into this branch)
- **Permanent docker grant** — non-expiring option (largely moot under DinD but
  keep the portal toggle usable without a timer).
- **Root without noot/password** — a grant that makes the default `vscode` user
  root-capable (passwordless sudo), time-limited with a **permanent** option.
  Replaces the `noot` user + generated-password dance.

## Decisions (made autonomously — no user available)
- Branch `experiment/dind`, kept local until push target confirmed.
- **Push target: user's PERSONAL gh `TijsVK` (a fork), NOT the client account
  `Tijs-VanKampen_reynaers` that gh is currently logged into.** Wait for the user
  to `gh auth login` as TijsVK before any fork/push.
- Design N (per-devcontainer private daemon), chosen over shared-engine Design S
  because the goal is tool compatibility (real unrestricted daemon), not just
  host-shielding.
- Feature-flag `HUDDLE_DIND` so both models coexist and classic tests stay green.

## Task checklist
- [x] Explore architecture, read Aspire issues #12/#61, lock Design N
- [x] Create branch + this doc
- [x] gh: logged in as TijsVK; forked infosupport/huddle → TijsVK; remote `fork` added; branch pushed
- [x] Gateway: sidecar bring-up (`dind.ts`) + DOCKER_HOST rewire under HUDDLE_DIND
- [x] Gateway: proxy injection into the private daemon for nested containers (client-config proxies.default)
- [x] CLI: HUDDLE_DIND plumbing to the gateway
- [x] Build: gateway typecheck clean, 204 vitest pass, cli typecheck clean
- [x] Tool-compat harness (Tier-1): compose, testcontainers, buildx, privileged, k3d, localstack ALL FULLY PASS
- [x] Tier-2 egress harness (`tools/egress.sh`) — all pass incl. loopback-not-proxied (#12)
- [x] Aspire deep test (`tools/aspire.sh`) — ALL PASS: DCP container Running, no #12 403/CopyFile, no #61 ownership error (needed libicu + socket chmod 0666 for the non-root user)
- [x] More tools: act (GH Actions) ✅, devcontainer-cli ✅, workspace bind-through ✅
- [x] `run.sh` runner + `docs/dind/RESULTS.md` — 11/11 tools green
- [x] Feature: root-for-vscode grant (time-limited + permanent) replacing noot dance — backend + frontend + tests
- [x] Feature: permanent (non-expiring) docker grant — backend + frontend + tests
- [x] Frontend: portal toggles for permanent grant + root grant — Angular build passes
- [x] Docs: `docs/dind/ARCHITECTURE.md` + README notes
- [x] Removed orphaned credentials endpoint (noot fully retired)
- [x] Commit incrementally; pushed to TijsVK fork

## STATUS (2026-07-18): C1 host-escape MITIGATED via a dockerd AUTHORIZATION PLUGIN.

**Finding C1 (privileged nested container escapes to host) is CLOSED.** The sidecar
dockerd runs with `--authorization-plugin=huddle-authz` (`gateway/src/dind-authz.ts`);
dockerd calls the plugin before every request on its single socket, so there is no
unfiltered path to reach. The plugin denies the device/kernel/namespace/masked-path
create vectors (via the pure `host-config-policy.ts` `validateDindEscape`) and
privileged exec, and allows everything else.

An adversarial review killed the FIRST design (a socket-proxy filter in front of an
`inner.sock`): it was bypassable (a) by hitting the co-mounted `inner.sock`
directly, and (b) by a workspace symlink bind reaching the socket dir — a lexical
bind guard can't beat symlink-following bind sources. Both verified live. The authz
plugin removes the unfiltered socket entirely, so neither bypass exists, and dockerd
handles stream/hijack/chunk framing natively (the earlier half-open/grpc/buffering
fixes become moot). Also closed review findings #3 (MaskedPaths/ReadonlyPaths
unmask), #7 (privileged exec), #8 (non-default seccomp/apparmor), plus the earlier
#2 (MITM safeRequestPath) and the audit_log row cap.

A SECOND adversarial review (of the authz plugin) found + fixed 4 more real
escapes, all verified live: #1 case-insensitive JSON keys (`{"hostconfig":
{"privileged":true}}` bypassed the case-sensitive plugin while dockerd applied it —
now deep-lowercase all keys); #2 plugin-socket swap (a nested `-v /run/docker/
plugins` could replace the authz socket with an allow-all one — plugin dir now
mounted READ-ONLY into the sidecar); #3 host-kernel bind (privileged sidecar's
/proc,/sys are the HOST's — `-v /proc/sys` wrote the host core_pattern → root; now
deny binds of /proc,/sys,/dev,/); #4 partial MaskedPaths unmask (require a superset
of runc defaults). The #3 workspace-symlink variant is now also CLOSED:
shared workspace/folder mounts are remounted `nosymfollow` in the sidecar so
dockerd can't follow a symlink out of the workspace during bind-source resolution
(verified live; compose `./path` binds unaffected). Full harness battery GREEN
(23/23 tools) + all 10 e2e GREEN under authz; 256 unit tests.

Cost/limitation: `--privileged`-needing tools (kind, k3d, helm-on-k3d, dind-in-dind)
are refused in DinD mode; their harness scripts assert that limitation. The compat
harness (`lib.sh`) runs the SHIPPED plugin via `authz-runner.mjs`, so every tool is
driven through the real guard. Escape red test `e2e-escape.sh` GREEN (no inner.sock;
raw privileged create over docker.sock → 403; symlink bypass closed; MaskedPaths
unmask denied); 239 gateway unit tests green (`dind-authz.test.ts`).

## STATUS (earlier): deep adversarial pass. 10 bugs fixed; ~30 automated tests.
Battery: `gateway/test/dind-compat/battery.sh` (all harness tools + real-gateway
E2Es -> docs/dind/RESULTS.md). Harness tools: compose, testcontainers, buildx,
privileged, k3d, kind, helm, localstack, act, devcontainer-cli, workspace,
isolation, kafka, multidb, rabbitmq, webdev, playwright, compose-build, registry,
resources, concurrent, nested2, exec-stream, egress. Real-gateway E2Es:
aspire-sqlserver, nested-egress, toolchain-ca (git/go/rust/pip/maven), restart,
restart-devcontainer, migrate, upgrade, grpc-noproxy, delete-cleanup.
Bugs fixed: proxy-crash, socket-perms, sidecar-CA, sudo-env, cgroup-delegation,
pip-CA, host.docker.internal-noproxy (Aspire dashboard gRPC). Migration classic<->
DinD + huddle migrate; in-place update + workspace-change survival verified.

## (earlier milestone) core complete + FULL E2E PASS.
212 gateway tests green; gateway+cli typecheck; Angular build passes; 11/11
tool-compat tests pass; and the full real-gateway Aspire+SqlServer E2E passes
(rc=0): huddle init (DinD) → real devcontainer → Aspire AppHost w/ SqlServer →
container Running → `SELECT @@VERSION` returns SQL Server 2022; no #12/#61 errors.
Two prod bugs found+fixed by the E2E: gateway crash on malformed proxied path;
sidecar dockerd CA trust for image pulls.

### Possible follow-ups (not blocking)
- Auto-inject proxy env into raw-API nested containers (Aspire DCP) — currently
  confined by internal net but not auto-proxied. Would need a daemon-side shim.
- Broaden workspace bridging beyond workspace+folder-mappings if a tool needs
  arbitrary devcontainer-local bind sources.
- More tools if desired: skaffold/tilt, dagger, minikube(docker), earthly.

## Smoke-test notes

### 2026-07-17 — Design N core mechanism validated (Docker 29 host)
Manual test outside huddle: devcontainer (`docker:28-cli`) + `dind-` sidecar
(`docker:28-dind`, `--privileged`, `--network container:<dc>`, shared socket
volume, `dockerd --host=unix:///var/run/dind/docker.sock`).
- Inner dockerd up in ~1s; devcontainer talks to it via the shared socket. ✓
- Nested `docker run -d -p 8080:80 nginx` ✓
- `docker inspect web` ✓ — the exact op that fails today with
  *"container not owned by this devcontainer"* (issue #61).
- Published port reachable from devcontainer at `localhost:8080` **and**
  `[::1]:8080` (what Aspire DCP addresses) — shared netns works. ✓
- `docker compose version` present in `docker:28-cli`. ✓
Conclusion: sidecar-shares-netns topology delivers the Aspire fix. Proceed.

