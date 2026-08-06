# What to clean up before this can be a reviewable change

**Date:** 2026-08-05. **Branch:** `experiment/sysbox`.

## The core problem: lineage, not leftovers

`experiment/sysbox` is branched off `experiment/dind-rootless`, which is branched off
`experiment/dind`. So its diff against `main` is **not** "the sysbox feature":

```
141 commits ahead of origin/main
  44  sysbox-era
  97  DinD / rootless / other
122 files changed, +9077 / -2364
```

Deleting the DinD files from *this* branch does not fix that — the PR would still carry 97 commits
of unrelated experiment history, and the reviewer would see the DinD work added and then removed.

**Recommendation: build the shippable branch fresh from `main` and port the sysbox feature onto it.**
The port is mechanical (see coupling below), and the result is reviewable: roughly **~2 000 lines**
instead of 9 000, with no DinD in the history at all.

## What is genuinely DinD-only (does not ship)

| Path | Lines | Note |
|---|---|---|
| `gateway/src/dind.ts` | 469 | sidecar lifecycle |
| `gateway/src/dind-authz.ts` | 156 | dockerd authorization plugin |
| `gateway/test/dind-authz.test.ts` | 164 | its unit tests |
| `gateway/test/dind-compat/authz-runner.mjs` | 22 | plugin harness |
| `docs/dind/*` | ~1 100 | 8 design/progress documents |
| `gateway/test/dind-compat/` DinD scripts | ~2 000 | `lib.sh`, `run.sh`, `battery.sh`, `tools/*.sh` (30 files), `e2e-*.sh` (15) |

The tool battery is genuinely valuable as a *compatibility* suite, but it is written against the
DinD topology (`lib.sh` builds devcontainer + sidecar + authz plugin). Porting it to sysbox is a
separate, worthwhile piece of work — not a precondition for this change.

## Coupling that has to be untangled during the port

- `gateway/src/docker.ts` imports `./dind` (`ensureDindSockVolume`, `createDindSidecar`,
  `removeDindSidecar`, `DIND_*` constants); `index.ts` and `api.ts` import it too.
- **Sysbox mode reuses three things written for DinD**, which must be lifted out of the DinD module
  rather than deleted with it:
  1. `dindClientProxyConfig()` — proxy env for nested containers via `~/.docker/config.json`;
  2. the `docker0` / `br+` OUTPUT exemptions that make nested published ports reachable;
  3. the `PRIVATE_DAEMON` notion (no socket-proxy, nested-proxy config) — rename to something
     mode-neutral, e.g. `OWN_DAEMON`.
- `gateway/src/host-config-policy.ts` is **not** DinD-only any more: `socket-proxy.ts` imports it, so
  it is classic-mode hardening. Keep, or split out as its own PR against `main`.
- `gateway/src/root-grant.ts` is a product feature (portal grant), used by `api.ts`, `index.ts` and
  `docker.ts`. It originated on the DinD branch but stands alone. Under sysbox it is close to
  meaningless (container root is host uid 165536+), so decide: keep as-is, or make it a no-op in
  sysbox mode like the Docker-permissions UI.

## Debris the sysbox work itself created

| Item | Disposition |
|---|---|
| `scripts/huddle-docker.cmd` | **delete** — superseded by `huddle-docker.cs`/`.exe`; keeping both invites using the broken one (cmd.exe's UNC preamble) |
| `e2e-sysbox-firewall-realimage.sh` | **merge** into `e2e-sysbox-firewall.sh` — identical but for the image; make it a `$BASE_IMAGE` parameter |
| `e2e-sysbox-egress.sh` | **delete** — its checks are a subset of `e2e-sysbox-firewall.sh` |
| `e2e-sysbox-aspire.sh` / `-volume.sh` | keep both (different scenarios), but move out of `dind-compat/` into e.g. `gateway/test/sysbox/` |
| `docs/research/*` (5 files, ~1 100 lines) | research notes, not product docs. Keep **one** (the Windows runbook) in the repo; the survey/spike write-ups belong in the notes repo or a wiki |
| `.gitattributes` | **rescope** — see below |

## `.gitattributes` is a trap in its current form

It fixed a real bug (`.sh` checked out CRLF broke the engine installer), but adding it to a repo that
never had one makes git renormalize the entire tree on a Windows checkout: we saw **190 files** show
as modified with EOL-only diffs, and I told you to `git add --renormalize .`, which staged all of it.
In a PR that is indistinguishable from a catastrophe.

Options, in order of preference:
1. Ship it **with** a single normalization commit (`git add --renormalize .`) made deliberately, on
   its own, so the noise is isolated and reviewable — and mention it in the PR description.
2. Scope it to exactly the files that need it (`scripts/*.sh`, `gateway/test/**/*.sh`).
3. Drop it and rely on the `sed 's/\r$//'` guard already in the engine bootstrap.

## Test/CI story that a reviewer will ask about

- The sysbox E2Es need a **Linux host with sysbox installed**; they cannot run in normal CI. Either
  mark them clearly as manual (`e2e-sysbox-*` are already driven by hand) or add a self-hosted runner.
- `gateway/test/dind-compat/Dockerfile.e2e-base` is still required for the sysbox tests (the
  `huddle-e2e-base-sysbox` image builds `FROM` it). If the DinD harness goes, that file has to move
  with the sysbox tests.
- Nothing in the automated unit suite covers sysbox mode yet. The cheap wins: `SYSBOX_ENABLED`
  container-create shape (runtime, restart policy, `/var/lib/docker` volume, no socket-proxy mount)
  and `/api/auth/status` reporting the mode.

## Product decisions still open (they change the shape of the PR)

1. **Does DinD mode ship at all?** If sysbox supersedes it, the honest PR deletes `HUDDLE_DIND`
   entirely rather than leaving three modes to maintain. If it stays as a fallback for hosts without
   sysbox, then all three need a documented capability matrix and the test burden triples.
2. **Does classic mode stay the default?** Sysbox needs an engine host, which is a real
   prerequisite on Windows/macOS. Probably yes for now, with sysbox opt-in.
3. **`needsMigration()` / `huddle migrate`** know only classic ↔ DinD. Whatever the answer to (1),
   they need to learn the third mode or lose the second.

## Suggested sequence

1. Decide (1) above — it determines everything else.
2. New branch off `main`; port: `docker.ts` sysbox switch + lifted helpers, `init.ts` passthrough,
   `api.ts` mode field, `auth.service.ts`/sidebar, `base-devimage` build arg, `huddle.ps1` changes,
   `huddle-engine.ps1`, `scripts/huddle-engine-install.sh`, `scripts/huddle-docker.cs`, the two
   sysbox E2Es + `Dockerfile.e2e-base`, the Windows runbook.
3. Separate PRs for the independently-useful bits currently mixed in: `host-config-policy`
   hardening, `dns-egress`, the audit-prune/worktree/proxy-path tests, the `.gitattributes`
   normalization.
4. Re-run on the engine: firewall E2E, Aspire E2E, a clean VS Code attach.
</content>
