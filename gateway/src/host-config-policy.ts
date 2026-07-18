// Host-escape HostConfig policy — PURE (no db/native imports) so it can be reused
// by the classic socket-proxy AND the DinD authorization plugin (and a standalone
// authz runner in the dind-compat harness) without dragging in better-sqlite3.
// See socket-proxy.ts (classic proxy) and dind-authz.ts (DinD authz plugin).

// CRITICAL (review finding #1): dockerd decodes the request body with Go's
// encoding/json, which matches struct fields CASE-INSENSITIVELY. If we read keys
// case-sensitively, a create like {"hostconfig":{"privileged":true}} slips past
// every check (we see `undefined`) while dockerd still applies it — a total
// bypass. So we deep-lowercase every object key before inspecting, and look up all
// fields by their lowercase name. (Field VALUES that dockerd compares
// case-sensitively — e.g. IpcMode "host", Mount.Type "bind" — are matched as-is.)
export function lowerKeysDeep(v: any): any {
  if (Array.isArray(v)) return v.map(lowerKeysDeep);
  if (v && typeof v === 'object') {
    const out: any = {};
    for (const k of Object.keys(v)) out[k.toLowerCase()] = lowerKeysDeep(v[k]);
    return out;
  }
  return v;
}

// runc's default masked / read-only paths. If a create EXPLICITLY provides
// MaskedPaths/ReadonlyPaths it REPLACES these defaults, so any provided list must
// be a superset — otherwise the dropped entries are unmasked (host kernel memory
// via /proc/kcore, RAPL side-channel via powercap, host DoS via /proc/sysrq-trigger,
// …). Review findings #3/#4.
const REQUIRED_MASKED = [
  '/proc/asound', '/proc/acpi', '/proc/kcore', '/proc/keys', '/proc/latency_stats',
  '/proc/timer_list', '/proc/sched_debug', '/proc/scsi', '/sys/firmware',
  '/sys/devices/virtual/powercap',
];
const REQUIRED_READONLY = ['/proc/bus', '/proc/fs', '/proc/irq', '/proc/sys', '/proc/sysrq-trigger'];

function missingFrom(provided: unknown, required: string[]): string | null {
  if (!Array.isArray(provided)) return null; // null/omitted → daemon applies defaults, fine
  for (const p of required) if (!provided.includes(p)) return p;
  return null;
}

// Device/kernel/namespace hard-denies: the vectors that give a container direct
// host-kernel/device access regardless of filesystem. Apply to BOTH the classic
// proxy AND the DinD authz plugin (in DinD the sidecar is --privileged, so a
// --privileged / --device / host-namespace / unmasked nested container reaches the
// HOST's block devices and kernel — finding C1). Binds/Mounts/VolumesFrom are
// handled separately because their safety differs between the two modes. `hc` MUST
// already have lowercased keys (call via a lowerKeysDeep'd HostConfig).
function kernelEscapeLC(hc: any): string | null {
  if (hc.privileged === true) return 'Privileged containers not permitted';
  if (hc.pidmode && hc.pidmode !== '') return 'PidMode not permitted';
  if (hc.ipcmode === 'host') return 'IpcMode=host not permitted';
  if (hc.usernsmode === 'host') return 'UsernsMode=host not permitted';
  if (hc.cgroupnsmode === 'host') return 'CgroupnsMode=host not permitted';
  if (hc.utsmode === 'host') return 'UTSMode=host not permitted';
  if (hc.cgroupparent) return 'CgroupParent override not permitted';
  if (Array.isArray(hc.capadd) && hc.capadd.length > 0) return 'CapAdd not permitted';
  if (Array.isArray(hc.devices) && hc.devices.length > 0) return 'Devices not permitted';
  if (Array.isArray(hc.devicecgrouprules) && hc.devicecgrouprules.length > 0) return 'DeviceCgroupRules not permitted';
  if (Array.isArray(hc.devicerequests) && hc.devicerequests.length > 0) return 'DeviceRequests not permitted';
  for (const k of ['blkiodevicereadbps', 'blkiodevicewritebps', 'blkiodevicereadiops', 'blkiodevicewriteiops']) {
    if (Array.isArray(hc[k]) && hc[k].length > 0) return `${k} not permitted`;
  }
  const sys = hc.sysctls;
  if (sys && typeof sys === 'object' && Object.keys(sys).length > 0) return 'Sysctls not permitted';
  const mMask = missingFrom(hc.maskedpaths, REQUIRED_MASKED);
  if (mMask) return `MaskedPaths must keep the default masks (missing ${mMask})`;
  const mRo = missingFrom(hc.readonlypaths, REQUIRED_READONLY);
  if (mRo) return `ReadonlyPaths must keep the default read-only paths (missing ${mRo})`;
  if (Array.isArray(hc.securityopt)) {
    for (const opt of hc.securityopt) {
      if (typeof opt !== 'string') continue;
      const norm = opt.toLowerCase().replace(/\s+/g, '');
      // Refuse ANY non-default seccomp/apparmor (finding #8): an inline permissive
      // profile (`seccomp=<allow-all-json>`) evades a literal "unconfined" match.
      const key = norm.split('=')[0];
      if (key === 'seccomp' || key === 'apparmor') {
        if (norm !== 'seccomp=default' && norm !== 'apparmor=default' &&
            norm !== 'seccomp=builtin' && norm !== 'apparmor=docker-default')
          return `SecurityOpt ${opt} not permitted`;
      }
      if (norm === 'label=disable' || norm === 'systempaths=unconfined' || norm === 'no-new-privileges=false')
        return `SecurityOpt ${opt} not permitted`;
    }
  }
  return null;
}

