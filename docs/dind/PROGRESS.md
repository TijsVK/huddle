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

## STATUS: core complete. 212 gateway tests green; gateway+cli typecheck; Angular build passes; 11/11 tool-compat tests pass.

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

