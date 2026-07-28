import { describe, it, expect, beforeEach, vi } from 'vitest';
import { EventEmitter } from 'events';
import { createRequire } from 'module';
import Database from 'better-sqlite3';

// The extension is plain CommonJS (it is loaded by the gateway's extension
// loader with `await import`, not compiled with the gateway sources).
const require_ = createRequire(import.meta.url);
const EXT_PATH = '../extensions/sudo-grant/index.js';
const GRANTS_PATH = '../extensions/sudo-grant/grants.js';

type Handler = (req: any, reply: any) => Promise<any>;

interface FakeDocker {
  execAsRoot: ReturnType<typeof vi.fn>;
  listDevcontainers: ReturnType<typeof vi.fn>;
  calls: Array<{ container: string; script: string }>;
}

function makeReply() {
  const reply: any = {
    statusCode: 200,
    payload: undefined,
    code(c: number) { reply.statusCode = c; return reply; },
    send(p: unknown) { reply.payload = p; return p; },
  };
  return reply;
}

function setup(opts: { containers?: any[]; exitCode?: number; settings?: Record<string, string> } = {}) {
  const routes = new Map<string, Handler>();
  const db = new Database(':memory:');
  const settings = new Map(Object.entries(opts.settings ?? {}));
  const calls: Array<{ container: string; script: string }> = [];

  const docker: FakeDocker = {
    calls,
    execAsRoot: vi.fn(async (container: string, script: string) => {
      calls.push({ container, script });
      return { exitCode: opts.exitCode ?? 0, output: '' };
    }),
    listDevcontainers: vi.fn(async () =>
      opts.containers ?? [{ id: 'abc', name: 'dc-demo', running: true, status: 'Up 2 hours', presentableName: 'demo', ide: 'vscode' }],
    ),
  };

  // Patch the docker layer before index.js resolves it. CommonJS gives us a live
  // module object, so replacing the functions is enough — index.js deliberately
  // calls `dockerIo.execAsRoot(...)` through the namespace for this reason.
  const dockerIo = require_('../extensions/sudo-grant/docker-io.js');
  dockerIo.execAsRoot = docker.execAsRoot;
  dockerIo.listDevcontainers = docker.listDevcontainers;

  const events = new EventEmitter();
  const changed = vi.fn();
  events.on('changed', changed);

  const ctx = {
    app: {
      get: (p: string, h: Handler) => routes.set(`GET:${p}`, h),
      post: (p: string, h: Handler) => routes.set(`POST:${p}`, h),
      put: (p: string, h: Handler) => routes.set(`PUT:${p}`, h),
      delete: (p: string, h: Handler) => routes.set(`DELETE:${p}`, h),
      inject: vi.fn(),
    },
    events,
    db,
    log: () => {},
    getSetting: (k: string) => settings.get(k) ?? null,
    setSetting: (k: string, v: string) => void settings.set(k, v),
    runInContainer: vi.fn(),
    fetch: vi.fn(),
  };

  return { ctx, routes, db, docker, changed, settings };
}

async function callRoute(routes: Map<string, Handler>, key: string, req: any = {}) {
  const handler = routes.get(key);
  if (!handler) throw new Error(`route ${key} not registered`);
  const reply = makeReply();
  const result = await handler({ params: {}, body: undefined, ...req }, reply);
  return { result, reply };
}

function freshExt() {
  // Drop the module cache so each test gets its own grant manager (and its own
  // timer map) instead of inheriting the previous test's state.
  delete require_.cache[require_.resolve(EXT_PATH)];
  return require_(EXT_PATH);
}

