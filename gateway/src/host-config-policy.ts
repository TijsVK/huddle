// Host-escape HostConfig policy — PURE (no db/native imports) so it can be reused
// by the classic socket-proxy AND the DinD authorization plugin (and a standalone
// authz runner in the dind-compat harness) without dragging in better-sqlite3.
// See socket-proxy.ts (classic proxy) and dind-authz.ts (DinD authz plugin).

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
  // Clearing/shrinking the default masks exposes host kernel state regardless of
  // namespaces: /proc/kcore (host kernel memory), /proc/sysrq-trigger (host DoS/
  // panic), etc. (review finding #3). The Docker CLI normally sends these arrays
  // POPULATED with the defaults, so we only refuse when the critical entries are
  // MISSING — i.e. an explicit unmask ([] or a shrunk list).
  if (Array.isArray(hostConfig.MaskedPaths) && !hostConfig.MaskedPaths.includes('/proc/kcore'))
    return 'MaskedPaths must keep the default masks (/proc/kcore)';
  if (Array.isArray(hostConfig.ReadonlyPaths) && !hostConfig.ReadonlyPaths.includes('/proc/sysrq-trigger'))
    return 'ReadonlyPaths must keep the default read-only paths (/proc/sysrq-trigger)';
  if (Array.isArray(hostConfig.SecurityOpt)) {
    for (const opt of hostConfig.SecurityOpt) {
      if (typeof opt !== 'string') continue;
      const norm = opt.toLowerCase().replace(/\s+/g, '');
      // Refuse ANY non-default seccomp/apparmor (finding #8): an inline permissive
      // profile (`seccomp=<allow-all-json>`) evades a literal "unconfined" match.
      // The only accepted forms keep the daemon default.
      const key = norm.split('=')[0];
      if ((key === 'seccomp' || key === 'apparmor')) {
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

// Exec-create (POST /containers/{id}/exec) carries Privileged / capability fields
// at the TOP LEVEL (not under HostConfig). `docker exec --privileged` grants the
// full capability set to the exec process inside a nested container — inspect it
// too (review finding #7). Returns a denial reason or null.
export function validateExecEscape(execBody: any): string | null {
  if (!execBody || typeof execBody !== 'object') return null;
  if (execBody.Privileged === true) return 'privileged exec not permitted';
  if (Array.isArray(execBody.CapAdd) && execBody.CapAdd.length > 0) return 'exec CapAdd not permitted';
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

// DinD escape policy, enforced by the dockerd authorization plugin (dind-authz.ts).
// Because dockerd enforces this on EVERY request to its single socket, there is no
// unfiltered daemon path to reach — so binds need NO special handling: binding the
// docker socket (Testcontainers Ryuk / docker-outside-of-docker) just yields another
// authz-guarded client, and binding a host path resolves against the disposable
// sidecar fs. Only the device/kernel/namespace/masked-path vectors matter here.
// Returns a denial reason or null.
export function validateDindEscape(hostConfig: any): string | null {
  if (!hostConfig || typeof hostConfig !== 'object') return null;
  return validateKernelEscape(hostConfig);
}
