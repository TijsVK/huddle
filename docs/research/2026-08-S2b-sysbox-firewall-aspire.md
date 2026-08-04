# S2′b — firewall + Aspire E2E under `HUDDLE_SYSBOX=1`

**Date:** 2026-08-04. **Branch:** `experiment/sysbox` (off `experiment/dind-rootless`).
**Host:** WSL2, kernel 6.6.114.1, Debian 13, Docker 29.6.2, Sysbox CE 0.7.1.
**Companion docs:** the isolation survey and the escape matrix live on branch
`worktree-research-isolation-backing-layer` (`docs/research/2026-08-isolation-backing-layer.md`,
`docs/research/2026-08-S2-sysbox-spike-results.md`).

These were the two things worth proving: **does the firewall still work**, and **does Aspire work
end-to-end** — the case that fails on current Huddle and that no previous experiment fixed.

## What was built

A third gateway mode next to classic (socket-proxy) and DinD (sidecar + authz plugin):
`HUDDLE_SYSBOX=1`. The devcontainer itself runs under `sysbox-runc` and `dockerd` starts
**inside** it.

- No sidecar, no shared network namespace, no authz plugin, no socket-proxy, no host-escape
  filter to maintain.
- Isolation is Sysbox's user namespace + virtualized `/proc` and `/sys`.
- Egress model untouched: `dc-net-*` stays `Internal: true`, identical proxy/CA env, and the
  nested-container client-proxy config plus the `docker0`/`br+` OUTPUT exemptions are shared with
  DinD mode through a new `PRIVATE_DAEMON` flag.
- Touched: `gateway/src/docker.ts` (mode switch, `Runtime: sysbox-runc`, in-container dockerd
  bootstrap), `cli/src/init.ts` (env passthrough).

## Firewall — 14/14 (`gateway/test/dind-compat/e2e-sysbox-firewall.sh`, real gateway)

| Check | Result |
|---|---|
| gateway init in sysbox mode | ✅ |
| devcontainer up with its own in-container dockerd, no sidecar | ✅ |
| allowlisted domain reachable (MITM CA trusted) | ✅ `200` |
| **not**-allowlisted domain blocked | ✅ `000` |
| blocked attempt appears as a firewall **request** in the portal | ✅ |
| operator approval accepted by the API | ✅ |
| approval takes effect **live** on a running devcontainer, no restart | ✅ `200` |
| nested container reaches allowlisted domain through the proxy | ✅ `200` |
| nested container blocked for not-allowlisted domain | ✅ `000` |
| nested container cannot bypass by direct IP | ✅ `000` |
| root flushes in-container iptables, then tries direct IP | ✅ still blocked |
| DNS from the devcontainer | blocked (proxy resolves; CONNECT carries the hostname) |
| network log records the devcontainer's requests | ✅ |

The request→approve loop — the product's core UX — behaves identically under Sysbox, and the
in-container iptables stay what they always were: defence-in-depth. The real egress boundary is
the `--internal` `dc-net-*`, which guest root cannot undo (verified by flushing the rules as root
and still failing to reach a direct IP).

**Harness note:** an earlier version of this script also flushed `nat OUTPUT`, which removes
Docker's embedded-DNS DNAT (`127.0.0.11:53`) and broke DNS for every nested container afterwards.
That was a harness artefact, not a product finding; the script now flushes only the filter chain.

## Aspire E2E — 9/9 (`gateway/test/dind-compat/e2e-sysbox-aspire.sh`, real gateway)

Full path: gateway → devcontainer → .NET Aspire AppHost with a **project resource** (ASP.NET +
EF Core) referencing a **SqlServer container**; `nuget restore` through the firewall;
`WaitFor(db)` health checks; DB round-trip through the project's HTTP endpoint; then the
dashboard is actually fetched and asserted, not log-grepped.

| Check | Result |
|---|---|
| `ASPIRE_ALLOW_UNSECURED_TRANSPORT` injected by the gateway | ✅ |
| AppHost + EF project build (nuget via the proxy) | ✅ |
| project → SqlServer round-trip via Aspire service discovery | ✅ `{"count":1,"first":"hello-from-ef"}` |
| dashboard on plain http (unsecured transport inherited) | ✅ |
| no dashboard gRPC `UntrustedRoot` / cert errors | ✅ |
| dashboard Blazor UI boots (served circuit markup) | ✅ |
| no dashboard runtime circuit/gRPC errors | ✅ |

**Why this is structurally easier here.** Nested containers run on the devcontainer's *own*
Docker daemon, so their published ports land on the devcontainer's real `localhost` with no
`--network container:<dc>` trick. That is exactly what Aspire's DCP assumes
(`http://[::1]:<port>`), so the shared-netns gymnastics the DinD design needed to reach the same
place are unnecessary. Health checks over those published ports work for the same reason.

## Scope caveat — read before claiming the bug is fixed

This is the same harness scenario the DinD branch also passes. It proves the Aspire path works
end-to-end under Sysbox with the firewall on. It does **not** prove the user-visible failure is
gone, because:

- the harness builds its own minimal AppHost, not a real solution;
- no IDE backend is in the loop (no Rider/IntelliJ remote backend, no VS Code server), and the
  reported failure happens in IDE-driven use;
- only `huddle-e2e-base-sysbox` was used, not the shipped `base-devimage-*` images.

To settle it, the next run needs the **actual failing repo** plus the IDE backend running under
Sysbox mode.

## Follow-ups

1. Reproduce the real-world Aspire failure in sysbox mode with the actual solution + IDE backend.
2. Build a `base-devimage-*` variant with a Docker engine (the shipped images carry only the CLI)
   and re-run the E2Es against it.
3. Run the rest of the `dind-compat` battery (`testcontainers`, `k3d`, `act`, `devcontainer-cli`,
   `kafka`, `localstack`, …) in sysbox mode.
4. S3′: engine host + IDE attach on Windows (WSL2 distro), macOS (Lima) and native Linux.
5. Decide the residual mount policy: Sysbox blocks nested escapes, but *outer* bind mounts are
   still Huddle's call — that policy stays, minus everything the authz plugin did.

## Reproduce

```bash
# images (once): huddle-local:dind, huddle-e2e-base:latest, huddle-e2e-base-sysbox:latest
docker build -t huddle-local:dind ./gateway
docker build -t huddle-e2e-base:latest -f gateway/test/dind-compat/Dockerfile.e2e-base gateway/test/dind-compat
printf 'FROM huddle-e2e-base:latest\nENV DEBIAN_FRONTEND=noninteractive\nRUN apt-get update && apt-get install -y --no-install-recommends docker-ce containerd.io && rm -rf /var/lib/apt/lists/*\n' \
  | docker build -t huddle-e2e-base-sysbox:latest -f - .

bash gateway/test/dind-compat/e2e-sysbox-firewall.sh   # 14 checks
bash gateway/test/dind-compat/e2e-sysbox-aspire.sh     # 9 checks, ~20 min (1.7GB SqlServer pull)
```
