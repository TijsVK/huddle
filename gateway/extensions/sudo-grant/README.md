# Sudo Grant (Huddle extension)

Time-boxed passwordless sudo for a devcontainer's work user, driven from the portal.
15 / 30 / 60 minutes, revoke on demand, automatic revoke on expiry, reconciled after a
gateway restart.

This is the additive extension form of the change proposed in PR #83. It **adds** a page,
an API namespace and a table. It does not patch core, the SPA bundle, or the existing
`noot` credentials flow — those keep working exactly as before, they are just no longer
the only way to get root.

## What it does

- **Grant** — execs as root in the target container and writes a single sudoers drop-in
  `/etc/sudoers.d/99-huddle-sudo-grant`:
  - `Defaults:<user> env_keep += "http_proxy https_proxy … NODE_EXTRA_CA_CERTS …"` — without
    this, `sudo apt-get` loses the Huddle proxy and CA and has no network at all.
  - `<user> ALL=(ALL) NOPASSWD:ALL`
  - The file is written to a dot-prefixed temp name (sudo ignores filenames containing a
    period), `chmod 440`, validated with `visudo -cf`, then atomically moved into place. A
    broken drop-in would break `sudo` for the whole container, so it is never left parsable
    while half-written.
  - Group membership is deliberately **not** touched — the explicit user rule is enough, so
    revoke has nothing to unwind.
- **Revoke** — removes that one file. Explicit (portal) or timer-driven (expiry).
- **Extend** — granting again on an active container moves the deadline; the revoke timer
  re-reads the DB when it fires, so an extend that lands late never gets clobbered.
- **Reconcile on boot** — expired grants are revoked, still-active grants are re-applied
  (the container may have been rebuilt) and their timers re-armed.

## Scope guard

The extension runs in-process in the gateway with raw `/var/run/docker.sock` access, so it
polices its own scope: it will only exec into **running containers carrying the
`com.intellij.devcontainer.id` label** — the same filter core's `listDevcontainers()` uses.
Container names are validated against `^[A-Za-z0-9][A-Za-z0-9_.-]*$`, minutes must be an
integer within the configured maximum, and a non-zero exit from the in-container script
means **no grant row is written** (no phantom "active" state).

## Install

**Bundled (recommended).** The directory lives in `gateway/extensions/`, which the image
copies to `EXT_DIR=/app/extensions`; `loadAllExtensions()` picks it up on boot. Nothing to
upload, nothing to hash-pin.

**Zip upload.** Zip the *contents* of this directory (`manifest.json` at the zip root) and
upload it on the portal's Extensions page. In that case also pin it:

```
HUDDLE_EXTENSION_SHA256_ALLOWLIST=<sha256 of the zip>
```

Without that variable the loader's integrity check is **log-only** and any uploaded bundle
runs as root in-process. Pin it.

## Settings (portal → Extensions → Sudo Grant → Settings)

| Key | Default | Notes |
|-----|---------|-------|
| `sudoUser` | `vscode` | Must match `^[a-z_][a-z0-9_-]*$`; anything else falls back to `vscode`. `vscode` is the work user in the vscode/rider/intellij variants alike. |
| `maxMinutes` | `120` | Hard-capped at 480. The UI only offers presets that fit under it. |

## API

All routes sit behind the gateway's operator auth (the global `onRequest` hook covers
`/api/*`, extension routes included).

| Method | Path | Body / result |
|--------|------|---------------|
| `GET` | `/api/ext/sudo-grant/containers` | devcontainers + grant state + `sudoUser`/`maxMinutes` (one call paints the page) |
| `GET` | `/api/ext/sudo-grant/grants` | `{ "<container>": { until, user } }` for active grants |
| `GET` | `/api/ext/sudo-grant/grants/:container` | `{ container, active, until, user }` |
| `PUT` | `/api/ext/sudo-grant/grants/:container` | `{ "minutes": 15 }` — grant or extend |
| `DELETE` | `/api/ext/sudo-grant/grants/:container` | revoke now |

State lives in its own table `ext_sudo_grants` (core tables untouched).

## Security model — what time-boxing is and is not

The timer bounds **when** root is available. It is **not** a containment control. Anything
running in the container during an active window can persist root past expiry — a SUID
binary, a second `/etc/sudoers.d/*` drop-in, a uid-0 account — or side-step the sudo audit
log. Revoke removes this extension's drop-in; it cannot claw back root already held.

It also **lowers the bar for an in-container agent to self-escalate**: while a grant is
active, any process running as the work user (including an autonomous coding agent) has
root with no credential. Under the `noot` flow, root was gated by a password a human had to
share into the container deliberately.

What does not change is host isolation: the container stays unprivileged and only reaches
the filtered docker-proxy socket, so container-root is not host-root. Containment stays at
the container + proxy boundary; the grant is a per-window trust decision the operator makes.

On a **shared** gateway this is a deployment-wide decision, not a personal preference —
every operator with portal access can press the button for any devcontainer.

## Known limitations

- **Own page, not a tab.** Extension UI can only mount as a full page
  (`/extensions/view/sudo-grant`); `container-detail`'s tab strip has no extension slot.
  Adding one upstream (`manifest.contributes.containerTabs` + a host slot) plus a
  root-capable `ctx.runInContainer(name, cmd, { user, capture })` would let this drop the
  raw-socket layer and render as a real tab.
- **No teardown hook.** The loader never calls anything on uninstall, so `unregister()`
  (which revokes every active grant) is exported but currently unwired. Revoke your grants
  before removing the extension, or they stay in place until the file is deleted by hand.
- **No container lifecycle events.** A rebuild mid-grant is only repaired on the next
  gateway restart (core's own reconcile has the same shape).
- `noot` is untouched by design: the user is still created and its tab still renders. This
  extension is additive — retiring `noot` needs a core change.
