# Huddle Docker-in-Docker (Design N)

Experimental architecture on branch `experiment/dind`. Gives each devcontainer a
**real, private Docker daemon** instead of a filtered window onto the shared host
daemon, so demanding dev tools work out of the box — while egress stays firewalled
and the host and peer devcontainers stay unreachable.

Enabled with `HUDDLE_DIND=1`. Off by default; the classic socket-proxy model is
unchanged and all its tests still pass.

## Why

The per-container **socket-proxy** (`socket-proxy.ts`) mediates every Docker API
call a devcontainer makes and enforces a label/ownership policy on the shared
host daemon. That policy is what breaks real tools:

| Symptom (real issues) | Cause in the socket-proxy |
|-----------------------|---------------------------|
| Aspire DCP: `proxy tunnel request … 403` (#12) | loopback calls forced through the egress proxy |
| Aspire: `docker 'CopyFile' … non-zero` (#12) | archive/`docker cp` into a spawned container filtered |
| Aspire: container stuck `Unknown`, `InspectContainers … not owned by this devcontainer` (#61) | inspect filtered to `huddle.parent`-labelled containers |
| Port publish hangs | host-port needs portal approval (`__PORT_CHECK__`) |
| `--privileged`, host binds, `--volumes-from`, `--device` | hard-denied by `validateHostConfig` |

A private daemon has none of these filters, so the tools behave exactly as they
do on a laptop.

## Topology

```
Host Docker daemon
  ├─ huddle gateway              orchestrator + egress firewall + portal
  ├─ dc-net-<name>  (--internal) no direct route to the internet
  ├─ devcontainer-<name>         IDE/dev env; DOCKER_HOST → private daemon
  └─ dind-<name>                 docker:dind, --privileged,
       │                         --network container:devcontainer-<name>
       └─ nested containers      Aspire / compose / Testcontainers / k8s nodes …
```

- **Private daemon per devcontainer.** `dind-<name>` runs a real `dockerd`. The
  devcontainer talks to it over a unix socket in a shared volume
  (`DOCKER_HOST=unix:///var/run/dind/docker.sock`). No socket-proxy in the path.
- **Shared network namespace** (`--network container:<devcontainer>`). The sidecar
  shares the devcontainer's netns, so:
  - nested **published ports land on the devcontainer's own `localhost`/`[::1]`**
    — what Aspire's DCP expects (`http://[::1]:<port>`), and what makes
    Testcontainers/compose port mapping "just work";
  - nested traffic inherits the devcontainer's **firewall iptables** (DNAT→proxy,
    DROP) and the `--internal` network, so egress can't bypass Huddle.
- **Isolation.** The private daemon cannot see the host daemon or any peer
  devcontainer. The only privileged unit is the sidecar, and it has **no host
  mounts** — an escape lands in that one disposable daemon, not the host.

## Egress firewall

Unchanged model, extended to nested containers:
- The devcontainer's own processes use `http(s)_proxy=http://huddle:80` (name
  resolvable in its netns) + the Huddle MITM CA, plus the iptables DNAT/DROP.
- **Nested containers** get proxy env injected client-side via the devcontainer's
  docker config (`~/.docker/config.json` `proxies.default`) for root + vscode.
  Because a nested container is on the private daemon's own network and cannot
  resolve the name `huddle`, the config uses the **resolved huddle IP**
  (regenerated on restart in `refreshContainerIptables`).
- Result: no direct internet without the proxy (verified), and `dockerd`'s own
  image pulls go through `HTTPS_PROXY` too.
- Huddle MITMs outbound HTTPS with its own CA, so the sidecar `dockerd` installs
  the **Huddle CA into its trust store before starting** — otherwise every image
  pull fails with `x509: certificate signed by unknown authority`.
- The private daemon's unix socket is chmod'd **0666** once created so the
  non-root devcontainer user (vscode) can reach it (it lives in a volume shared
  only by the devcontainer + its sidecar).

Limitation: a container created via the **raw Docker API** (e.g. Aspire DCP)
does not get the CLI's `proxies.default` injection; it is still confined by the
`--internal` network, but if it needs outbound it must be configured with the
proxy explicitly. CLI/compose/most tools are covered automatically.

## Workspace / file sharing

The private daemon has its **own filesystem**. So a tool inside the devcontainer
that bind-mounts a path into a nested container only sees real files if that path
also exists in the daemon. Huddle mounts the **workspace + folder-mappings into
the sidecar at the same target paths**, so workspace binds (the common case —
compose build contexts, Dev Containers CLI, Testcontainers copy) resolve to the
real files. Bind mounts of *arbitrary* devcontainer-local paths outside that set
are the one known limitation (they mount empty), documented and asserted in the
harness (`tools/workspace.sh`).

## Grants (this branch)

- **Permanent docker grant** — the portal grant can be permanent (sentinel
  `until = 4102444800`) instead of 1–120 min. Largely moot under DinD (the private
  daemon is unrestricted) but kept usable for the classic model.
- **Root for the default user** — a portal grant gives the default `vscode` user
  passwordless sudo (a `/etc/sudoers.d` drop-in), time-limited or permanent,
  replacing the old separate `noot` user + generated password. Because sudo is
  stateful in the container, expiry triggers an **active revoke** (`root-grant.ts`
  timer); startup restores/expires grants.

## Migration (classic ↔ DinD)

Switching `HUDDLE_DIND` changes a devcontainer's docker plumbing (socket-proxy ↔
private daemon), which only takes effect on **recreate**. Migration is designed to
feel seamless — same capabilities and UX afterwards:

