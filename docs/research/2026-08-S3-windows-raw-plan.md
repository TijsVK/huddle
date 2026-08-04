# Running Huddle+Sysbox "raw" on a Windows dev host — what's left

**Date:** 2026-08-04. **Branch:** `experiment/sysbox`. **Status:** plan, derived from what the
S2′/S2′b spikes actually proved on WSL2.

What already works, measured (see `2026-08-S2-sysbox-spike-results.md`,
`2026-08-S2b-sysbox-firewall-aspire.md`): Sysbox 0.7.1 on the WSL2 kernel, devcontainer under
`sysbox-runc` with its own unprivileged `dockerd`, all DinD-red-test escape vectors blocked,
firewall 14/14 including the live approve loop, and the Aspire project+SqlServer E2E 9/9.

What "raw on a Windows host" means concretely: a developer on Windows 11 runs `huddle init`, gets
devcontainers that are Sysbox sandboxes with a real Docker inside, opens them in Rider/VS Code,
and the firewall behaves as it does today. Everything below is what stands between here and that.

---

## 1. Engine host: Huddle must own a WSL2 distro

Sysbox is Linux software that has to be installed **on the Docker host**. On Windows that host
cannot be Docker Desktop's own distro (managed by Docker; the equivalent there is ECI, which is
Business-tier and Desktop-only). So Huddle needs its own engine host: a dedicated WSL2 distro.

**Implementation — `huddle engine` bootstrap (new):**
1. Create/import a distro (e.g. `huddle-engine`, Ubuntu 24.04 — Sysbox's best-tested distro).
2. `/etc/wsl.conf`: `[boot] systemd=true` (Sysbox ships systemd units; measured working here).
3. Install `docker-ce` + `containerd.io`.
4. Install `sysbox-ce` **before any containers exist** — the installer refuses to proceed while
   containers are present and must restart `dockerd` (measured). This is why it belongs in
   provisioning, never as a live migration on a working host.
5. Reconcile Docker's address pools: the Sysbox installer wanted `bip 172.20.0.1/16` and
   `default-address-pool 172.25.0.0/16` and **skipped both** here because they overlapped
   existing subnets. Huddle's `dc-net-*` allocation has to be planned against whatever the engine
   host uses.
6. Verify prerequisites and fail loudly if absent: kernel ≥ 5.19, `/dev/fuse`, cgroup v2, userns.

**Known Windows wrinkles to design around:**
- **WSL2 distros share one network namespace.** A second `dockerd` in the engine distro coexists
  with Docker Desktop's, but they share netfilter and published ports. Expect port collisions and
  iptables-chain churn; decide whether Huddle requires Docker Desktop to be off, or picks
  non-colliding ports and address pools.
- **Published ports** reach Windows via WSL's localhost forwarding, so the portal on `:3000` and
  IDE connections work without extra plumbing.
- **Workspaces belong in the distro filesystem, not `/mnt/c`** — `drvfs` is slow and its
  permission model fights ID-mapped mounts. Huddle already uses git worktrees, so point them at
  distro-local storage. (Note: on this box `/mnt/c` isn't even mounted, which is a *better*
  posture — worth keeping as the default.)

---

## 2. Devcontainer images need a Docker engine

The shipped `base-devimage-*` images contain the docker **CLI** only; Sysbox mode needs `dockerd`
**inside** the devcontainer. The spikes used a purpose-built `huddle-e2e-base-sysbox` image.

**Implementation:**
- Add `docker-ce` + `containerd.io` to the base images (or ship `-sysbox` variants selected by
  mode). Cost: a few hundred MB per image.
- **Mount a volume at `/var/lib/docker`.** Today the inner daemon writes into the container's
  writable layer, i.e. overlay-on-overlay: slower, and every nested image bloats the sandbox's
  snapshot (and any `docker commit`). Nestybox recommends a dedicated volume; this also gives a
  natural place to prune.
- Decide the supervision model for the inner daemon. Current bootstrap is a `nohup dockerd` from
  the config script — fine for a spike, not for a workday. Two options:
  - keep the script but add a restart-on-crash watchdog + log rotation; or
  - run **systemd as PID 1** inside the devcontainer (Sysbox's showcase, and what the Nestybox
    image does), which conflicts with Huddle's current `sleep infinity` entrypoint and changes how
    the IDE backends are launched. This is a design decision, not a detail.

---

## 3. IDE attach (the S3′ spike, still open)

Today JetBrains Gateway attaches with `connectionParams.type: "docker"` against the **local**
Docker daemon, and Huddle discovers the gateway link by grepping the backend log inside the
container. With an engine-host distro the daemon is no longer "local" to Windows.

**To verify:** `docker context` / `DOCKER_HOST=ssh://…` from Windows to the engine distro; Gateway's
"add Docker server over SSH"; VS Code Dev Containers "attach to running container" against that
context; and whether the gateway-link discovery still works through it. Also whether the JetBrains
backend runs happily inside a Sysbox userns (no reason it shouldn't — it is an ordinary process —
but it is unproven).

---

## 4. Product surface that changes in Sysbox mode

- **Delete/hide the per-action Docker policy UI** for sysbox devcontainers: the daemon is private
  and unrestricted, so the toggles are meaningless (the DinD mode has this same inconsistency
  today, and it is the one silent divergence worth not repeating).
- **`needsMigration()` / `huddle migrate`** must know about a third mode, so classic/DinD→sysbox is
  a recreate like the existing migration.
- **Root grant** becomes uninteresting: root inside a Sysbox userns is not host root (measured:
  container root maps to host uid 165536). Simplify to "always available", or keep it as an audit
  affordance only.
- **Snapshots** (`docker commit` of a Sysbox container) are untested. Sysbox has a historical
  commit issue on kernels < 5.19; we are on 6.6, so it likely works — but the portal offers this
  button, so it needs a test.
- **Outer mount policy stays Huddle's job.** Sysbox stops nested escapes (verified: a nested
  container binding `/` sees the sandbox, not the host), but what Huddle itself bind-mounts into
  the devcontainer is still a policy decision — that part of `host-config-policy` survives, minus
  everything the authz plugin did.