export function validateKernelEscape(hostConfig: any): string | null {
  if (!hostConfig || typeof hostConfig !== 'object') return null;
  return kernelEscapeLC(lowerKeysDeep(hostConfig));
}

// Exec-create (POST /containers/{id}/exec) carries Privileged / capability fields
// at the TOP LEVEL (not under HostConfig). `docker exec --privileged` grants the
// full capability set to the exec process inside a nested container — inspect it
// too (review finding #7). Returns a denial reason or null.
export function validateExecEscape(execBody: any): string | null {
  if (!execBody || typeof execBody !== 'object') return null;
  const b = lowerKeysDeep(execBody);
  if (b.privileged === true) return 'privileged exec not permitted';
  if (Array.isArray(b.capadd) && b.capadd.length > 0) return 'exec CapAdd not permitted';
  return null;
}

// Classic socket-proxy escape denies: kernel/device vectors PLUS all host-path
// binds/bind-mounts/VolumesFrom (the "host" is the real host here).
export function validateHostConfigEscape(hostConfig: any): string | null {
  if (!hostConfig || typeof hostConfig !== 'object') return null;
  const hc = lowerKeysDeep(hostConfig);
  const kernel = kernelEscapeLC(hc);
  if (kernel) return kernel;
  if (Array.isArray(hc.volumesfrom) && hc.volumesfrom.length > 0) return 'VolumesFrom not permitted';
  if (Array.isArray(hc.binds)) {
    for (const bind of hc.binds) {
      if (typeof bind !== 'string') continue;
      const src = bind.split(':')[0] ?? '';
      if (src.startsWith('/')) return `host-path bind not permitted: ${bind}`;
    }
  }
  if (Array.isArray(hc.mounts)) {
    for (const mount of hc.mounts) {
      if (!mount) continue;
      if (mount.type === 'bind') return 'bind-type mounts not permitted';
      if (mount.type === 'volume' && mount.volumeoptions?.driverconfig) return 'volume DriverConfig not permitted';
    }
  }
  return null;
}

// Normalize a POSIX path: collapse `.`/`..`/duplicate slashes, drop trailing slash.
function normPath(p: string): string {
  const parts: string[] = [];
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') { if (parts.length) parts.pop(); continue; }
    parts.push(seg);
  }
  return '/' + parts.join('/');
}