- **New devcontainers** pick up the current mode automatically.
- **Existing devcontainers**: `huddle migrate <name>` (or `huddle migrate` for all,
  or `POST /api/docker/containers/:name/migrate`) recreates them in the current
  mode from their own labels. It's a forced recreate, but:
  - the **workspace** is preserved (git worktree / bind mount is reused);
  - **portal state** — grants, firewall rules, action policies, approved ports —
    is keyed by container name in SQLite and survives untouched;
  - only ephemeral in-container state is lost.
- On startup the gateway logs a **non-destructive hint** listing devcontainers
  still in the other mode (`needsMigration()`), so nothing changes until the
  operator chooses to migrate.

E2E-verified: a classic devcontainer + a firewall rule → switch the gateway to
DinD → the rule persists → `migrate` → the devcontainer runs on a private daemon
with docker fully working (`gateway/test/dind-compat/e2e-migrate.sh`).

## Code map

| File | Role |
|------|------|
| `gateway/src/dind.ts` | sidecar lifecycle: create/ensure/remove, image pull, shared socket + workspace mounts |
| `gateway/src/docker.ts` | `HUDDLE_DIND` switch (DOCKER_HOST, mounts, config-script symlink), sidecar start, nested-proxy client config, root-grant exec helpers |
| `gateway/src/root-grant.ts` | root-grant apply/revoke + expiry scheduler + startup restore |
| `gateway/src/index.ts` | restore sidecars + root grants on boot |
| `cli/src/init.ts` | `HUDDLE_DIND` passthrough + DinD engine image pre-pull |
| `gateway/test/dind-compat/` | Docker-driven tool-compatibility harness (see RESULTS.md) |

## Enabling

```bash
HUDDLE_DIND=1 huddle init      # gateway runs every devcontainer with a private daemon
# optional: HUDDLE_DIND_IMAGE=docker:28-dind
```

## Trade-offs

- One extra privileged sidecar container + a storage volume per devcontainer
  (disk for the nested images).
- Nested images are pulled per-devcontainer (no sharing with the host daemon).
- Raw-API nested containers aren't auto-proxied (see Egress).
- Arbitrary non-workspace bind mounts into nested containers don't see host files
  (see Workspace).
- The portal's per-action Docker policy is bypassed for devcontainer docker use
  (the daemon is private/unrestricted); the UI stays for the classic model.
