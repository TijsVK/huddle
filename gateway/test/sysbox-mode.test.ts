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

// ── Kapotte uid-shift na een harde reboot ───────────────────────────────────
// Sysbox shift de rootfs soms met een ID-mapped mount; die is weg na een reboot
// van de host, en een container die tijdens het afbreken DRAAIDE komt daarna
// terug met de hele image op nobody (65534). Herstarten repareert dat niet.
describe('devcontainerNeedsRecreate', () => {
  it('slaat containers over die het niet kunnen zijn', async () => {
    const m = await loadDocker({ HUDDLE_SYSBOX: '1' });
    // Van ná de laatste boot: die heeft zijn shift nog, niet meten.
    const future = Math.floor(Date.now() / 1000) + 3600;
    expect(await m.devcontainerNeedsRecreate('x', future, true)).toBe(false);
    // Gestopt: breekt pas (of juist niet) bij de volgende start, en exec kan er
    // niet in. Geen exec-poging, dus ook geen false positive als docker weg is.
    expect(await m.devcontainerNeedsRecreate('x', 1, false)).toBe(false);
  });

  it('staat uit in klassieke modus', async () => {
    const m = await loadDocker({ HUDDLE_SYSBOX: undefined });
    expect(await m.devcontainerNeedsRecreate('x', 1, true)).toBe(false);
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
