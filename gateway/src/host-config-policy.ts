// Host-escape HostConfig policy — PURE (no db/native imports) so it can be reused
// by the socket-proxy, the DinD filter, AND a standalone filter runner (the
// dind-compat harness) without dragging in better-sqlite3. See socket-proxy.ts
// (classic proxy) and dind-filter.ts (DinD host-escape filter) for callers.

// Device/kernel/namespace hard-denies: the vectors that give a container direct
// host-kernel/device access regardless of filesystem. Apply to BOTH the classic
// proxy AND the DinD filter (in DinD the sidecar is --privileged, so a
// --privileged / --device / host-namespace nested container reaches the HOST's
// block devices and kernel — finding C1). Binds/Mounts/VolumesFrom are handled
// separately because their safety differs between the two modes.
export function validateKernelEscape(hostConfig: any): string | null {
  if (hostConfig.Privileged === true) return 'Privileged containers not permitted';
  if (hostConfig.PidMode && hostConfig.PidMode !== '') return 'PidMode not permitted';
  if (hostConfig.IpcMode === 'host') return 'IpcMode=host not permitted';
  if (hostConfig.UsernsMode === 'host') return 'UsernsMode=host not permitted';
  if (hostConfig.CgroupnsMode === 'host') return 'CgroupnsMode=host not permitted';
  if (hostConfig.UTSMode === 'host') return 'UTSMode=host not permitted';
  if (hostConfig.CgroupParent) return 'CgroupParent override not permitted';
  if (Array.isArray(hostConfig.CapAdd) && hostConfig.CapAdd.length > 0) return 'CapAdd not permitted';
  if (Array.isArray(hostConfig.Devices) && hostConfig.Devices.length > 0) return 'Devices not permitted';
  if (Array.isArray(hostConfig.DeviceCgroupRules) && hostConfig.DeviceCgroupRules.length > 0) return 'DeviceCgroupRules not permitted';
  if (Array.isArray(hostConfig.DeviceRequests) && hostConfig.DeviceRequests.length > 0) return 'DeviceRequests not permitted';
  for (const k of ['BlkioDeviceReadBps', 'BlkioDeviceWriteBps', 'BlkioDeviceReadIOps', 'BlkioDeviceWriteIOps'] as const) {
    if (Array.isArray(hostConfig[k]) && hostConfig[k].length > 0) return `${k} not permitted`;
  }
  const sys = hostConfig.Sysctls;
  if (sys && typeof sys === 'object' && Object.keys(sys).length > 0) return 'Sysctls not permitted';
  if (Array.isArray(hostConfig.SecurityOpt)) {
    for (const opt of hostConfig.SecurityOpt) {
      if (typeof opt !== 'string') continue;
      const norm = opt.toLowerCase().replace(/\s+/g, '');
      if (norm === 'apparmor=unconfined' || norm === 'seccomp=unconfined' || norm === 'label=disable' ||
          norm === 'systempaths=unconfined' || norm === 'no-new-privileges=false')
        return `SecurityOpt ${opt} not permitted`;
    }
  }
  return null;
}

// Classic socket-proxy escape denies: kernel/device vectors PLUS all host-path
// binds/bind-mounts/VolumesFrom (the "host" is the real host here).
export function validateHostConfigEscape(hostConfig: any): string | null {
  if (!hostConfig || typeof hostConfig !== 'object') return null;
  const kernel = validateKernelEscape(hostConfig);
  if (kernel) return kernel;
  if (Array.isArray(hostConfig.VolumesFrom) && hostConfig.VolumesFrom.length > 0) return 'VolumesFrom not permitted';
  if (Array.isArray(hostConfig.Binds)) {
    for (const bind of hostConfig.Binds) {
      if (typeof bind !== 'string') continue;
      const src = bind.split(':')[0] ?? '';
      if (src.startsWith('/')) return `host-path bind not permitted: ${bind}`;
    }
  }
  if (Array.isArray(hostConfig.Mounts)) {
    for (const mount of hostConfig.Mounts) {
      if (!mount) continue;
      if (mount.Type === 'bind') return 'bind-type mounts not permitted';
      if (mount.Type === 'volume' && mount.VolumeOptions?.DriverConfig) return 'volume DriverConfig not permitted';
    }
  }
  return null;
}

// Normalize a POSIX path: collapse `.`/`..`/duplicate slashes, drop trailing
// slash (except root). Used to defeat `..`-based evasions of the socket-dir guard.
function normPosix(p: string): string {
  const abs = p.startsWith('/');
  const parts: string[] = [];
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') { if (parts.length) parts.pop(); continue; }
    parts.push(seg);
  }
  return (abs ? '/' : '') + parts.join('/') || (abs ? '/' : '.');
}

// The private daemon's control sockets live here (bind-mounted into the sidecar).
// A nested container that bind-mounts this dir — or any ANCESTOR of it (/, /var,
// /var/run, …) — reaches inner.sock and talks to the UNFILTERED dockerd, escaping
// the host-escape guard. `/var/run` is a symlink to `/run` on the Alpine dind
// image, so guard both roots. This is the ONE bind DinD must refuse.
const DIND_SOCKET_DIRS = ['/var/run/dind', '/run/dind'];
// Binding the FILTER socket itself (docker.sock) into a nested container is SAFE
// — that container then talks THROUGH the filter, so it still can't create a
// privileged/host-escaping container. This is exactly what Testcontainers' Ryuk
// reaper (and other docker-outside-of-docker helpers) need, so allow it. Only
// inner.sock / the dir / ancestors (which expose the UNFILTERED daemon) are
// refused.
const DIND_FILTER_SOCKS = ['/var/run/dind/docker.sock', '/run/dind/docker.sock'];
function bindReachesDindSocket(src: string): boolean {
  if (!src.startsWith('/')) return false; // named volume / relative → not a host path
  const p = normPosix(src);
  if (DIND_FILTER_SOCKS.includes(p)) return false; // filtered socket passthrough is fine
  if (p === '/') return true;
  for (const sock of DIND_SOCKET_DIRS) {
    if (p === sock) return true;                 // the socket dir itself
    if (p.startsWith(sock + '/')) return true;   // inner.sock or anything else under it
    if (sock.startsWith(p + '/')) return true;   // p is an ancestor of it
  }
  return false;
}

// DinD variant: the sidecar is a DISPOSABLE private daemon, so a bind source
// resolves against the SIDECAR filesystem, not the host — ordinary host-path
// binds (workspace files for compose/testcontainers) are safe and MUST work. The
// only bind that matters is one reaching the daemon's control socket (which would
// bypass this very filter); plus the shared kernel/device denies. Returns a
// denial reason or null.
export function validateDindEscape(hostConfig: any): string | null {
  if (!hostConfig || typeof hostConfig !== 'object') return null;
  const kernel = validateKernelEscape(hostConfig);
  if (kernel) return kernel;
  if (Array.isArray(hostConfig.Binds)) {
    for (const bind of hostConfig.Binds) {
      if (typeof bind !== 'string') continue;
      const src = bind.split(':')[0] ?? '';
      if (bindReachesDindSocket(src)) return `bind of the private daemon socket path not permitted: ${bind}`;
    }
  }
  if (Array.isArray(hostConfig.Mounts)) {
    for (const mount of hostConfig.Mounts) {
      if (!mount || mount.Type !== 'bind') continue;
      if (typeof mount.Source === 'string' && bindReachesDindSocket(mount.Source))
        return `bind of the private daemon socket path not permitted: ${mount.Source}`;
    }
  }
  return null;
}
