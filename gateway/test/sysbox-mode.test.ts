import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// docker.ts trekt db.ts binnen voor settings/grants; mocken houdt de native
// better-sqlite3-binding buiten deze test (zelfde reden als host-config.test.ts).
vi.mock('../src/db', () => ({
  getSetting: () => undefined,
  getGrant: () => null,
  isHostPortApproved: () => false,
  getFolderMappings: () => [],
  logAudit: () => {},
}));

// ── Sysbox-modus ────────────────────────────────────────────────────────────
// De modus wordt uit de omgeving gelezen bij import, dus elke case herimporteert
// de module met een eigen HUDDLE_SYSBOX.
async function loadDocker(env: Record<string, string | undefined>) {
  vi.resetModules();
  const prev = { ...process.env };
  for (const [k, v] of Object.entries(env)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await import('../src/docker');
  } finally {
    process.env = prev;
  }
}

describe('sysbox mode flag', () => {
  beforeEach(() => vi.resetModules());
  afterEach(() => vi.resetModules());

  it('is uit zonder HUDDLE_SYSBOX', async () => {
    const m = await loadDocker({ HUDDLE_SYSBOX: undefined });
    expect(m.SYSBOX_ENABLED).toBe(false);
  });

  it('gaat alleen aan bij exact "1"', async () => {
    expect((await loadDocker({ HUDDLE_SYSBOX: '1' })).SYSBOX_ENABLED).toBe(true);
    // Geen fuzzy waarheid: 'true'/'yes' zetten de modus NIET aan, zodat een typo
    // niet stilletjes de isolatie-modus van de hele gateway omzet.
    expect((await loadDocker({ HUDDLE_SYSBOX: 'true' })).SYSBOX_ENABLED).toBe(false);
    expect((await loadDocker({ HUDDLE_SYSBOX: '0' })).SYSBOX_ENABLED).toBe(false);
  });
});

describe('sysboxDockerDataVolume', () => {
  it('is per devcontainer en herleidbaar', async () => {
    const { sysboxDockerDataVolume } = await loadDocker({ HUDDLE_SYSBOX: '1' });
    expect(sysboxDockerDataVolume('proj-a')).toBe('huddle-sysbox-docker-proj-a');
    expect(sysboxDockerDataVolume('proj-a')).not.toBe(sysboxDockerDataVolume('proj-b'));
    // De naam wordt ook gebruikt om het volume bij delete op te ruimen; een
    // prefix-wijziging laat verweesde volumes achter.
    expect(sysboxDockerDataVolume('x')).toMatch(/^huddle-sysbox-docker-/);
  });
});
