import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import net from 'net';
import fs from 'fs';
import os from 'os';
import path from 'path';

// socket-proxy (where validateHostConfigEscape lives) imports db transitively.
// Mock it so this pure-socket test needs no native binding.
vi.mock('../src/db', () => ({ logAudit: () => 0, updateAuditResponse: () => {} }));

const { createDindFilter, removeDindFilter } = await import('../src/dind-filter');
const { validateDindEscape } = await import('../src/socket-proxy');

describe('validateDindEscape', () => {
  it('allows a benign workspace bind', () => {
    expect(validateDindEscape({ Binds: ['/home/vscode/proj:/proj'] })).toBeNull();
  });
  it('allows VolumesFrom (contained to the sidecar)', () => {
    expect(validateDindEscape({ VolumesFrom: ['other'] })).toBeNull();
  });
  it('denies Privileged', () => {
    expect(validateDindEscape({ Privileged: true })).toMatch(/Privileged/);
  });
  it('denies Devices and host namespaces', () => {
    expect(validateDindEscape({ Devices: [{ PathOnHost: '/dev/sda' }] })).toMatch(/Devices/);
    expect(validateDindEscape({ PidMode: 'host' })).toMatch(/PidMode/);
  });
  it.each([
    '/var/run/dind',
    '/var/run/dind/inner.sock',
    '/run/dind',
    '/var/run',
    '/run',
    '/var',
    '/',
    '/var/run/../run/dind',      // .. evasion
    '/var/run/dind/',            // trailing slash
  ])('denies a bind reaching the socket dir via %s', (src) => {
    expect(validateDindEscape({ Binds: [`${src}:/x`] })).toMatch(/socket path/);
  });
  it('denies a socket-dir bind expressed as a Mount', () => {
    expect(validateDindEscape({ Mounts: [{ Type: 'bind', Source: '/var/run/dind', Target: '/x' }] })).toMatch(/socket path/);
  });
  it('allows a benign bind expressed as a Mount', () => {
    expect(validateDindEscape({ Mounts: [{ Type: 'bind', Source: '/home/vscode/x', Target: '/x' }] })).toBeNull();
  });
});

// A tiny fake "private daemon": records every byte it receives and answers each
// request. It emulates docker's HIJACK for /exec/<id>/start — it waits until the
// client has half-closed its write side (stdin-EOF), THEN streams output. That
// ordering is exactly what breaks a proxy that doesn't preserve half-open.
function fakeUpstream(sockPath: string): Promise<{ server: net.Server; received: () => string }> {
  let received = Buffer.alloc(0);
  return new Promise((resolve) => {
    const server = net.createServer({ allowHalfOpen: true }, (sock) => {
      let handled = false;
      sock.on('data', (chunk) => {
        received = Buffer.concat([received, chunk]);
        const text = received.toString();
        if (handled) return;
        if (/POST \/(v[\d.]+\/)?containers\/create/.test(text) && text.includes('\r\n\r\n')) {
          handled = true;
          const body = JSON.stringify({ Id: 'newcontainer' });
          sock.write(`HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\n\r\n${body}`);
          sock.end();
        } else if (/POST \/(v[\d.]+\/)?exec\/[^/]+\/start/.test(text)) {
          handled = true;
          // Emulate hijack: only emit output AFTER the client half-closes.
          sock.on('end', () => {
            sock.write('HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\nEXEC-OUTPUT-OK');
            sock.end();
          });
        } else if (text.includes('\r\n\r\n')) {
          handled = true;
          sock.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi');
          sock.end();
        }
      });
    });
    server.listen(sockPath, () => resolve({ server, received: () => received.toString() }));
  });
}

function talk(sockPath: string, payload: string, halfCloseAfterWrite = false): Promise<string> {
  return new Promise((resolve, reject) => {
    const c = net.createConnection({ path: sockPath, allowHalfOpen: true });
    let out = Buffer.alloc(0);
    c.on('connect', () => {
      c.write(payload);
      if (halfCloseAfterWrite) c.end(); // FIN, but keep reading (half-open)
    });
    c.on('data', (d) => { out = Buffer.concat([out, d]); });
    c.on('end', () => resolve(out.toString()));
    c.on('close', () => resolve(out.toString()));
    c.on('error', reject);
    setTimeout(() => { c.destroy(); resolve(out.toString()); }, 3000);
  });
}

