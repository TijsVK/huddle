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
- [ ] gh: user logs in as TijsVK; fork infosupport/huddle → TijsVK; add remote
- [ ] Gateway: sidecar bring-up (`dind.ts`) + DOCKER_HOST rewire under HUDDLE_DIND
- [ ] Gateway: proxy/CA injection into the private daemon for nested containers
- [ ] Gateway: permanent-grant + root-grant (default user) support
- [ ] Frontend: portal toggles for permanent grant + root grant
- [ ] CLI: HUDDLE_DIND plumbing to the gateway
- [ ] Tests: keep classic green; add DinD-mode + grant tests
- [ ] Build: gateway `npm run build`, cli typecheck, vitest
- [ ] Smoke test: sidecar dockerd + shared netns + compose workload + egress
- [ ] Docs: architecture doc + README notes
- [ ] Commit incrementally; push to TijsVK fork

## Smoke-test notes
(fill in as runs happen)
