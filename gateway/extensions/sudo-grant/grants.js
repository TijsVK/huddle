'use strict';

// Grant lifecycle: time-boxed passwordless sudo for the devcontainer's work user.
//
// Unlike the docker-grant (checked passively per request) sudo is STATEFUL inside
// the container: the sudoers drop-in stays until something removes it. So every
// grant arms a revoke timer, and gateway restarts reconcile what the DB says
// against what the containers actually have.
//
// Built as a factory so the whole lifecycle is testable with a fake docker layer.

const SUDOERS_FILE = '/etc/sudoers.d/99-huddle-sudo-grant';
// setTimeout delays above ~24.8 days overflow a 32-bit int; clamp and re-arm.
const MAX_DELAY_MS = 2_000_000_000;
const DEFAULT_SUDO_USER = 'vscode';
const DEFAULT_MAX_MINUTES = 120;
const HARD_MAX_MINUTES = 480;

const CONTAINER_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
const USER_RE = /^[a-z_][a-z0-9_-]*$/;

// Env vars sudo would otherwise drop (env_reset), leaving `sudo apt-get` without
// the Huddle proxy or CA — i.e. no network at all from a root shell.
const ENV_KEEP =
  'http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY ' +
  'NODE_EXTRA_CA_CERTS SSL_CERT_FILE REQUESTS_CA_BUNDLE';

function grantScript(user) {
  // The temp file lives in /etc/sudoers.d with a leading dot: sudo ignores any
  // filename containing a period, so a half-written file is never parsed. It is
  // validated with visudo before the atomic move — a broken drop-in would break
  // sudo for the whole container.
  return `set -e
export DEBIAN_FRONTEND=noninteractive
id ${user} >/dev/null 2>&1 || { echo "user ${user} does not exist" >&2; exit 3; }
command -v sudo >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y --no-install-recommends sudo; }
mkdir -p /etc/sudoers.d
TMP=/etc/sudoers.d/.99-huddle-sudo-grant.tmp
{
  printf 'Defaults:%s env_keep += "%s"\\n' '${user}' '${ENV_KEEP}'
  printf '%s ALL=(ALL) NOPASSWD:ALL\\n' '${user}'
} > "$TMP"
chmod 440 "$TMP"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$TMP" >/dev/null 2>&1 || { rm -f "$TMP"; echo "sudoers validation failed" >&2; exit 4; }
fi
mv "$TMP" ${SUDOERS_FILE}`;
}

function revokeScript() {
  // Nothing else to unwind: the grant never touches group membership, so the
  // single drop-in is the whole footprint.
  return `rm -f ${SUDOERS_FILE} 2>/dev/null || true`;
}