- **Portal must show the boundary per devcontainer** (userns / shared-kernel / hypervisor) so the
  claim never outruns the mechanism.

---

## 5. Remaining spikes, in order

| # | Spike | Pass criteria | Size |
|---|---|---|---|
| **S6** | **RUN — see §7. Partly answered:** `WithDataVolume()` works on a fresh volume; the **restart-on-existing-volume** case reproduces a real failure that is *not* Sysbox's fault. Remaining: same cycle under DinD/classic for comparison, and with a clean AppHost shutdown. | SqlServer healthy after restart on an existing volume | ½ day remaining |
| **S7** | Engine-host bootstrap on a real Windows 11 box: dedicated WSL2 distro, systemd, docker-ce, sysbox, address pools, portal reachable from Windows | `huddle init` completes; a devcontainer starts under `sysbox-runc`; firewall E2E passes from Windows | 1–2 days |
| **S8** | IDE attach (§3) for Rider/IntelliJ **and** VS Code against the engine host | project opens, backend runs, gateway link discovered, terminal works | 1–2 days |
| **S9** | `base-devimage-*` with engine + `/var/lib/docker` volume; rerun firewall + Aspire E2Es against the **shipped** image | both E2Es green on the real image; sandbox snapshot size sane | 1 day |
| **S10** | Rest of the `dind-compat` battery in sysbox mode (testcontainers, k3d, act, devcontainer-cli, kafka, localstack, compose-build, registry, exec-stream, workspace) | parity with DinD results, or documented deltas | 1–2 days |
| **S11** | Workspace-mount performance + uid/gid behaviour under ID-mapped mounts (build a real solution, measure against classic mode); snapshot/`docker commit` test | no worse than ~1.2× classic on a real build; commit works | 1 day |
| **S12** | macOS (Lima) and native-Linux engine hosts, for the three-platform requirement | same E2Es green on both | 2 days |

**Ordering logic:** S6 answers *the* open product question (the real Aspire bug). S7+S8 answer
"can a developer actually use this on Windows". S9 makes it real rather than harness-only.
S10–S12 are breadth and parity.

---

## 6. Risks worth naming now