// In DinD the sidecar is --privileged, so its /proc, /sys and /dev are the HOST's
// (writable) kernel interfaces — NOT a disposable fs. A nested container that
// bind-mounts them in reaches host-escape primitives: e.g. `-v /proc/sys:/x` then
// write /x/kernel/core_pattern → the kernel runs it as HOST root on the next core
// dump (verified live). So deny binds whose source is a host kernel interface (or
// `/`, which contains them). Ordinary binds (workspace, /etc, docker.sock, …) stay
// allowed. Review finding #3.
// /proc,/sys,/dev: the privileged sidecar's HOST kernel interfaces.
// /run/docker/plugins: the authz plugin socket dir (a rw re-bind could otherwise
// shadow the plugin — defense-in-depth atop the read-only mount, review #3 #3).
const SENSITIVE_BIND_ROOTS = ['/proc', '/sys', '/dev', '/run/docker/plugins'];
function bindSourceSensitive(rawSrc: string): boolean {
  if (!rawSrc.startsWith('/')) return false; // named volume / relative
  const p = normPath(rawSrc);
  if (p === '/') return true;
  for (const root of SENSITIVE_BIND_ROOTS) {
    if (p === root || p.startsWith(root + '/')) return true;
  }
  return false;
}
function dindBindEscape(hc: any): string | null {
  if (Array.isArray(hc.binds)) {
    for (const bind of hc.binds) {
      if (typeof bind !== 'string') continue;
      if (bindSourceSensitive(bind.split(':')[0] ?? '')) return `bind of a host kernel path not permitted: ${bind}`;
    }
  }
  if (Array.isArray(hc.mounts)) {
    for (const m of hc.mounts) {
      if (!m) continue;
      if (m.type === 'bind' && typeof m.source === 'string' && bindSourceSensitive(m.source))
        return `bind of a host kernel path not permitted: ${m.source}`;
      // A `local` volume with a `device`+`o=bind` option is a bind mount in
      // disguise — `--mount type=volume,volume-opt=device=/proc/sys,volume-opt=o=bind`
      // reaches the host's rw /proc/sys and dodges the Binds/Mounts.Source check
      // (verified live: wrote host core_pattern). The path lives in
      // VolumeOptions.DriverConfig.Options.device. Guard it the same way.
      const dev = m.volumeoptions?.driverconfig?.options?.device;
      if (typeof dev === 'string' && bindSourceSensitive(dev))
        return `volume device bind of a host kernel path not permitted: ${dev}`;
    }
  }
  return null;
}

// DinD escape policy, enforced by the dockerd authorization plugin (dind-authz.ts)
// on every request to the daemon's single socket. Enforces the device/kernel/
// namespace/masked-path create vectors PLUS a deny on binds whose source is a host
// kernel interface (/proc, /sys, /dev, /) — those are the HOST's, writable, through
// the privileged sidecar (finding #3). Ordinary binds (workspace, /etc, the
// authz-guarded docker.sock for Ryuk) stay allowed. Returns a reason or null.
export function validateDindEscape(hostConfig: any): string | null {
  if (!hostConfig || typeof hostConfig !== 'object') return null;
  const hc = lowerKeysDeep(hostConfig);
  return kernelEscapeLC(hc) ?? dindBindEscape(hc);
}

// `POST /volumes/create` is a SECOND door to the bind-in-disguise escape (review
// #3 finding #1): a `local` volume created with `{"Driver":"local","DriverOpts":
// {"type":"none","o":"bind","device":"/proc/sys"}}` performs the bind at MOUNT
// time, so a later container-create that references it by NAME carries no
// sensitive path for the create-time guard to see. Reject the dangerous device at
// volume-create time. Returns a reason or null.
export function validateVolumeCreate(body: any): string | null {
  if (!body || typeof body !== 'object') return null;
  const b = lowerKeysDeep(body);
  const dev = b.driveropts?.device;
  if (typeof dev === 'string' && bindSourceSensitive(dev))
    return `volume device bind of a host kernel path not permitted: ${dev}`;
  return null;
}
