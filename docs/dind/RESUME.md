# RESUME — Huddle DinD dark-factory build

**One-line resume prompt** (paste into a fresh Claude Code session in this repo):

```
Resume the autonomous DinD build on branch experiment/dind: read docs/dind/PROGRESS.md + RESULTS.md + TEST-BACKLOG.md, run `git log --oneline main..HEAD`, then continue. Dark factory: no questions, keep going, go maximally deep. Push to the TijsVK fork (remote `fork`), never the client account.
```

## State (2026-07-18)

- Branch `experiment/dind` → pushed to **`fork` = github.com/TijsVK/huddle** (personal). `origin` = infosupport upstream — never push there. gh active account must be **TijsVK** (`gh auth switch --user TijsVK` before any push).
- An hourly cron (job `7 * * * *`) re-checks for work (session-only; the background-job runtime resumes after usage-limit resets).

### ⭐ Latest: finding C1 (privileged host escape) MITIGATED + fully validated
- **The escape is closed.** Per-devcontainer host-escape filter (`gateway/src/dind-filter.ts`): sidecar dockerd on `inner.sock`, gateway serves the filtered `docker.sock`, devcontainer `DOCKER_HOST` → filter. Pure policy in `host-config-policy.ts` (`validateDindEscape`). Streaming HTTP/1.1 proxy that inspects every `/containers/create` and confirms hijacks from the RESPONSE (101/raw-stream) before raw-tunnelling — a create can never reach the daemon uninspected. See `SECURITY-CRITICAL.md`.
- **3 filter bugs found by MANUAL probing + fixed** (red→green): exec output dropped w/o `allowHalfOpen`; blanket bind-denial broke compose/testcontainers (DinD binds resolve against the disposable sidecar fs — only socket-dir binds refused); BuildKit `/grpc` h2c upgrade misparsed. Binding the *filter* socket is allowed (Testcontainers Ryuk) and stays filtered.
- **Cost:** `--privileged`-needing tools (kind/k3d/helm-on-k3d/dind-in-dind) refused in DinD mode — their harness scripts now assert that limitation.
- **The compat harness now runs the REAL filter** (`lib.sh` + `filter-runner.mjs`), not raw dockerd — faithful to the product.
- **Fully green through the filter:** 20/20 harness tools; all 10 e2e (escape, aspire-sqlserver, delete-cleanup, restart, migrate, upgrade, restart-devcontainer, grpc-noproxy, nested-egress, toolchain-ca); **245 unit tests**.
- Also hardened: MITM upstream `safeRequestPath` (finding #2); `audit_log` row-cap (200k).

## What's done
- **Design N** (per-devcontainer private Docker daemon; sidecar shares the devcontainer netns), gated by `HUDDLE_DIND=1`. Classic model still default; **245 unit tests green** (incl. the `dind-filter` suite).
- **7 bugs found + fixed** (red→green where applicable): gateway crash on malformed proxied path; private-daemon socket perms; sidecar CA trust for pulls; sudo env stripping; cgroup-v2 delegation (nested resource limits); pip CA (PIP_CERT); **host.docker.internal not in no_proxy → Aspire dashboard gRPC** (the user's reported issue).
- **Seamless migration** classic↔DinD (`huddle migrate`), in-place update, and workspace-change survival — all E2E-verified.
- **Grants**: permanent docker grant + root-for-vscode grant (replaces noot) — backend + Angular UI.
- **Full Aspire+SqlServer E2E** passes (real gateway): container Running, `SELECT @@VERSION` works, no #12/#61 errors.

## Test battery — `gateway/test/dind-compat/`
`bash battery.sh` runs everything → regenerates `docs/dind/RESULTS.md`.
Harness tools: compose, testcontainers, buildx, privileged, k3d, kind, helm,
localstack, act, devcontainer-cli, workspace, isolation, kafka, multidb, rabbitmq,
webdev, playwright, compose-build, registry, resources, concurrent, nested2,
exec-stream, egress. Real-gateway E2Es: aspire-sqlserver, nested-egress,
toolchain-ca, restart, restart-devcontainer, migrate, upgrade, grpc-noproxy,
delete-cleanup.

## Open / next
- Backlog (TEST-BACKLOG.md): Java Testcontainers, dagger/skaffold/tilt, gradle CA,
  IPv6/dual-stack. Env-gated (can't run here): real IDE attach, Podman/rootless,
  ARM64, GPU passthrough, host reboot.
- Remaining classic-huddle adversarial findings (NOT DinD-specific, pre-existing):
  proxy backpressure (#1), refresh_token scrub, C2 classic huddle-data theft, pty
  leak, leaf-cert cache. Weigh against destabilizing the shipping classic path.
- Could not reproduce a user-specific Aspire dashboard gRPC error beyond the
  host.docker.internal fix (non-interactive; no exact error text). If it persists,
  need the exact error string + whether resources are projects or containers.