describe('sudo-grant extension', () => {
  beforeEach(() => {
    vi.useRealTimers();
  });

  it('registers its routes under its own /api/ext namespace', async () => {
    const { ctx, routes } = setup();
    await freshExt().register(ctx);
    expect([...routes.keys()].sort()).toEqual([
      'DELETE:/api/ext/sudo-grant/grants/:container',
      'GET:/api/ext/sudo-grant/containers',
      'GET:/api/ext/sudo-grant/grants',
      'GET:/api/ext/sudo-grant/grants/:container',
      'PUT:/api/ext/sudo-grant/grants/:container',
    ]);
  });

  it('grants sudo: writes a validated drop-in and stores the deadline', async () => {
    const { ctx, routes, db, docker, changed } = setup();
    await freshExt().register(ctx);

    const before = Math.floor(Date.now() / 1000);
    const { result } = await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' },
      body: { minutes: 15 },
    });

    expect(result).toMatchObject({ container: 'dc-demo', user: 'vscode' });
    expect((result as any).until).toBeGreaterThanOrEqual(before + 15 * 60);

    const script = docker.calls[0].script;
    expect(script).toContain("printf '%s ALL=(ALL) NOPASSWD:ALL\\n' 'vscode'");
    expect(script).toContain('visudo -cf "$TMP"');
    expect(script).toContain('mv "$TMP" /etc/sudoers.d/99-huddle-sudo-grant');
    expect(script).toContain('id vscode >/dev/null 2>&1');
    expect(script).toContain('env_keep');

    const row = db.prepare('SELECT container, user FROM ext_sudo_grants').get() as any;
    expect(row).toMatchObject({ container: 'dc-demo', user: 'vscode' });
    expect(changed).toHaveBeenCalled();
  });

  it('extends an active grant instead of stacking a second one', async () => {
    const { ctx, routes, db } = setup();
    await freshExt().register(ctx);
    const first = await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 15 },
    });
    const second = await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 60 },
    });
    expect((second.result as any).until).toBeGreaterThan((first.result as any).until);
    expect(db.prepare('SELECT COUNT(*) AS n FROM ext_sudo_grants').get()).toEqual({ n: 1 });
  });

  it('rejects bad minute values', async () => {
    const { ctx, routes } = setup();
    await freshExt().register(ctx);
    for (const minutes of [0, -5, 1.5, 999, 'abc', undefined]) {
      const { reply } = await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
        params: { container: 'dc-demo' }, body: { minutes },
      });
      expect(reply.statusCode, `minutes=${String(minutes)}`).toBe(400);
    }
  });

  it('refuses containers that are not running Huddle devcontainers', async () => {
    const stopped = setup({ containers: [{ name: 'dc-demo', running: false, status: 'Exited (0)' }] });
    await freshExt().register(stopped.ctx);
    const notRunning = await callRoute(stopped.routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 15 },
    });
    expect(notRunning.reply.statusCode).toBe(400);

    const unknown = await callRoute(stopped.routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'some-other-container' }, body: { minutes: 15 },
    });
    expect(unknown.reply.statusCode).toBe(404);

    const bogus = await callRoute(stopped.routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: '../../etc' }, body: { minutes: 15 },
    });
    expect(bogus.reply.statusCode).toBe(400);
    expect(stopped.docker.execAsRoot).not.toHaveBeenCalled();
  });

  it('does not record a grant when applying it in the container fails', async () => {
    const { ctx, routes, db } = setup({ exitCode: 4 });
    await freshExt().register(ctx);
    const { reply } = await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 15 },
    });
    expect(reply.statusCode).toBe(500);
    expect(db.prepare('SELECT COUNT(*) AS n FROM ext_sudo_grants').get()).toEqual({ n: 0 });
  });

  it('revokes: removes the drop-in and the row', async () => {
    const { ctx, routes, db, docker } = setup();
    await freshExt().register(ctx);
    await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 15 },
    });
    await callRoute(routes, 'DELETE:/api/ext/sudo-grant/grants/:container', { params: { container: 'dc-demo' } });

    expect(docker.calls.at(-1)!.script).toContain('rm -f /etc/sudoers.d/99-huddle-sudo-grant');
    expect(db.prepare('SELECT COUNT(*) AS n FROM ext_sudo_grants').get()).toEqual({ n: 0 });
  });

  it('reports status and the active-grant map', async () => {
    const { ctx, routes } = setup();
    await freshExt().register(ctx);
    const idle = await callRoute(routes, 'GET:/api/ext/sudo-grant/grants/:container', { params: { container: 'dc-demo' } });
    expect(idle.result).toMatchObject({ active: false, until: null, user: 'vscode' });

    await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 30 },
    });
    const active = await callRoute(routes, 'GET:/api/ext/sudo-grant/grants/:container', { params: { container: 'dc-demo' } });
    expect(active.result).toMatchObject({ active: true, user: 'vscode' });

    const map = await callRoute(routes, 'GET:/api/ext/sudo-grant/grants');
    expect(Object.keys(map.result as object)).toEqual(['dc-demo']);
  });

  it('lists containers with their grant state for the UI', async () => {
    const { ctx, routes } = setup();
    await freshExt().register(ctx);
    await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 15 },
    });
    const { result } = await callRoute(routes, 'GET:/api/ext/sudo-grant/containers');
    expect(result).toMatchObject({ sudoUser: 'vscode', maxMinutes: 120 });
    expect((result as any).containers[0]).toMatchObject({ name: 'dc-demo', running: true, ide: 'vscode' });
    expect((result as any).containers[0].until).toBeGreaterThan(Math.floor(Date.now() / 1000));
  });

  it('honours the sudoUser / maxMinutes settings and clamps them', async () => {
    const custom = setup({ settings: { sudoUser: 'dev', maxMinutes: '9999' } });
    await freshExt().register(custom.ctx);
    const listed = await callRoute(custom.routes, 'GET:/api/ext/sudo-grant/containers');
    expect(listed.result).toMatchObject({ sudoUser: 'dev', maxMinutes: 480 });
    await callRoute(custom.routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 200 },
    });
    expect(custom.docker.calls[0].script).toContain("'dev'");

    const bad = setup({ settings: { sudoUser: 'root; rm -rf /' } });
    await freshExt().register(bad.ctx);
    const fallback = await callRoute(bad.routes, 'GET:/api/ext/sudo-grant/containers');
    expect(fallback.result).toMatchObject({ sudoUser: 'vscode' });
  });

  it('auto-revokes when the grant expires', async () => {
    vi.useFakeTimers();
    const { ctx, routes, db, docker } = setup();
    await freshExt().register(ctx);
    await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 1 },
    });
    expect(db.prepare('SELECT COUNT(*) AS n FROM ext_sudo_grants').get()).toEqual({ n: 1 });

    await vi.advanceTimersByTimeAsync(61_000);

    expect(docker.calls.at(-1)!.script).toContain('rm -f /etc/sudoers.d/99-huddle-sudo-grant');
    expect(db.prepare('SELECT COUNT(*) AS n FROM ext_sudo_grants').get()).toEqual({ n: 0 });
  });

  it('keeps the grant when the timer fires on a grant that was extended', async () => {
    vi.useFakeTimers();
    const { ctx, routes, db } = setup();
    await freshExt().register(ctx);
    await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 1 },
    });
    await vi.advanceTimersByTimeAsync(30_000);
    await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 60 },
    });
    await vi.advanceTimersByTimeAsync(40_000); // past the ORIGINAL deadline

    expect(db.prepare('SELECT COUNT(*) AS n FROM ext_sudo_grants').get()).toEqual({ n: 1 });
  });

  it('reconciles on startup: expired revoked, active re-applied', async () => {
    const { ctx, db, docker } = setup();
    const now = Math.floor(Date.now() / 1000);
    db.exec(`CREATE TABLE IF NOT EXISTS ext_sudo_grants (
      container TEXT PRIMARY KEY, until INTEGER NOT NULL,
      user TEXT NOT NULL DEFAULT 'vscode', granted INTEGER NOT NULL)`);
    db.prepare('INSERT INTO ext_sudo_grants (container, until, user, granted) VALUES (?, ?, ?, ?)')
      .run('dc-demo', now + 600, 'vscode', now - 600);
    db.prepare('INSERT INTO ext_sudo_grants (container, until, user, granted) VALUES (?, ?, ?, ?)')
      .run('dc-stale', now - 10, 'vscode', now - 3600);

    await freshExt().register(ctx);
    // reconcile() is intentionally not awaited by register() so the gateway keeps
    // booting; give it a turn to finish.
    await vi.waitFor(() => expect(docker.execAsRoot).toHaveBeenCalledTimes(2));

    const scripts = new Map(docker.calls.map((c) => [c.container, c.script]));
    expect(scripts.get('dc-demo')).toContain('mv "$TMP" /etc/sudoers.d/99-huddle-sudo-grant');
    expect(scripts.get('dc-stale')).toContain('rm -f /etc/sudoers.d/99-huddle-sudo-grant');
    expect(db.prepare('SELECT container FROM ext_sudo_grants').all()).toEqual([{ container: 'dc-demo' }]);
  });

  it('unregister revokes every active grant', async () => {
    const { ctx, routes, db } = setup();
    const ext = freshExt();
    await ext.register(ctx);
    await callRoute(routes, 'PUT:/api/ext/sudo-grant/grants/:container', {
      params: { container: 'dc-demo' }, body: { minutes: 30 },
    });
    await ext.unregister();
    expect(db.prepare('SELECT COUNT(*) AS n FROM ext_sudo_grants').get()).toEqual({ n: 0 });
  });
});

describe('sudo-grant script shape', () => {
  it('never leaves a parsable half-written sudoers file', () => {
    const { grantScript } = require_(GRANTS_PATH);
    const script = grantScript('vscode');
    // sudo ignores filenames containing a period, so the temp name is inert until
    // it is validated and atomically moved into place.
    expect(script).toContain('TMP=/etc/sudoers.d/.99-huddle-sudo-grant.tmp');
    expect(script.indexOf('visudo -cf "$TMP"')).toBeLessThan(script.indexOf('mv "$TMP"'));
    expect(script).toContain('chmod 440 "$TMP"');
  });

  it('does not touch group membership (nothing to unwind on revoke)', () => {
    const { grantScript, revokeScript } = require_(GRANTS_PATH);
    expect(grantScript('vscode')).not.toContain('usermod');
    expect(revokeScript()).not.toContain('gpasswd');
  });
});
