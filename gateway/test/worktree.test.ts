import { describe, it, expect, beforeAll } from 'vitest';
import { execFileSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { ensureWorktree } from '../src/worktree';

// Migration / update force-recreates a devcontainer, which re-runs ensureWorktree
// for the same workspace. This must be IDEMPOTENT: the same worktree is reused so
// a user's cloned repo + committed AND uncommitted changes in the workspace
// survive the recreate (they live on host disk, not in the container).
let gitAvailable = true;
try { execFileSync('git', ['--version'], { stdio: 'ignore' }); } catch { gitAvailable = false; }

function git(cwd: string, ...args: string[]): void {
  execFileSync('git', args, { cwd, stdio: 'ignore' });
}

describe.skipIf(!gitAvailable)('ensureWorktree idempotency (workspace survives recreate)', () => {
  let repo: string;

  beforeAll(() => {
    repo = fs.mkdtempSync(path.join(os.tmpdir(), 'wt-repo-'));
    git(repo, 'init', '-b', 'main');
    git(repo, 'config', 'user.email', 't@e.st');
    git(repo, 'config', 'user.name', 'Test');
    fs.writeFileSync(path.join(repo, 'README.md'), 'hello\n');
    git(repo, 'add', '.');
    git(repo, 'commit', '-m', 'init');
  });

  it('reuses the same worktree and preserves committed + uncommitted changes on recreate', async () => {
    const first = await ensureWorktree(repo, 'dc1');
    expect(fs.existsSync(first)).toBe(true);
    expect(first).not.toBe(repo); // a real worktree was created

    // Simulate the user working in the devcontainer: a committed change and an
    // uncommitted (dirty + untracked) change in the workspace.
    fs.appendFileSync(path.join(first, 'README.md'), 'edited-in-devcontainer\n');
    fs.writeFileSync(path.join(first, 'untracked.txt'), 'work-in-progress\n');
    git(first, 'config', 'user.email', 't@e.st');
    git(first, 'config', 'user.name', 'Test');
    fs.writeFileSync(path.join(first, 'committed.txt'), 'committed-work\n');
    git(first, 'add', 'committed.txt');
    git(first, 'commit', '-m', 'work');

    // Migration / update recreates the devcontainer -> ensureWorktree runs again.
    const second = await ensureWorktree(repo, 'dc1');

    expect(second).toBe(first); // same worktree, not a fresh one
    // Uncommitted edit + untracked file survive.
    expect(fs.readFileSync(path.join(second, 'README.md'), 'utf8')).toContain('edited-in-devcontainer');
    expect(fs.existsSync(path.join(second, 'untracked.txt'))).toBe(true);
    // Committed work survives.
    expect(fs.existsSync(path.join(second, 'committed.txt'))).toBe(true);
  });

  it('a different devcontainer name gets its own isolated worktree', async () => {
    const a = await ensureWorktree(repo, 'dcA');
    const b = await ensureWorktree(repo, 'dcB');
    expect(a).not.toBe(b);
  });
});