1. **Two Docker daemons on one WSL netns** (Desktop + engine host) is the most likely source of
   weird, hard-to-debug behaviour on Windows. Mitigation: recommend/require Desktop off, or own
   the whole engine host.
2. **Distro sprawl and disk.** Nested images live per-devcontainer, so disk grows faster than the
   current model (where they share the host daemon). Needs a prune story and the `/var/lib/docker`
   volume.
3. **Sysbox install is disruptive** (restarts dockerd, refuses with containers present) → strictly
   a provisioning-time operation.
4. **Debian 13 is not on Sysbox's tested-distro list** (it worked here). For the shipped engine
   host, prefer Ubuntu 24.04, which is.
5. **Upstream dependency**: Sysbox CE is Docker-owned and actively maintained (v0.7.1, 2026-07-31),
   but it is one project; the fallback if it stalls is the Kata/microVM path already surveyed.

---

## 7. S6 findings — the reported SqlServer failure, reproduced and narrowed

Test: `gateway/test/dind-compat/e2e-sysbox-aspire-volume.sh` — Aspire AppHost with
`AddSqlServer(...).WithDataVolume("sbx-mssql-data")` and a project gated on its health check
(`WaitFor(db)`), under `HUDDLE_SYSBOX=1` with the firewall on.

| Case | Result |
|---|---|
| **A.** first run, fresh persistent volume | ✅ SqlServer healthy, dependent project started, DB round-trip `{"count":1,"first":"persisted-widget"}`, no permission errors |
| **B.** AppHost restarted against the **same** volume | ❌ SqlServer exits 1, dependents never start |
| **C.** `WithDataBindMount()` into the workspace | run did not complete in the window; not yet characterised |

Case B's actual error, from the SQL Server container's own log:

```
/opt/mssql/bin/sqlservr: Error: The system directory [/.system] could not be created.
File: LinuxDirectory.cpp:420 [Status: 0xC0000022 Access Denied errno = 0xD(13) Permission denied]
SQL Server 2022 will run as non-root by default.  This container is running as user mssql.
```

Note *where* it fails: `/.system` at the **container root**, not in the mounted volume. The volume
itself was fine — `data/`, `log/`, `secrets/` all owned by `10001:10001`.

**Two control experiments narrow this down:**

1. **Plain `runc` on the host daemon**, same image, same fresh-then-reuse volume cycle:
   both runs reach "SQL Server is now ready" — reuse is fine, and `/.system` never exists.
2. **Inside the Sysbox sandbox, plain `docker run`** (no Aspire, no Huddle), same cycle:
   **both runs succeed too** — run 2 stays `running`, no `/.system` error, volume dirs `10001`.

So: it is **not** basic volume-permission handling, and it is **not** Sysbox — a bare
mssql-with-reused-volume works fine inside a Sysbox sandbox. What fails is the **Aspire/DCP
restart path** re-creating the SqlServer resource over an existing data volume. The harness's
shutdown was deliberately dirty (`pkill -f AppHost`), which is itself a realistic developer
action (stop the debugger, run again) and may be what leaves the resource in a state where SQL
Server resolves its system directory to `/`.

**This is very likely the reported bug** — "SqlServer wouldn't properly launch due to
perms/healthcheck, so the dependent apps wouldn't start" — and the important consequence is that
**no backing-layer change fixes it**, because it reproduces identically outside Huddle's control
surface. It needs to be chased in the Aspire layer, not the isolation layer.

**Next steps for S6 (½ day):**
1. Run the same A→B cycle in **DinD** and **classic** mode. Expect: identical failure. That
   confirms it is mode-independent and takes it off the backing-layer critical path.
2. Repeat B with a **clean** AppHost shutdown (Ctrl-C equivalent / `dotnet run` SIGINT, let DCP
   tear resources down) to see whether the dirty kill is the trigger.
3. If the dirty kill is the trigger, the product fix is on Huddle's side after all — a documented
   `docker rm` of orphaned Aspire resources (or a portal action), not an isolation change.
4. Characterise case C (`WithDataBindMount`) separately: that one *does* cross Sysbox's ID-mapped
   mount boundary, so it is the case where the runtime genuinely could matter.
