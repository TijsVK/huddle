import { describe, it, expect, beforeAll, beforeEach } from 'vitest';

// Tests for the DinD-branch grant additions: the PERMANENT_UNTIL sentinel + its
// isPermanentUntil check, and the root_grants db helpers (root for the default
// vscode-user, replacing the noot dance). db-level, same sqlite probe as
// grants.test.ts. The exec/scheduler side (root-grant.ts) pulls in docker.ts and
// is covered by the tool-compat harness, not here.
let sqliteAvailable = true;
try {
  const mod = await import('better-sqlite3');
  new mod.default(':memory:').close();
} catch {
  sqliteAvailable = false;
}

let dbMod: typeof import('../src/db');
const CID = 'devcontainer-root';

describe.skipIf(!sqliteAvailable)('permanent + root grants', () => {
  beforeAll(async () => {
    dbMod = await import('../src/db');
    dbMod.initDb();
  });
  beforeEach(() => { dbMod.db.exec('DELETE FROM root_grants; DELETE FROM docker_grants;'); });

  describe('PERMANENT_UNTIL sentinel', () => {
    it('is far enough in the future to always read as active', () => {
      const now = Math.floor(Date.now() / 1000);
      expect(dbMod.PERMANENT_UNTIL).toBeGreaterThan(now + 60 * 60 * 24 * 365 * 50);
    });
    it('isPermanentUntil recognises the sentinel and rejects normal expiries', () => {
      expect(dbMod.isPermanentUntil(dbMod.PERMANENT_UNTIL)).toBe(true);
      expect(dbMod.isPermanentUntil(Math.floor(Date.now() / 1000) + 3600)).toBe(false);
    });
    it('a permanent docker grant is always active via the existing until check', () => {
      dbMod.setGrant(CID, dbMod.PERMANENT_UNTIL);
      const g = dbMod.getGrant(CID)!;
      expect(g.until > Math.floor(Date.now() / 1000)).toBe(true);
      expect(dbMod.isPermanentUntil(g.until)).toBe(true);
    });
  });

  describe('root_grants helpers', () => {
    it('sets, reads and deletes a time-boxed root grant', () => {
      const until = Math.floor(Date.now() / 1000) + 1800;
      dbMod.setRootGrant(CID, until);
      expect(dbMod.getRootGrant(CID)).toEqual({ until });
      dbMod.deleteRootGrant(CID);
      expect(dbMod.getRootGrant(CID)).toBeUndefined();
    });
    it('upserts (extends) instead of duplicating', () => {
      dbMod.setRootGrant(CID, 1000);
      dbMod.setRootGrant(CID, 2000);
      expect(dbMod.getRootGrant(CID)).toEqual({ until: 2000 });
      const n = (dbMod.db.prepare('SELECT COUNT(*) n FROM root_grants WHERE container_id=?').get(CID) as { n: number }).n;
      expect(n).toBe(1);
    });
    it('supports a permanent root grant via the sentinel', () => {
      dbMod.setRootGrant(CID, dbMod.PERMANENT_UNTIL);
      const g = dbMod.getRootGrant(CID)!;
      expect(dbMod.isPermanentUntil(g.until)).toBe(true);
    });
    it('getAllRootGrants returns a map keyed by container', () => {
      dbMod.setRootGrant('a', 1000);
      dbMod.setRootGrant('b', dbMod.PERMANENT_UNTIL);
      const all = dbMod.getAllRootGrants();
      expect(all.a).toEqual({ until: 1000 });
      expect(all.b).toEqual({ until: dbMod.PERMANENT_UNTIL });
    });
    it('root and docker grants are independent tables', () => {
      dbMod.setGrant(CID, 1111);
      dbMod.setRootGrant(CID, 2222);
      expect(dbMod.getGrant(CID)).toEqual({ until: 1111 });
      expect(dbMod.getRootGrant(CID)).toEqual({ until: 2222 });
    });
  });
});
