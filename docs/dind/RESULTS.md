# DinD tool-compatibility results

Design N (per-devcontainer private Docker daemon sharing the devcontainer netns).
Each tool is driven **end-to-end with functional assertions** — not just "it ran" —
by `gateway/test/dind-compat/`. Reproduce with:

```bash
bash gateway/test/dind-compat/run.sh            # all tools
bash gateway/test/dind-compat/run.sh compose k3d # a subset
```

Host used for these runs: Docker 29.x, `docker:28-dind` sidecar, `docker:28-cli`
based test devcontainer. Tier-1 = tools on a normal network; Tier-2 (`egress`) =
the real Huddle constraint (internal network, all egress via a forward proxy).

| Tool | Result | What was proven (functional, not just "started") |
|------|--------|--------------------------------------------------|
| docker compose | ✅ pass | healthcheck-gated `up --wait`, service-name DNS, published port on `localhost` **and** `[::1]` |
| Testcontainers (node) | ✅ pass | container start, `getMappedPort` (inspect), `exec` → PONG, reachable mapped port, stop |
| BuildKit / buildx | ✅ pass | multi-stage `DOCKER_BUILDKIT=1` build, run result, `buildx build --load` |
| privileged / binds / volumes-from | ✅ pass | `--privileged` (mount tmpfs), host-path bind, `--volumes-from` — all socket-proxy-forbidden, all work; daemon isolated |
| k3d (Kubernetes) | ✅ pass | real cluster create, node Ready, deployment rollout, nginx pod Running |
| LocalStack | ✅ pass | container healthy on `localhost:4566`, real `aws s3 mb` succeeds |
| act (GitHub Actions) | ✅ pass | runner image pull, workflow step executed, job succeeded |
| Dev Containers CLI | ✅ pass | `devcontainer up` (build+start), **workspace files visible inside nested devcontainer**, `exec` |
| workspace bind-through | ✅ pass | shared workspace readable+writable in nested containers (both directions); non-shared path limitation asserted |
| egress (Tier-2) | ✅ pass | no direct internet without proxy; proxied HTTPS; image pull via proxy; nested egress via injected proxy; **loopback NOT proxied on `localhost` and `[::1]` (Aspire #12 fix)** |
| .NET Aspire | ⏳ running | #12 403 / CopyFile and #61 inspect-ownership all absent so far; container-Running assertion being finalized |

## Why these were failing before (classic socket-proxy)

- **Aspire** (#12/#61): DCP loopback proxied → 403; `docker CopyFile` blocked;
  `InspectContainers` → *"container not owned by this devcontainer"* → stuck.
- **Testcontainers / k3d / act / devcontainer-cli**: rely on unrestricted
  create/inspect/port-publish/bind that the proxy filters or the HostConfig
  allowlist denies.
- **privileged / host-bind / volumes-from**: hard-denied by `validateHostConfig`.

All of these are gone with a private daemon.

## Known limitations (see ARCHITECTURE.md)

- Nested containers created via the **raw Docker API** (e.g. Aspire DCP) are
  confined by the internal network but not auto-proxied (CLI/compose are).
- Bind mounts of **arbitrary devcontainer-local paths** (outside workspace +
  folder-mappings) mount empty in nested containers — the daemon's own fs.
- Nested images are pulled per-devcontainer (not shared with the host daemon).

## Notes

- Findings fixed during bring-up: proxy-env for nested containers must be injected
  client-side in the devcontainer using the **resolved** proxy IP (a nested
  container can't resolve the name `huddle`); the workspace must be mounted into
  the sidecar for bind-through to see real files. Both are in the gateway now.
