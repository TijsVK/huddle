# RESUME — Huddle DinD dark-factory build

**One-line resume prompt** (paste into a fresh Claude Code session in this repo):

```
Resume the autonomous DinD build on branch experiment/dind: read docs/dind/PROGRESS.md + RESULTS.md + TEST-BACKLOG.md, run `git log --oneline main..HEAD`, then continue. Dark factory: no questions, keep going, go maximally deep. Push to the TijsVK fork (remote `fork`), never the client account.
```

## State (2026-07-18)

- Branch `experiment/dind` → pushed to **`fork` = github.com/TijsVK/huddle** (personal). `origin` = infosupport upstream — never push there. gh active account must be **TijsVK**.
- An hourly cron (job `7 * * * *`) re-checks for work (session-only; the background-job runtime resumes after usage-limit resets).

## What's done
- **Design N** (per-devcontainer private Docker daemon; sidecar shares the devcontainer netns), gated by `HUDDLE_DIND=1`. Classic model still default; 214 unit tests green.
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
- Known cosmetic bug: `battery.sh` `[ -f ] && runone || log` mislogs "skip (missing)"
  for passing tests (runone returns non-zero on success). Fix with if/then/else
  (only when the battery is NOT running — editing a live bash script is unsafe).
- Backlog (TEST-BACKLOG.md): Java Testcontainers, dagger/skaffold/tilt, gradle CA,
  IPv6/dual-stack. Env-gated (can't run here): real IDE attach, Podman/rootless,
  ARM64, GPU passthrough, host reboot.
- Could not reproduce a user-specific Aspire dashboard gRPC error beyond the
  host.docker.internal fix (non-interactive; no exact error text). If it persists,
  need the exact error string + whether resources are projects or containers.
