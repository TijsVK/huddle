import { describe, it, expect, vi } from 'vitest';

// db is native (better-sqlite3); proxy.ts imports it transitively. Mock so this
// pure-string test doesn't need the binding.
vi.mock('../src/db', () => ({ logAudit: () => 0, updateAuditResponse: () => {} }));

const { safeRequestPath } = await import('../src/proxy');

// A devcontainer must not be able to crash the gateway with an odd request path.
// Node's http client rejects paths with chars outside !-ÿ; safeRequestPath
// percent-encodes them. The bug this guards: a decoded astral-plane char (emoji)
// matched by a non-`u` regex splits into lone surrogates and encodeURIComponent
// itself throws URIError -> unhandled rejection -> process exit.
describe('safeRequestPath', () => {
  it('encodes an astral-plane char (emoji) WITHOUT throwing', () => {
    const emoji = decodeURIComponent('%F0%9F%98%80'); // 😀 as a real surrogate pair
    expect(() => safeRequestPath('/' + emoji)).not.toThrow();
    expect(safeRequestPath('/' + emoji)).toBe('/%F0%9F%98%80');
  });
  it('encodes a lone-surrogate path without throwing', () => {
    expect(() => safeRequestPath('/\uD83D/x')).not.toThrow();
  });
  it('encodes spaces and control chars', () => {
    expect(safeRequestPath('/a b')).toBe('/a%20b');
    expect(safeRequestPath('/x\ty')).toBe('/x%09y');
  });
  it('leaves already-encoded and normal ASCII paths untouched', () => {
    expect(safeRequestPath('/api/v1/foo?q=1&r=2')).toBe('/api/v1/foo?q=1&r=2');
    expect(safeRequestPath('/%20already')).toBe('/%20already');
    expect(safeRequestPath('/a/b-c_d.e~f')).toBe('/a/b-c_d.e~f');
  });
  it('passes latin1 range through (Node accepts !-ÿ)', () => {
    expect(safeRequestPath('/café')).toBe('/café');
  });
});