describe('dind-filter', () => {
  let dir: string;
  let up: { server: net.Server; received: () => string };
  const NAME = 'test-dc';
  let upSock: string;
  let filterSock: string;

  beforeEach(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dindfilter-'));
    upSock = path.join(dir, 'inner.sock');
    filterSock = path.join(dir, 'docker.sock');
    up = await fakeUpstream(upSock);
    await createDindFilter(NAME, filterSock, upSock);
  });

  afterEach(() => {
    removeDindFilter(NAME);
    up.server.close();
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
  });

  it('forwards a benign container create to the daemon', async () => {
    const body = JSON.stringify({ Image: 'alpine', HostConfig: { Memory: 1000000 } });
    const resp = await talk(filterSock, `POST /v1.45/containers/create HTTP/1.1\r\nHost: d\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\n\r\n${body}`);
    expect(resp).toContain('201 Created');
    expect(up.received()).toContain('/containers/create');
    expect(up.received()).toContain('"Memory"');
  });

  it('denies a --privileged create with 403 and never forwards it', async () => {
    const body = JSON.stringify({ Image: 'alpine', HostConfig: { Privileged: true } });
    const resp = await talk(filterSock, `POST /v1.45/containers/create HTTP/1.1\r\nHost: d\r\nContent-Length: ${body.length}\r\n\r\n${body}`);
    expect(resp).toContain('403 Forbidden');
    expect(resp).toContain('blocked by Huddle');
    expect(up.received()).not.toContain('/containers/create');
  });

  // In DinD an ordinary host-path bind resolves against the disposable sidecar
  // fs (not the real host) and is REQUIRED for compose/testcontainers — it must
  // be forwarded, unlike the classic socket-proxy which blocks all host binds.
  it('forwards a benign host-path bind (compose/testcontainers workspace mount)', async () => {
    const body = JSON.stringify({ Image: 'alpine', HostConfig: { Binds: ['/home/vscode/proj/data:/data'] } });
    const resp = await talk(filterSock, `POST /v1.45/containers/create HTTP/1.1\r\nHost: d\r\nContent-Length: ${body.length}\r\n\r\n${body}`);
    expect(resp).toContain('201 Created');
    expect(up.received()).toContain('/containers/create');
  });

  it('denies a bind reaching the private-daemon socket dir (filter bypass)', async () => {
    const body = JSON.stringify({ Image: 'alpine', HostConfig: { Binds: ['/var/run/dind:/d'] } });
    const resp = await talk(filterSock, `POST /v1.45/containers/create HTTP/1.1\r\nHost: d\r\nContent-Length: ${body.length}\r\n\r\n${body}`);
    expect(resp).toContain('403 Forbidden');
    expect(up.received()).not.toContain('/containers/create');
  });

  // The regression the manual Aspire probe surfaced: exec output was silently
  // dropped because the hijacked stream's half-close tore down the whole socket.
  it('delivers hijacked exec output after the client half-closes (stdin-EOF)', async () => {
    const body = JSON.stringify({ Detach: false, Tty: false });
    const resp = await talk(filterSock, `POST /v1.45/exec/abc123/start HTTP/1.1\r\nHost: d\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\n\r\n${body}`, true);
    expect(resp).toContain('EXEC-OUTPUT-OK');
  });

  // Keep-alive pipelining must not smuggle a privileged create past inspection:
  // a benign request followed on the same connection by a privileged create is
  // still inspected and denied.
  it('inspects a privileged create pipelined after a benign request', async () => {
    const create = JSON.stringify({ Image: 'alpine', HostConfig: { Privileged: true } });
    const payload =
      `GET /v1.45/_ping HTTP/1.1\r\nHost: d\r\n\r\n` +
      `POST /v1.45/containers/create HTTP/1.1\r\nHost: d\r\nContent-Length: ${create.length}\r\n\r\n${create}`;
    const resp = await talk(filterSock, payload);
    expect(resp).toContain('403 Forbidden');
    expect(up.received()).not.toContain('/containers/create');
  });
});
