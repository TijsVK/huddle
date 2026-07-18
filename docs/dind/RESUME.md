# RESUME — Huddle DinD dark-factory build

**One-line resume prompt** (paste into a fresh Claude Code session in this repo):

```
Resume the autonomous DinD build on branch experiment/dind: read docs/dind/PROGRESS.md + RESULTS.md + TEST-BACKLOG.md, run `git log --oneline main..HEAD`, then continue. Dark factory: no questions, keep going, go maximally deep. Push to the TijsVK fork (remote `fork`), never the client account.
```

## State (2026-07-18)

- Branch `experiment/dind` → pushed to **`fork` = github.com/TijsVK/huddle** (personal). `origin` = infosupport upstream — never push there. gh active account must be **TijsVK** (`gh auth switch --user TijsVK` before any push).
- An hourly cron (job `7 * * * *`) re-checks for work (session-only; the background-job runtime resumes after usage-limit resets).

### ⭐ Latest: finding C1 (privileged host escape) MITIGATED via a dockerd AUTHZ PLUGIN
- **The escape is closed by a dockerd authorization plugin**, NOT a socket proxy. Sidecar dockerd runs `--authorization-plugin=huddle-authz` (`gateway/src/dind-authz.ts`); the gateway serves the plugin socket at `<sockdir>/plugin/huddle-authz.sock` (mounted into the sidecar at `/run/docker/plugins`). dockerd listens on `docker.sock` (mounted into the devcontainer). No `inner.sock`. Policy in `host-config-policy.ts` (`validateDindEscape`/`validateExecEscape`). See `SECURITY-CRITICAL.md`.
- **Why the pivot:** adversarial review found the earlier socket-proxy filter (`dind-filter.ts`, now deleted) bypassable — (1) devcontainer could hit the co-mounted raw `inner.sock`; (2) a workspace symlink bind reached the socket dir (dockerd follows symlink bind sources; lexical guard can't stop it). Both verified live. Authz removes the unfiltered socket entirely.
- **Closes findings #1/#2 (bypass), #3 (MaskedPaths/ReadonlyPaths unmask), #6 (path-norm), #7 (privileged exec), #8 (non-default seccomp/apparmor).** Under authz all binds are safe (docker.sock is authz-guarded) → Ryuk / docker-outside-of-docker work.
- **Cost:** `--privileged`-needing tools (kind/k3d/helm-on-k3d/dind-in-dind) refused in DinD mode — harness scripts assert that limitation. If the gateway is down, dockerd fails closed until the plugin reconnects (re-established on gateway restart before the sidecar (re)starts).
- **Harness runs the REAL plugin** (`lib.sh` + `authz-runner.mjs`). Full harness battery GREEN (23/23) + all 10 e2e GREEN under authz; 256 unit tests green.
- **Two adversarial reviews done.** Review 1 killed the socket-proxy filter (bypassable) → pivoted to authz plugin. Review 2 (of the authz plugin) found + fixed 4 more live-verified escapes: #1 case-insensitive JSON keys, #2 plugin-socket swap (→ read-only plugin mount), #3 `/proc/sys` host-kernel bind (→ deny /proc,/sys,/dev,/ binds; wrote host core_pattern before the fix), #4 partial MaskedPaths unmask (→ require runc-defaults superset).
- **#3 symlink variant CLOSED** (`ln -s /proc/sys /work/evil; -v /work/evil:/x`): shared workspace/folder mounts are remounted `nosymfollow` in the sidecar so dockerd can't follow a symlink out of the workspace during bind-source resolution. Verified live (bind fails, host core_pattern unchanged); compose `./path` binds unaffected. Requires Linux ≥ 5.10.

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
