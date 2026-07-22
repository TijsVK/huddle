# DinD adversarial-review findings — validated against `origin/main`

**Baseline:** `origin/main` @ `3894332` (infosupport/huddle). No DinD, no authz plugin.
main ships the **classic per-container socket-proxy** (`gateway/src/socket-proxy.ts`,
a `net.Server` MITM in front of the host dockerd).

**Source of findings:** the adversarial review rounds on `experiment/dind`, which
hardened the DinD **authz plugin** (`dind-authz.ts` + `host-config-policy.ts`).

**Method:** each finding was mapped onto main's classic proxy and asserted against
main's *real* exported functions in `gateway/test/security-validation.test.ts`
(9 tests, all green). No live exploit was run — see *Residual* below.

## Why some findings apply and others don't

The two designs have opposite defaults:

| | Route policy | HostConfig-field policy |
|---|---|---|
| Classic proxy (main) | **default-DENY** — `classifyRequest` allowlist; unknown route → 403 | **default-ALLOW** — only listed keys hard-denied; allowlist sweep is log-only |
| Authz plugin (dind) | **default-ALLOW** — dockerd needs full API for Aspire/compose | explicit denies per vector |

So the plugin needed explicit swarm/plugin-install denies *because* it forwards
everything by default; the classic proxy blocks those routes for free. The
overlap is the **HostConfig-field** layer, which both share — and that is where
main is exposed.

## Findings that CARRY OVER (real on main)

### 1. Case-insensitive HostConfig key bypass — **HIGH / host escape**
dockerd's Go JSON decoder matches struct fields case-insensitively; the proxy
compares exact-case. Two independent variants, both verified at code level:

- **Nested key:** `validateHostConfig({ privileged: true })` → `null` (allow).
  dockerd reads `Privileged=true` and builds a **privileged** container.
  Same for `capadd`, `devices`, `binds` (`/:/host`).
- **Top-level key:** the router calls `validateHostConfig(body.HostConfig)`; a body
  of `{"hostconfig":{"Privileged":true}}` has `body.HostConfig === undefined`, so
  the guard inspects `undefined` and passes.

The unrecognized lowercase key *is* caught by the allowlist sweep — but that sweep
is **log-only** unless `HUDDLE_HOSTCONFIG_ENFORCE=1`, which is not the shipped
default. Result: privileged container → host root.

Notably, main **already defends `validateVolumeCreate` against case tricks**
(`host-config.test.ts:123`) but never applied the same normalization to the
container-create HostConfig path. Fix on dind was `lowerKeysDeep` (finding #1).

### 2. Privileged exec-create — **HIGH / host escape**
The exec route (`POST /containers/{id}/exec`) is authorized by ownership only; the
exec **body is never buffered or inspected**. `docker exec --privileged` on an
owned (non-privileged) container reconfigures its device cgroup to allow-all →
`mknod` a host block device → raw-disk read. No `validateExecEscape` exists on
main. Fix on dind was `validateExecEscape` (finding #7).

### 3. MaskedPaths / ReadonlyPaths unmask — **MEDIUM (LOW without privileged)**
Both keys are on the allow-list and accepted with **any** value, including `[]`
(unmask everything). No superset check. Lower impact on the classic proxy since
containers aren't privileged, but `/proc/sysrq-trigger` is a host-global write.
Fix on dind: require the critical masks as a superset (review round #2).

## Findings that DO NOT carry over

| Finding | Status on main | Why |
|---|---|---|
| Swarm service = mount factory (#3-2) | **N/A** | `/services/*`, `/swarm/*` route-denied |
| Managed-plugin install (#4-1) | **N/A** | `/plugins/*` route-denied |
| secrets/configs factories | **N/A** | route-denied |
| volumes/create bind-in-disguise (#3-1) | **already fixed** | `validateVolumeCreate` denies device/`o=bind`/`type=none`, case-insensitive |
| `//path` / `%2f` route dodge (#6) | **not a privesc** | default-deny turns a crafted path into a 403, not a bypass |
| Symlink-bind through shared mount (#3) | **N/A** | classic proxy denies *all* host-path binds; no shared workspace mount |
| Read-only plugin-socket swap (#1/#2 dind) | **N/A** | no authz plugin socket exists |

## Residual / next step

The proof is code-level (unit assertions + documented dockerd case-insensitivity,
which is the exact behavior the dind branch cites when adding `lowerKeysDeep`).
A full end-to-end PoC — running gateway + devcontainer + host dockerd, sending
`{"hostconfig":{"privileged":true}}` over the proxy socket and reading a host
device from the spawned container — was **not** executed here (needs the full
runtime). Findings #1 and #2 warrant that live confirmation before disclosure.

A ready-to-run PoC for finding #1 lives at `docs/security/poc-host-escape.sh`: run
it inside a Huddle devcontainer against your own instance. It creates a
`privileged` + host-PID + host-rootfs container via the lowercase-`hostconfig`
bypass, `nsenter`s into host init, pops a calculator, and drops a proof file on the
host. Harmless payload, self-cleaning; exits 2 if the proxy refuses (patched).

## Recommended fixes (port from `experiment/dind`)

1. Deep-lowercase HostConfig keys before validation (`lowerKeysDeep`) **and** read
   `HostConfig` case-insensitively in the router — closes #1.
2. Buffer + validate the exec body (`validateExecEscape`) — closes #2.
3. Require the critical `/proc` masks as a superset on `MaskedPaths`/`ReadonlyPaths`
   — closes #3.
4. Consider flipping `HUDDLE_HOSTCONFIG_ENFORCE` to on by default (defence in depth;
   would have caught #1 as a side effect).
