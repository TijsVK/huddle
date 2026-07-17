# Huddle DinD experiment — autonomous build log

> **Dark-factory control doc.** This file is the durable state for a long-running,
> unattended build on branch `experiment/dind`. If context is reset or the session
> resumes after a usage-limit reset, **read this first**, run `git log --oneline main..HEAD`,
> then continue from the first unchecked step.

## Goal

Run Huddle with **Docker-in-Docker** instead of exposing the host Docker socket
to the gateway. Same features; the nested engine's isolation lets us relax the
host-escape restrictions ("more freedom, no more risk").

## Architecture — Design S (single nested engine)

```
Host Docker daemon
  └─ huddle-engine        (docker:dind, --privileged, ONLY host-privileged unit)
       ├─ huddle gateway  (orchestrator + egress firewall + portal)
       ├─ devcontainer-*  (DOCKER_HOST → per-container filtering socket-proxy)
       └─ child containers spawned by devcontainers / compose
```

- Host daemon is never reachable from the gateway or any devcontainer. An escape
  reaches only `huddle-engine`, a disposable nested daemon → host is shielded by
  a single DinD boundary.
- The per-container **socket-proxy stays** (labels, network injection, proxy-env
  injection, per-action grants, portal Docker Access page all unchanged).
- Host-escape denials in `validateHostConfig` (Privileged / host binds / Devices /
  VolumesFrom / etc.) **relax when `HUDDLE_DIND=1`** because "host" is now the
  disposable engine. Cross-devcontainer `huddle.parent` ownership checks stay.
- Gated by `HUDDLE_DIND=1`. Classic host-socket model remains the default so the
  existing security tests stay valid.

### Workspace bridging

The nested engine has its own filesystem. Host workspaces are made visible by
mounting a host projects root into `huddle-engine` at the identical path
(`HUDDLE_WORKSPACE_ROOT`, default `$HOME`). Same mechanism Docker Desktop uses.

## Decisions (made autonomously — no user available)

- Branch: `experiment/dind` (kept local; pushing `experiment/**` triggers the
  image-publish pipeline, a side effect not requested).
- Single shared engine (Design S), not per-devcontainer DinD: minimal diff, keeps
  the socket-proxy feature set and portal semantics intact, still delivers the
  isolation + freedom thesis.
- Feature-flag `HUDDLE_DIND` so both models coexist and classic tests stay green.

## Task checklist

- [x] Explore architecture, lock design
- [x] Create branch + this doc
- [ ] Gateway: parameterize upstream socket + `HUDDLE_DIND` relaxation in socket-proxy
- [ ] Gateway: `HUDDLE_DIND`-aware validateHostConfig
- [ ] CLI: `huddle init` brings up `huddle-engine`, runs gateway inside it, no host socket
- [ ] CLI: runtime/workspace-root plumbing
- [ ] Tests: keep classic green; add DinD-mode tests
- [ ] Build: gateway `npm run build`, cli typecheck
- [ ] Smoke test: bring up `huddle-engine` + gateway, hit portal
- [ ] Docs: architecture doc + README notes
- [ ] Commit incrementally

## Smoke-test notes

(fill in as runs happen)
