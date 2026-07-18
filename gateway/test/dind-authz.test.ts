import { describe, it, expect, vi } from 'vitest';

// dind-authz imports host-config-policy (pure) — no db. No mock needed, but keep
// one in case a transitive import appears.
vi.mock('../src/db', () => ({ logAudit: () => 0, updateAuditResponse: () => {} }));

const { authorize } = await import('../src/dind-authz');
const { validateDindEscape, validateExecEscape } = await import('../src/host-config-policy');

// Build a Docker AuthZReq the way dockerd sends it: method, URI, base64 body.
function req(method: string, uri: string, body?: unknown) {
  return {
    RequestMethod: method,
    RequestUri: uri,
    RequestBody: body === undefined ? undefined : Buffer.from(JSON.stringify(body)).toString('base64'),
  };
}

describe('dind-authz authorize()', () => {
  it('allows a benign container create', () => {
    expect(authorize(req('POST', '/v1.45/containers/create', { Image: 'alpine', HostConfig: { Memory: 1e6 } }))).toBeNull();
  });
  it('denies a --privileged create', () => {
    expect(authorize(req('POST', '/v1.45/containers/create', { HostConfig: { Privileged: true } }))).toMatch(/Privileged/);
  });
  it('denies a --device create', () => {
    expect(authorize(req('POST', '/v1.45/containers/create', { HostConfig: { Devices: [{ PathOnHost: '/dev/sda' }] } }))).toMatch(/Devices/);
  });
  it('ALLOWS host-path binds (safe under authz — resolves to the sidecar fs)', () => {
    expect(authorize(req('POST', '/v1.45/containers/create', { HostConfig: { Binds: ['/etc:/h', '/var/run/dind/docker.sock:/s'] } }))).toBeNull();
  });
  it('fails CLOSED when a create carries no inspectable body', () => {
    expect(authorize(req('POST', '/v1.45/containers/create'))).toMatch(/not available/);
  });

  // Path-normalization: a create routed via // or an encoded path must still be
  // inspected (finding #6).
  it.each([
    '//containers/create',
    '/v1.45//containers/create',
    '/v1.45/containers%2fcreate',
  ])('inspects a create reached via %s', (uri) => {
    expect(authorize(req('POST', uri, { HostConfig: { Privileged: true } }))).toMatch(/Privileged/);
  });

  it('denies a privileged exec-create (finding #7)', () => {
    expect(authorize(req('POST', '/v1.45/containers/abc123/exec', { Privileged: true, Cmd: ['sh'] }))).toMatch(/privileged exec/);
  });
  it('allows an ordinary exec-create', () => {
    expect(authorize(req('POST', '/v1.45/containers/abc123/exec', { Cmd: ['ls'], AttachStdout: true }))).toBeNull();
  });

  it('allows non-create/exec requests (version, list, build, grpc)', () => {
    for (const u of ['/v1.45/version', '/v1.45/containers/json', '/v1.45/build', '/v1.45/grpc', '/v1.45/containers/abc/start']) {
      expect(authorize(req('POST', u))).toBeNull();
    }
  });
  it('activates as an authz plugin (handshake shape)', () => {
    // handshake is handled at the HTTP layer; authorize() only sees AuthZReq.
    expect(authorize(req('GET', '/v1.45/_ping'))).toBeNull();
  });
});

describe('validateDindEscape / validateExecEscape (findings #3/#7/#8)', () => {
  it('denies MaskedPaths / ReadonlyPaths overrides (#3)', () => {
    expect(validateDindEscape({ MaskedPaths: [] })).toMatch(/MaskedPaths/);
    expect(validateDindEscape({ ReadonlyPaths: [] })).toMatch(/ReadonlyPaths/);
  });
  it('denies a custom (non-default) seccomp/apparmor profile (#8)', () => {
    expect(validateDindEscape({ SecurityOpt: ['seccomp={"defaultAction":"SCMP_ACT_ALLOW"}'] })).toMatch(/SecurityOpt/);
    expect(validateDindEscape({ SecurityOpt: ['seccomp=unconfined'] })).toMatch(/SecurityOpt/);
    expect(validateDindEscape({ SecurityOpt: ['apparmor=unconfined'] })).toMatch(/SecurityOpt/);
  });
  it('allows the daemon-default seccomp/apparmor', () => {
    expect(validateDindEscape({ SecurityOpt: ['seccomp=default'] })).toBeNull();
    expect(validateDindEscape({ SecurityOpt: ['apparmor=docker-default'] })).toBeNull();
  });
  it('allows a plain create and ordinary binds', () => {
    expect(validateDindEscape({ Memory: 1e6, Binds: ['/home/x:/x'] })).toBeNull();
  });
  it('exec escape: privileged + CapAdd denied, plain allowed (#7)', () => {
    expect(validateExecEscape({ Privileged: true })).toMatch(/privileged/);
    expect(validateExecEscape({ CapAdd: ['SYS_ADMIN'] })).toMatch(/CapAdd/);
    expect(validateExecEscape({ Cmd: ['ls'] })).toBeNull();
  });
});