function createGrantManager({ db, log, emitChanged, docker, getSetting }) {
  const timers = new Map();

  db.exec(`CREATE TABLE IF NOT EXISTS ext_sudo_grants (
    container TEXT PRIMARY KEY,
    until     INTEGER NOT NULL,
    user      TEXT NOT NULL DEFAULT 'vscode',
    granted   INTEGER NOT NULL
  )`);

  const q = {
    get: db.prepare('SELECT container, until, user FROM ext_sudo_grants WHERE container = ?'),
    all: db.prepare('SELECT container, until, user FROM ext_sudo_grants ORDER BY container'),
    put: db.prepare(
      'INSERT INTO ext_sudo_grants (container, until, user, granted) VALUES (?, ?, ?, ?) ' +
        'ON CONFLICT(container) DO UPDATE SET until = excluded.until, user = excluded.user',
    ),
    del: db.prepare('DELETE FROM ext_sudo_grants WHERE container = ?'),
  };

  // ── Settings ───────────────────────────────────────────────────────────────

  function sudoUser() {
    const raw = (getSetting('sudoUser') || '').trim();
    if (!raw) return DEFAULT_SUDO_USER;
    if (!USER_RE.test(raw)) {
      log(`ignoring invalid sudoUser setting '${raw}', falling back to ${DEFAULT_SUDO_USER}`);
      return DEFAULT_SUDO_USER;
    }
    return raw;
  }

  function maxMinutes() {
    const n = parseInt((getSetting('maxMinutes') || '').trim(), 10);
    if (!Number.isFinite(n) || n < 1) return DEFAULT_MAX_MINUTES;
    return Math.min(n, HARD_MAX_MINUTES);
  }

  // ── Timers ─────────────────────────────────────────────────────────────────

  function clearTimer(container) {
    const t = timers.get(container);
    if (t) {
      clearTimeout(t);
      timers.delete(container);
    }
  }

  function scheduleRevoke(container, until) {
    clearTimer(container);
    const delay = until * 1000 - Date.now();
    if (delay <= 0) {
      void expireIfDue(container);
      return;
    }
    const t = setTimeout(() => void expireIfDue(container), Math.min(delay, MAX_DELAY_MS));
    if (typeof t.unref === 'function') t.unref();
    timers.set(container, t);
  }

  // Timer-driven expiry re-reads the DB: the grant may have been EXTENDED after
  // this timer was armed, so only revoke when it is genuinely past due.
  async function expireIfDue(container) {
    const row = q.get.get(container);
    if (!row) {
      clearTimer(container);
      return;
    }
    if (row.until * 1000 - Date.now() > 0) {
      scheduleRevoke(container, row.until);
      return;
    }
    await doRevoke(container);
  }

  async function doRevoke(container) {
    clearTimer(container);
    const row = q.get.get(container);
    q.del.run(container);
    emitChanged();
    try {
      const res = await docker.execAsRoot(container, revokeScript());
      if (res.exitCode !== 0) {
        log(`revoke in ${container} exited ${res.exitCode}: ${res.output}`);
      } else {
        log(`sudo revoked for ${row ? row.user : DEFAULT_SUDO_USER} in ${container}`);
      }
    } catch (err) {
      // Container may already be gone — then there is nothing left to revoke.
      log(`revoke in ${container} skipped: ${err.message}`);
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  async function assertGrantable(container) {
    if (!CONTAINER_RE.test(container)) throw badRequest('invalid container name');
    // The extension runs in-process with raw socket access, so it must police its
    // own scope: only running Huddle devcontainers, never arbitrary containers.
    const known = await docker.listDevcontainers();
    const match = known.find((c) => c.name === container);
    if (!match) throw notFound(`'${container}' is not a Huddle devcontainer`);
    if (!match.running) throw badRequest(`'${container}' is not running`);
    return match;
  }

  async function grant(container, minutes) {
    const max = maxMinutes();
    const m = Number(minutes);
    if (!Number.isInteger(m) || m < 1 || m > max) {
      throw badRequest(`minutes must be an integer between 1 and ${max}`);
    }
    await assertGrantable(container);

    const user = sudoUser();
    const res = await docker.execAsRoot(container, grantScript(user));
    if (res.exitCode !== 0) {
      throw new Error(`granting sudo in ${container} failed (exit ${res.exitCode}): ${res.output}`);
    }

    const until = Math.floor(Date.now() / 1000) + m * 60;
    q.put.run(container, until, user, Math.floor(Date.now() / 1000));
    scheduleRevoke(container, until);
    emitChanged();
    log(`sudo granted to ${user} in ${container} for ${m}m (until ${new Date(until * 1000).toISOString()})`);
    return { container, user, until };
  }

  async function revoke(container) {
    if (!CONTAINER_RE.test(container)) throw badRequest('invalid container name');
    await doRevoke(container);
  }

  function status(container) {
    const row = q.get.get(container);
    if (!row) return { container, active: false, until: null, user: sudoUser() };
    return { container, active: true, until: row.until, user: row.user };
  }

  function listAll() {
    const now = Math.floor(Date.now() / 1000);
    return q.all
      .all()
      .filter((r) => r.until > now)
      .map((r) => ({ container: r.container, until: r.until, user: r.user }));
  }

  // On gateway restart: drop expired grants, re-apply still-active ones (the
  // container may have been rebuilt in the meantime) and re-arm their timers.
  async function reconcile() {
    const now = Math.floor(Date.now() / 1000);
    for (const row of q.all.all()) {
      if (row.until <= now) {
        await doRevoke(row.container);
        continue;
      }
      try {
        await assertGrantable(row.container);
        const res = await docker.execAsRoot(row.container, grantScript(row.user));
        if (res.exitCode !== 0) log(`re-apply in ${row.container} exited ${res.exitCode}: ${res.output}`);
      } catch (err) {
        log(`re-apply in ${row.container} skipped: ${err.message}`);
      }
      scheduleRevoke(row.container, row.until);
    }
  }

  // Called on uninstall/reload: stop the timers AND revoke, so no container is
  // left with a grant nobody is tracking any more.
  async function dispose() {
    const containers = Array.from(timers.keys());
    for (const c of containers) clearTimer(c);
    for (const c of containers) await doRevoke(c);
  }

  return { grant, revoke, status, listAll, reconcile, dispose, maxMinutes, sudoUser };
}

function badRequest(message) {
  const err = new Error(message);
  err.statusCode = 400;
  return err;
}

function notFound(message) {
  const err = new Error(message);
  err.statusCode = 404;
  return err;
}

module.exports = { createGrantManager, grantScript, revokeScript, SUDOERS_FILE, HARD_MAX_MINUTES };
