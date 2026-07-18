import { describe, it, expect, beforeAll, beforeEach } from 'vitest';
import os from 'os';
import path from 'path';
import fs from 'fs';

// The audit_log row-cap (pruneAuditLog) bounds an untrusted container's ability to
// grow the table unbounded within a session (disk-fill DoS). db-level test, same
// sqlite probe pattern as root-grants.test.ts.
let sqliteAvailable = true;
try {
  const mod = await import('better-sqlite3');
  new mod.default(':memory:').close();
} catch {
  sqliteAvailable = false;
}

let dbMod: typeof import('../src/db');

describe.skipIf(!sqliteAvailable)('audit_log row cap', () => {
  beforeAll(async () => {
    process.env.DB_PATH = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'auditdb-')), 'huddle.db');
    dbMod = await import('../src/db');
    dbMod.initDb();
  });
  beforeEach(() => { dbMod.db.exec('DELETE FROM audit_log;'); });

  function seed(n: number): void {
    const ins = dbMod.db.prepare(
      `INSERT INTO audit_log (container_id, domain, port, action) VALUES (?, 'd', NULL, 'test')`
    );
    const tx = dbMod.db.transaction((count: number) => {
      for (let i = 0; i < count; i++) ins.run('c' + i);
    });
    tx(n);
  }
  const count = (): number => (dbMod.db.prepare('SELECT COUNT(*) n FROM audit_log').get() as { n: number }).n;

  it('caps to the newest maxRows and drops the oldest overflow', () => {
    seed(50);
    dbMod.pruneAuditLog(10);
    expect(count()).toBe(10);
    // the survivors must be the newest 10 (highest ids)
    const min = (dbMod.db.prepare('SELECT MIN(id) m FROM audit_log').get() as { m: number }).m;
    const total = (dbMod.db.prepare('SELECT MAX(id) m FROM audit_log').get() as { m: number }).m;
    expect(total - min).toBe(9);
  });

  it('is a no-op when the table is under the cap', () => {
    seed(5);
    dbMod.pruneAuditLog(10);
    expect(count()).toBe(5);
  });

  it('is a no-op on an empty table', () => {
    dbMod.pruneAuditLog(10);
    expect(count()).toBe(0);
  });
});
