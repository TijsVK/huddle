// Validation of the DinD adversarial-review findings against the CLASSIC
// socket-proxy shipped on origin/main (this branch's baseline).
//
// The findings were discovered on experiment/dind against the authz-plugin
// topology. main has no DinD and no authz plugin — it ships the classic
// per-container socket-proxy (net.Server MITM in front of the host dockerd),
// which is DEFAULT-DENY on routes (classifyRequest allowlist) but DEFAULT-ALLOW
// on HostConfig fields once a route is permitted.
//
// This suite proves, against main's REAL exported functions, which findings
// carry over to the classic proxy and which are structurally absent.
//
// Run: npx vitest run test/security-validation.test.ts
import { describe, it, expect } from 'vitest';
import { validateHostConfig, validateVolumeCreate } from '../src/socket-proxy';
import { classifyRequest } from '../src/docker-actions';

describe('CARRIES OVER — findings that defeat main’s classic proxy', () => {
  // Finding #1 (case-insensitive keys). dockerd’s Go JSON decoder matches struct
  // fields case-insensitively; the proxy compares exact-case. Two variants:
  it('#1a nested lowercase key bypasses every hard-deny (Privileged→null)', () => {
    // dockerd reads {"privileged":true} as HostConfig.Privileged=true and builds
    // a PRIVILEGED container; the proxy’s `hostConfig.Privileged === true` misses
    // it. Allowlist sweep is LOG-ONLY unless HUDDLE_HOSTCONFIG_ENFORCE=1, so this
    // returns null (ALLOW) in the shipped default config.
    expect(validateHostConfig({ privileged: true })).toBeNull();
    expect(validateHostConfig({ capadd: ['SYS_ADMIN'] })).toBeNull();
    expect(validateHostConfig({ devices: [{ PathOnHost: '/dev/sda' }] })).toBeNull();
    expect(validateHostConfig({ binds: ['/:/host'] })).toBeNull();
    // Contrast: the exact-case forms ARE denied — proving the gap is case only.
    expect(validateHostConfig({ Privileged: true })).toMatch(/Privileged/);
    expect(validateHostConfig({ Binds: ['/:/host'] })).toMatch(/host-path bind/);
  });

  it('#1b top-level lowercase HostConfig key is never inspected', () => {
    // The routing layer calls validateHostConfig(body.HostConfig). A body of
    // {"hostconfig":{"Privileged":true}} has body.HostConfig === undefined, so
    // the guard runs on undefined and passes.
    const body: any = JSON.parse('{"Image":"x","hostconfig":{"Privileged":true}}');
    expect(body.HostConfig).toBeUndefined();
    expect(validateHostConfig(body.HostConfig)).toBeNull();
  });

  // Finding #7 (privileged exec-create). The exec route is authorized by
  // ownership only; the exec BODY is never buffered/inspected, so
  // {"Privileged":true} on an owned container reconfigures its device cgroup to
  // allow-all → mknod host block devices → raw-disk read. There is no
  // validateExecEscape on main.
  it('#7 exec route is allowed with no body inspection', async () => {
    expect(classifyRequest('POST', '/containers/abc123/exec')).toBe('container.exec');
    const mod: any = await import('../src/socket-proxy');
    expect(mod.validateExecEscape).toBeUndefined(); // no exec guard exists
  });

  // Review round #2 (MaskedPaths/ReadonlyPaths unmask). Both keys are on the
  // ALLOWED list and accepted with ANY value, including [] (unmask everything).
  // No superset check. Lower severity on the classic proxy (containers are not
  // privileged), but /proc/sysrq-trigger is a host-global write.
  it('#2 MaskedPaths/ReadonlyPaths unmask is accepted', () => {
    expect(validateHostConfig({ MaskedPaths: [] })).toBeNull();
    expect(validateHostConfig({ ReadonlyPaths: [] })).toBeNull();
  });
});

describe('DOES NOT CARRY OVER — blocked by main’s default-deny or already fixed', () => {
  it('swarm services are route-denied (finding #3-#2 N/A)', () => {
    expect(classifyRequest('POST', '/services/create')).toBeNull();
    expect(classifyRequest('POST', '/services/abc/update')).toBeNull();
    expect(classifyRequest('POST', '/swarm/init')).toBeNull();
  });

  it('managed-plugin install is route-denied (finding #4-#1 N/A)', () => {
    expect(classifyRequest('POST', '/plugins/create')).toBeNull();
    expect(classifyRequest('POST', '/plugins/pull')).toBeNull();
    expect(classifyRequest('POST', '/plugins/x/enable')).toBeNull();
  });

  it('secrets/configs factories are route-denied', () => {
    expect(classifyRequest('POST', '/secrets/create')).toBeNull();
    expect(classifyRequest('POST', '/configs/create')).toBeNull();
  });

  it('volumes/create bind-in-disguise IS caught (review #3-#1 already fixed)', () => {
    expect(validateVolumeCreate({ Driver: 'local', DriverOpts: { device: '/', o: 'bind', type: 'none' } }))
      .toMatch(/bind-backed/);
    expect(validateVolumeCreate({ Driver: 'local', DriverOpts: { o: 'bind' } })).toMatch(/bind-backed/);
  });

  it('the //path and %2f route dodge causes DENY, not bypass (default-deny)', () => {
    // The version-strip regex is /^\/v[\d.]+/ and there is no slash-collapse or
    // percent-decode; a crafted path simply fails the allowlist → deny403.
    expect(classifyRequest('POST', '//containers/create')).toBeNull();
    expect(classifyRequest('POST', '/containers%2fcreate')).toBeNull();
  });
});
