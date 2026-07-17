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

**All workflows below pass**, each with functional assertions. This table is
hand-maintained; `battery.sh` regenerates a fresh combined report on a full run.
~24 distinct dev workflows + the real-gateway Aspire+SqlServer E2E; 6 bugs found
and fixed along the way (listed below).

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
| .NET Aspire | ✅ pass | DCP-spawned container reaches **Running**; **no #12 403**, **no CopyFile block**, **no #61 "not owned by this devcontainer"** |
| isolation (adversarial) | ✅ pass | private daemon shows no host/peer containers; can't see a peer devcontainer; privileged nested container confined to the private daemon |
| nested runtime egress | ⚠️ boundary | nested-container HTTPS **routes through the proxy**; CA trust not auto-injected into nested containers (mount the CA / set `SSL_CERT_FILE`) — expected, matches Docker Desktop behind a corporate MITM |
| Kafka (Testcontainers) | ✅ pass | create topic + produce + consume via the **advertised listener** (mapped port on the devcontainer's localhost, shared netns) |
| toolchain CA matrix | ✅ pass | git / `go mod` / rustup / `cargo fetch` all work through the MITM (system trust store). Surfaced+fixed: **sudo dropped the proxy/CA env** → `sudo apt-get` had no network; fixed with a sudoers `env_keep` drop-in |
| multi-DB (compose) | ✅ pass | Postgres + MySQL + MongoDB health-gated, each answers a query |
| RabbitMQ | ✅ pass | AMQP publish + consume over localhost:5672 (shared netns) |
| web dev / HMR | ✅ pass | dev-server HTTP + **WebSocket round-trip** over a mapped port on localhost |
| Playwright | ✅ pass | headless Chromium download + drives a page served by a nested container |
| compose build-context | ✅ pass | `compose up --build` builds from a workspace Dockerfile (shared into the daemon) and serves the built file |
| local registry | ✅ pass | build → push → pull → run round-trip to a nested `registry:2` |
| resource limits | ✅ pass | `--memory` / `--cpus` / `--pids-limit` enforced on nested containers (cgroup-v2 delegation) |
| restart resilience | ✅ pass | after a gateway restart: egress restored (dc-net rejoin + iptables refresh), private daemon reachable, root grant persists, sidecar running |
| helm on k3d | ✅ pass | scaffold a chart, `helm install --wait` → release deployed, pod Running |
| kind | ✅ pass | kubeadm node + systemd-in-container, `kind load docker-image`, pod from sideloaded image Ready |
| toolchain: pip | ✅ pass | `pip install` through the MITM (PIP_CERT fix — pip's certifi bundle) |
| toolchain: maven/JVM | ✅ pass | reaches Maven Central through the MITM, JVM trusts the CA (no TLS error) via ca-certificates-java |
| **in-place update** | ✅ pass | rule + grant + action-policy + settings + folder-mapping + devcontainer all survive a gateway update (re-init, same volume/token); docker access restored + enforcing |
| **workspace changes** | ✅ pass | worktree idempotent: cloned repo + committed/uncommitted/untracked changes survive migrate/recreate (unit test) |
| **migration** classic→DinD | ✅ pass | classic devcontainer + firewall rule → switch gateway to DinD → rule preserved → `migrate` → private daemon, docker fully works |

### Bugs found and fixed during testing
1. Gateway crash on a malformed proxied path (`ERR_UNESCAPED_CHARACTERS`) — took the whole gateway down.
2. Private-daemon socket root-only → non-root user (Aspire) got permission denied → DCP marked runtime unhealthy.
3. Sidecar dockerd didn't trust the Huddle MITM CA → image pulls failed `x509: unknown authority`.
4. `sudo` reset the environment → `sudo apt-get`/pip had no proxy/CA → no network.
5. cgroup-v2 controllers not delegated (bypassed `dockerd-entrypoint.sh`) → nested `--memory`/`--cpus` not enforced.

## Full end-to-end (real gateway, not the harness stand-in)

`gateway/test/dind-compat/e2e-aspire-sqlserver.sh` runs the **actual** stack:
`huddle init` (HUDDLE_DIND=1) → allowlist nuget/mcr in the firewall →
`/api/docker/start` a real VS Code devcontainer → inside it, a .NET Aspire
AppHost with **SqlServer** (issue #61's exact repro) → confirm the SQL container
comes up and answers a query.

Verified on Docker 29 (WSL2):
- ✅ real gateway boots in DinD mode; devcontainer + private daemon created by the gateway's own code
- ✅ private daemon reachable as the non-root `vscode` user
- ✅ `dotnet restore` succeeds through the Huddle egress firewall (MITM + CA)
- ✅ DCP reconciles the SqlServer container — **no "not owned by this devcontainer"** (issue #61 was exactly this)
- ✅ SqlServer image (~1.7 GB) pulls through the proxy; container reaches Running
- ✅ **`SELECT @@VERSION` returns "Microsoft SQL Server 2022"** — fully functional
- ✅ no #12 (403 / CopyFile) and no #61 (inspect ownership) errors in the AppHost/DCP logs

Two production bugs were found and fixed by this E2E:
1. **Gateway crash on a malformed proxied path** (`ERR_UNESCAPED_CHARACTERS`) —
   a single odd request path from DCP took the whole gateway down. Now the
   forwarded path is percent-encoded and that error class is non-fatal.
2. **Sidecar dockerd didn't trust the Huddle MITM CA** → image pulls failed
   `x509: unknown authority`. The sidecar now installs the CA before dockerd.

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
