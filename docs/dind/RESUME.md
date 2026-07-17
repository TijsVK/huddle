# RESUME — Huddle DinD dark-factory build

**One-line resume prompt** (paste into a fresh Claude Code session in this repo):

```
Resume the autonomous DinD build on branch experiment/dind: read docs/dind/PROGRESS.md + docs/dind/RESUME.md, run `git log --oneline main..HEAD`, then continue the task checklist. Dark factory: no questions, keep going. Push to the TijsVK fork (remote `fork`), never the client account.
```

## State snapshot (2026-07-17)

- Branch `experiment/dind`, pushed to **`fork` = https://github.com/TijsVK/huddle** (personal). `origin` = infosupport upstream — do NOT push there.
- gh active account must be **TijsVK** (`gh api user --jq .login`). A client account (`Tijs-VanKampen_reynaers`) also exists — never push with it.
- git identity in this repo is set (Tijs van Kampen / infosupport email).

### Done
- Design N locked (per-devcontainer private Docker daemon; sidecar shares the
  devcontainer netns). See PROGRESS.md.
- Gateway core: `gateway/src/dind.ts` (+ wiring in `docker.ts`, `index.ts`),
  CLI `cli/src/init.ts` — all behind `HUDDLE_DIND=1`. Typechecks; 204 tests pass.
- Tool-compat harness in `gateway/test/dind-compat/` (Docker-driven, runs the
  real topology). Passing FULLY: compose, testcontainers, buildx, privileged
  (incl. proxy-forbidden ops), k3d, localstack.

### In progress / next
1. Run `gateway/test/dind-compat/tools/egress.sh` (Tier-2 proxy path; written).
2. Write + run `tools/aspire.sh` (dotnet + Aspire repro from #12/#61).
3. Write `run.sh` runner that emits `docs/dind/RESULTS.md`.
4. Feature: root-for-vscode grant (time-limited + permanent) replacing the
   noot/password dance. Plan in PROGRESS + agent report.
5. Feature: permanent (non-expiring) docker grant (sentinel `until`, no schema
   migration). Mostly moot under DinD but keep portal toggle usable.
6. Docs: `docs/dind/ARCHITECTURE.md` + README notes.
7. Commit incrementally; `git push fork experiment/dind`.

### How to run the harness
```
cd /home/tijs/repos/huddle
bash gateway/test/dind-compat/tools/compose.sh      # any single tool
# image build (first run): auto-built from Dockerfile.testdc
```
Needs a working host Docker (29.x present). Each tool self-reports PASS/FAIL.
