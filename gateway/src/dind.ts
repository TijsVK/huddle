// ── Docker-in-Docker sidecar (experiment: broad dev-tool compatibility) ──────
//
// Model N (zie docs/dind/PROGRESS.md): elke devcontainer krijgt zijn EIGEN echte
// Docker-daemon via een `dind-<naam>` sidecar die de NETWERK-namespace van de
// devcontainer deelt (`--network container:<devcontainer>`). De devcontainer
// praat met die private daemon via een gedeelde socket-volume; er is geen
// filterende socket-proxy meer in het pad.
//
// Waarom dit tools als .NET Aspire repareert (issues #12/#61):
//   - Aspire's DCP inspecteert/maakt containers en netwerken ongefilterd — een
//     echte daemon kent geen "container not owned by this devcontainer".
//   - Gepubliceerde poorten landen op de LOOPBACK van de devcontainer
//     (localhost / [::1]) doordat de daemon de netns van de devcontainer deelt —
//     precies wat DCP verwacht (het adresseert targets als http://[::1]:<port>).
//   - `docker CopyFile`/archive, port-publish, health-check-inspects: allemaal
//     rechtstreeks op de private daemon, dus geen 403/`__PORT_CHECK__`/hangs.
//
// Isolatie: de private daemon ziet de host-daemon NIET en ook geen peer-
// devcontainers. Alleen de sidecar is privileged en heeft geen host-mounts.
//
// Egress: de sidecar én elke geneste container delen de (firewalled) netns van
// de devcontainer — dc-net-<naam> is `--internal`, dus de enige uitweg is de
// Huddle-proxy op huddle:80. We injecteren bovendien proxy-env in elke geneste
// container via de docker-client-config (proxies.default), zodat http(s)_proxy
// automatisch goed staat.

import fs from 'fs';
import { dockerRequest } from './docker';
import { getCaCertPem } from './tls-ca';
import { createDindAuthz, removeDindAuthz } from './dind-authz';

const DIND_IMAGE = process.env.HUDDLE_DIND_IMAGE ?? 'docker:28-dind';

// ── Rootless mode (experiment/dind-rootless) ─────────────────────────────────
// When HUDDLE_DIND_ROOTLESS=1 the sidecar runs `docker:*-dind-rootless` WITHOUT
// --privileged: dockerd runs as an unprivileged user inside a userns via
// rootlesskit, so the SIDECAR ITSELF is the isolation boundary. A nested
// container — even `--privileged` — cannot reach the host (verified: mount host
// disk denied, no host devices, host sysctl write denied, breakout maps to an
// unprivileged VM uid). That removes the need to police the Docker API, so the
// authz/HostConfig control surface is skipped (allow-all). The egress firewall is
// unaffected: dc-net is still `Internal`, host-enforced. See docs/dind/SPIKE-rootless.md.
export const DIND_ROOTLESS = process.env.HUDDLE_DIND_ROOTLESS === '1';
const DIND_IMAGE_ROOTLESS = process.env.HUDDLE_DIND_IMAGE_ROOTLESS ?? 'docker:28-dind-rootless';
const DIND_ACTIVE_IMAGE = DIND_ROOTLESS ? DIND_IMAGE_ROOTLESS : DIND_IMAGE;
// rootlesskit copy-up's /etc and /run, so a socket under /run would be shadowed.
// Put the shared socket + CA dir OUTSIDE those paths.
const DIND_RL_RUN = '/huddle-run';
const DIND_RL_SOCKET = `${DIND_RL_RUN}/docker.sock`;
const DIND_RL_CERT_MOUNT = '/huddle-certs';
const DIND_RL_DATA_TARGET = '/home/rootless/.local/share/docker';
// Host dir (gateway-visible) holding the huddle CA, bind-mounted ro into the
// rootless sidecar; dockerd trusts it via SSL_CERT_DIR (no trust-store write,
// which uid 1000 can't do). Reuses the per-container socket tree.
export function dindCertDir(containerName: string): string {
  return `${dindSockDir(containerName)}/certs`;
}

// Socket topology (C1 mitigation via a dockerd AUTHORIZATION PLUGIN — dind-authz.ts).
// The sidecar dockerd runs with `--authorization-plugin=huddle-authz` and listens
// on its OWN real socket `docker.sock`; the gateway serves the authz plugin socket
// that dockerd calls before every request. There is NO second "unfiltered" socket
// (the old inner.sock/filter split was bypassable — review findings #1/#2), so the
// devcontainer talks to docker.sock directly and dockerd enforces the guard.
//   <sockdir>/outer/docker.sock        → SIDECAR (dockerd listens) + DEVCONTAINER
//   <sockdir>/plugin/huddle-authz.sock → GATEWAY (serves) + SIDECAR (at /run/docker/plugins)
export const SOCKET_DIR = '/tmp/dc-sockets';
export const DIND_SOCKET_MOUNT = '/var/run/dind';
export const DIND_SOCKET_PATH = `${DIND_SOCKET_MOUNT}/docker.sock`;   // dockerd real socket (authz-guarded)
export const DIND_DOCKER_HOST = `unix://${DIND_SOCKET_PATH}`;
export const DIND_PLUGIN_MOUNT = '/run/docker/plugins';              // where dockerd discovers plugins
export const AUTHZ_PLUGIN_NAME = 'huddle-authz';

// Per-container socket tree on the host (== gateway's /tmp/dc-sockets/<name>).
export function dindSockDir(containerName: string): string {
  return `${SOCKET_DIR}/${containerName}`;
}
// Devcontainer-facing dir — holds docker.sock (dockerd's own socket, authz-guarded).
export function dindOuterDir(containerName: string): string {
  return `${dindSockDir(containerName)}/outer`;
}
// Gateway-served authz plugin dir — mounted into the sidecar at /run/docker/plugins.
export function dindPluginDir(containerName: string): string {
  return `${dindSockDir(containerName)}/plugin`;
}
export function dindPluginSockPath(containerName: string): string {
  return `${dindPluginDir(containerName)}/${AUTHZ_PLUGIN_NAME}.sock`;
}
export function dindDataVolume(containerName: string): string {
  return `huddle-dind-data-${containerName}`;
}
export function dindContainerName(containerName: string): string {
  return `dind-${containerName}`;
}

// Pull het dind-image als het lokaal ontbreekt. De pull-response is een stroom
// JSON-regels; dockerRequest wacht op 'end' (pull klaar) en negeert het niet-
// JSON-resultaat. Loopt via de host-daemon van de gateway (niet de proxy).
async function ensureImage(image: string): Promise<void> {
  try {
    await dockerRequest('GET', `/images/${encodeURIComponent(image)}/json`);
    return;
  } catch {}
  // Digest ref (`repo@sha256:…`) → pull the whole ref, no separate tag.
  // Otherwise split repo:tag only on a `:` AFTER the last `/` (so registry:port
  // stays intact). No tag → latest.
  let query: string;
  if (image.includes('@')) {
    query = `fromImage=${encodeURIComponent(image)}`;
  } else {
    const lastSlash = image.lastIndexOf('/');
    const colon = image.indexOf(':', lastSlash + 1);
    const repo = colon === -1 ? image : image.slice(0, colon);
    const tag = colon === -1 ? 'latest' : image.slice(colon + 1);
    query = `fromImage=${encodeURIComponent(repo)}&tag=${encodeURIComponent(tag)}`;
  }
  console.log(`[dind] pulling ${image} ...`);
  const out = await dockerRequest('POST', `/images/create?${query}`);
  // The pull stream returns HTTP 200 even on failure; a mid-stream {"error":…}
  // line (auth failure, proxy block, unknown tag) must be treated as a failure —
  // otherwise the sidecar starts with a non-functional daemon.
  const text = typeof out === 'string' ? out : JSON.stringify(out ?? '');
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    let obj: any;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj && obj.error) throw new Error(`image pull failed for ${image}: ${obj.error}`);
  }
  console.log(`[dind] pulled ${image}`);
}

async function ensureVolume(name: string, parent: string): Promise<void> {
  try {
    await dockerRequest('GET', `/volumes/${encodeURIComponent(name)}`);
  } catch {
    await dockerRequest('POST', '/volumes/create', {
      Name: name,
      Labels: { 'huddle.parent': parent, 'huddle.role': 'dind' },
    });
  }
}

// The host socket dirs must exist before the containers start: `outer/` holds
// dockerd's docker.sock (mounted into the sidecar AND devcontainer), `plugin/`
// holds the gateway-served authz socket (mounted into the sidecar). Called from
// createAndStartContainer.
export async function ensureDindSockVolume(containerName: string): Promise<void> {
  for (const d of [dindOuterDir(containerName), dindPluginDir(containerName)]) {
    try { fs.mkdirSync(d, { recursive: true, mode: 0o777 }); } catch {}
    try { fs.chmodSync(d, 0o777); } catch {}
  }
}

// Proxy-env voor geneste containers wordt NIET hier (in de sidecar) gezet: het
// injecteren van proxy-env bij `docker run` is een CLIENT-feature van de docker-
// CLI (proxies.default in ~/.docker/config.json), dus het hoort in de
// DEVCONTAINER (waar de CLI/compose draait), niet op de daemon. Bovendien kan
// een geneste container de naam `huddle` niet resolven (die leeft alleen in de
// netns van de devcontainer, niet in het aparte netwerk van de private daemon),
// dus de client-config gebruikt het OPGELOSTE huddle-IP. Zie het config-script
// in docker.ts (buildDindClientProxyConfig).

export interface SidecarMount { Type: 'bind' | 'volume'; Source: string; Target: string; ReadOnly?: boolean; }

// Maak (of herstart) de DinD-sidecar voor een devcontainer. De devcontainer moet
// al draaien: de sidecar deelt zijn netwerk-namespace via container:<id>.
//
// `sharedMounts` zijn de mounts (workspace + folder-mappings) die de devcontainer
// óók heeft, op HETZELFDE doelpad. Cruciaal: de private daemon heeft een eigen
// filesystem, dus een tool dat vanuit de devcontainer een pad (bv. de workspace)
// in een geneste container bind-mount, laat de daemon dat pad in ZIJN fs zoeken.
// Zonder deze gedeelde mounts maakt Docker dan een leeg pad aan (stille lege
// mount). Door dezelfde bronnen op dezelfde targets ook in de sidecar te mounten
// zien geneste containers de echte bestanden. (Bind-mounts van willekeurige
// devcontainer-lokale paden buiten deze set blijven een beperking — zie docs.)
export async function createDindSidecar(
  containerName: string,
  devcontainerId: string,
  sharedMounts: SidecarMount[] = [],
): Promise<string> {
  const name = dindContainerName(containerName);

  // Bestaande sidecar opruimen (herstart-scenario / re-create).
  try { await dockerRequest('DELETE', `/containers/${encodeURIComponent(name)}?force=true`); } catch {}

  await ensureImage(DIND_ACTIVE_IMAGE);
  await ensureDindSockVolume(containerName);
  await ensureVolume(dindDataVolume(containerName), containerName);

  if (DIND_ROOTLESS) {
    return await createRootlessSidecar(containerName, devcontainerId, sharedMounts);
  }

  // dockerd luistert op de unix-socket in de gedeelde volume. TLS uit
  // (DOCKER_TLS_CERTDIR leeg): het pad loopt over een unix-socket in een
  // volume die alleen de devcontainer en de sidecar delen, niet over TCP.
  //
  // dockerd maakt de socket standaard root:docker/0660. De devcontainer-user
  // (vscode/dev) zit niet per se in een group met dezelfde GID over de container-
  // grens, dus zou 'permission denied' krijgen (Aspire's DCP markeert de runtime
  // dan als unhealthy en start geen containers). We chmod'en de socket daarom naar
  // 0666 zodra hij bestaat. Dat is veilig: de socket leeft in een volume die
  // ALLEEN deze devcontainer en zijn sidecar mounten — de beoogde client.
  // Huddle MITM't uitgaande HTTPS met zijn eigen CA. De daemon trekt images via
  // die proxy (HTTPS_PROXY), dus dockerd moet de Huddle-CA vertrouwen — anders
  // faalt elke pull met "x509: certificate signed by unknown authority". Installeer
  // de CA in de sidecar's trust store VOORDAT dockerd start. (docker:dind is
  // Alpine met update-ca-certificates.)
  const caB64 = Buffer.from(getCaCertPem(), 'utf8').toString('base64');
  // We bypass dockerd-entrypoint.sh (to inject the CA + chmod the socket), so we
  // must replicate its cgroup-v2 prep: move our own process out of the root
  // cgroup and enable all controllers in cgroup.subtree_control. Without this the
  // subtree stays empty and nested containers get NO memory/cpu limits (only pids)
  // — the "failed to enable controllers" warning.
  const cgroupPrep =
    `if [ -f /sys/fs/cgroup/cgroup.controllers ]; then ` +
    `mkdir -p /sys/fs/cgroup/init 2>/dev/null || true; ` +
    `xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true; ` +
    `sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true; ` +
    `fi; `;
  // Close the host-kernel-bind symlink residual (finding #3): the shared workspace/
  // folder mounts are writable by nested containers, so one could plant a symlink
  // (workspace/evil -> /proc/sys) and `-v workspace/evil:/x` — dockerd resolves the
  // symlink on the sidecar fs, reaching the HOST's rw /proc/sys (→ core_pattern →
  // host root; the lexical bind guard only sees the allowed workspace path). Remount
  // each shared mount `nosymfollow` so the kernel refuses to follow symlinks out of
  // it during bind-source resolution. Legit (non-symlink) binds are unaffected.
  const nosymList = sharedMounts
    .map(m => `'${m.Target.replace(/'/g, "'\\''")}'`)
    .join(' ');
  const nosymfollowPrep = nosymList
    ? `for t in ${nosymList}; do mount -o remount,bind,nosymfollow "$t" "$t" 2>/dev/null || true; done; `
    : '';
  const cmd = [
    'sh', '-c',
    `mkdir -p /usr/local/share/ca-certificates; ` +
    `echo "$HUDDLE_CA_B64" | base64 -d > /usr/local/share/ca-certificates/huddle-ca.crt; ` +
    `update-ca-certificates 2>/dev/null || cat /usr/local/share/ca-certificates/huddle-ca.crt >> /etc/ssl/certs/ca-certificates.crt; ` +
    cgroupPrep +
    nosymfollowPrep +
    // dockerd listens on its own docker.sock and enforces our authorization
    // plugin (huddle-authz) on every request — the C1 host-escape guard. dockerd
    // discovers the plugin by name at /run/docker/plugins/huddle-authz.sock,
    // which the gateway serves (bind-mounted in).
    `dockerd --host=unix://${DIND_SOCKET_PATH} --authorization-plugin=${AUTHZ_PLUGIN_NAME} --mtu=1400 & DPID=$!; ` +
    `i=0; while [ ! -S ${DIND_SOCKET_PATH} ] && [ $i -lt 240 ]; do sleep 0.5; i=$((i+1)); done; ` +
    // Keep the socket world-accessible: the non-root devcontainer user (vscode,
    // not in the docker group) connects to it. A one-shot chmod races socket
    // re-creation (dockerd restart) and intermittently leaves it 0660 root:docker
    // → "permission denied". A cheap background loop keeps it 0666.
    `chmod 0666 ${DIND_SOCKET_PATH} 2>/dev/null || true; ` +
    `(while true; do chmod 0666 ${DIND_SOCKET_PATH} 2>/dev/null; sleep 2; done) & wait $DPID`,
  ];

  const createBody = {
    Image: DIND_IMAGE,
    Cmd: cmd,
    Env: [
      'DOCKER_TLS_CERTDIR=',
      `HUDDLE_CA_B64=${caB64}`,
      // dockerd's eigen pulls lopen via de proxy (de netns is internal).
      'HTTP_PROXY=http://huddle:80',
      'HTTPS_PROXY=http://huddle:80',
      'http_proxy=http://huddle:80',
      'https_proxy=http://huddle:80',
      'NO_PROXY=localhost,127.0.0.1,::1,[::1],huddle,host.docker.internal',
      'no_proxy=localhost,127.0.0.1,::1,[::1],huddle,host.docker.internal',
    ],
    Labels: {
      'huddle.parent': containerName,
      'huddle.role': 'dind',
    },
    HostConfig: {
      // Deel de netwerk-namespace van de devcontainer: gepubliceerde poorten
      // landen op diens loopback, en alle egress erft diens firewall-iptables.
      NetworkMode: `container:${devcontainerId}`,
      Privileged: true,
      Mounts: [
        // outer/ (dockerd's docker.sock) shared with the devcontainer; plugin/
        // (the gateway-served authz socket) at dockerd's plugin-discovery path.
        { Type: 'bind', Source: dindOuterDir(containerName), Target: DIND_SOCKET_MOUNT },
        // READ-ONLY (review): dockerd only connects to the plugin socket, it never
        // writes here. Under authz binds are allowed, so a nested container could
        // `-v /run/docker/plugins:/x` and DELETE/replace huddle-authz.sock with an
        // allow-all plugin (root bypasses dir perms) — a full authz bypass. A
        // read-only mount blocks the write at the VFS level even for root; the
        // gateway still writes the socket on the HOST side (its own fs).
        { Type: 'bind', Source: dindPluginDir(containerName), Target: DIND_PLUGIN_MOUNT, ReadOnly: true },
        { Type: 'volume', Source: dindDataVolume(containerName), Target: '/var/lib/docker' },
        // Dezelfde workspace/folder-mounts als de devcontainer, op hetzelfde
        // doelpad, zodat bind-mounts van die paden in geneste containers de echte
        // bestanden zien (de daemon heeft een eigen fs).
        ...sharedMounts,
      ],
      // Overleeft een Huddle-herstart: de devcontainer (en dus de netns) blijft
      // bestaan, dus de sidecar kan gewoon weer opstarten.
      RestartPolicy: { Name: 'unless-stopped' },
    },
  };

  const created = await dockerRequest(
    'POST',
    `/containers/create?name=${encodeURIComponent(name)}`,
    createBody,
  );
  const id: string = created.Id;

  // Start the authz plugin BEFORE the sidecar so the socket exists when dockerd
  // loads the plugin (dockerd fails requests closed if the plugin is unreachable).
  // safeRoots = the nosymfollow'd shared-mount targets; bind sources are allowed
  // only under them (or the docker socket / named volumes).
  await createDindAuthz(containerName, dindPluginSockPath(containerName), sharedMounts.map(m => m.Target));

  await dockerRequest('POST', `/containers/${id}/start`, {});
  console.log(`[dind] sidecar ${name} started (netns of ${containerName}), authz plugin active`);
  return id;
}

// Rootless sidecar (HUDDLE_DIND_ROOTLESS=1): non-privileged, allow-all, no authz.
// The sidecar's userns is the isolation boundary. See docs/dind/SPIKE-rootless.md.
async function createRootlessSidecar(
  containerName: string,
  devcontainerId: string,
  sharedMounts: SidecarMount[],
): Promise<string> {
  const name = dindContainerName(containerName);

  // dockerd (uid 1000) can't write the system trust store, so expose the huddle
  // MITM CA via SSL_CERT_DIR instead: write it to a gateway-visible dir and
  // bind-mount it ro. Go's cert pool ADDS SSL_CERT_DIR entries to the system set,
  // so dockerd's own registry pulls through the proxy validate.
  const certDir = dindCertDir(containerName);
  try { fs.mkdirSync(certDir, { recursive: true, mode: 0o777 }); } catch {}
  fs.writeFileSync(`${certDir}/huddle-ca.crt`, getCaCertPem());
  try { fs.chmodSync(`${certDir}/huddle-ca.crt`, 0o644); } catch {}

  // First arg 'dockerd' (no leading '-') makes dockerd-entrypoint.sh SKIP its
  // default-args block — avoiding the forced `tcp://0.0.0.0:2375` listener — and
  // run exactly these flags. No `--authorization-plugin`: rootless is the
  // boundary, so Docker ops are allow-all. The entrypoint still wraps dockerd in
  // rootlesskit + docker-init + iptables setup.
  const cmd = ['dockerd', `--host=unix://${DIND_RL_SOCKET}`, '--mtu=1400'];

  const createBody = {
    Image: DIND_IMAGE_ROOTLESS,
    Cmd: cmd,
    Env: [
      'DOCKER_TLS_CERTDIR=',
      `SSL_CERT_DIR=/etc/ssl/certs:${DIND_RL_CERT_MOUNT}`,
      'HTTP_PROXY=http://huddle:80',
      'HTTPS_PROXY=http://huddle:80',
      'http_proxy=http://huddle:80',
      'https_proxy=http://huddle:80',
      'NO_PROXY=localhost,127.0.0.1,::1,[::1],huddle,host.docker.internal',
      'no_proxy=localhost,127.0.0.1,::1,[::1],huddle,host.docker.internal',
    ],
    Labels: { 'huddle.parent': containerName, 'huddle.role': 'dind' },
    HostConfig: {
      // Deel de netns van de devcontainer: gepubliceerde poorten landen op diens
      // loopback (Aspire DCP), egress erft diens firewall (dc-net is Internal).
      NetworkMode: `container:${devcontainerId}`,
      // NIET privileged. Minimale versoepeling (getest):
      //  - seccomp=unconfined: VEREIST — het default seccomp-profiel blokkeert de
      //    fork/exec + userns-syscalls die rootlesskit nodig heeft.
      //  - apparmor NIET versoepeld: het default profiel werkt (geen uitbraak-
      //    oppervlak onnodig vergroten; op WSL2 is apparmor sowieso afwezig).
      //  - Leeg MaskedPaths/ReadonlyPaths = API-equivalent van CLI `systempaths=
      //    unconfined`: unmaskt /proc zodat dockerd de net-sysctls voor geneste
      //    bridge-netwerken kan schrijven.
      // Een uitbraak wordt door de userns hoe dan ook tot een unprivileged uid
      // beperkt; dit houdt het uitbraak-oppervlak van de sidecar-container zelf
      // zo klein mogelijk.
      SecurityOpt: ['seccomp=unconfined'],
      MaskedPaths: [],
      ReadonlyPaths: [],
      Devices: [
        { PathOnHost: '/dev/fuse', PathInContainer: '/dev/fuse', CgroupPermissions: 'rwm' },
        { PathOnHost: '/dev/net/tun', PathInContainer: '/dev/net/tun', CgroupPermissions: 'rwm' },
      ],
      Mounts: [
        // Socket buiten /run (rootlesskit copy-up't /run); dezelfde host-dir die
        // de devcontainer op /var/run/dind mount → gedeelde socket.
        { Type: 'bind', Source: dindOuterDir(containerName), Target: DIND_RL_RUN },
        { Type: 'bind', Source: certDir, Target: DIND_RL_CERT_MOUNT, ReadOnly: true },
        // Rootless bewaart data onder ~/.local/share/docker, niet /var/lib/docker.
        { Type: 'volume', Source: dindDataVolume(containerName), Target: DIND_RL_DATA_TARGET },
        ...sharedMounts,
      ],
      RestartPolicy: { Name: 'unless-stopped' },
    },
  };

  const created = await dockerRequest('POST', `/containers/create?name=${encodeURIComponent(name)}`, createBody);
  const id: string = created.Id;
  await dockerRequest('POST', `/containers/${id}/start`, {});
  chmodRootlessSocketWhenReady(containerName);
  console.log(`[dind] rootless sidecar ${name} started (netns of ${containerName}), allow-all (no authz)`);
  return id;
}

// rootless dockerd creates its socket 0660 owned by uid 1000; the devcontainer
// user may differ. The gateway sees the socket on the host bind (outer dir) —
// chmod it 0666 once it appears. A short loop also covers a dockerd restart
// re-creating the socket. (root gateway can chmod a uid-1000-owned file.)
function chmodRootlessSocketWhenReady(containerName: string): void {
  const sock = `${dindOuterDir(containerName)}/docker.sock`;
  let ticks = 0;
  const timer = setInterval(() => {
    ticks++;
    try { if (fs.existsSync(sock)) fs.chmodSync(sock, 0o666); } catch {}
    if (ticks > 150) clearInterval(timer);
  }, 2000);
  timer.unref?.();
}

// Sidecar + zijn volumes verwijderen wanneer de devcontainer wordt opgeruimd.
export async function removeDindSidecar(containerName: string): Promise<void> {
  const name = dindContainerName(containerName);
  removeDindAuthz(containerName);
  try { await dockerRequest('DELETE', `/containers/${encodeURIComponent(name)}?force=true`); } catch {}
  try { await dockerRequest('DELETE', `/volumes/${encodeURIComponent(dindDataVolume(containerName))}?force=true`); } catch {}
  try { fs.rmSync(dindSockDir(containerName), { recursive: true, force: true }); } catch {}
}

// Leid de te delen mounts (workspace + folder-mappings) af uit de devcontainer
// zelf, zodat een herstel-recreate dezelfde targets krijgt. Sluit de dind-socket-
// mount uit (die voegt createDindSidecar zelf toe).
async function sharedMountsFromDevcontainer(devcontainerId: string): Promise<SidecarMount[]> {
  try {
    const info = await dockerRequest('GET', `/containers/${encodeURIComponent(devcontainerId)}/json`);
    const mounts: any[] = info?.Mounts ?? [];
    const out: SidecarMount[] = [];
    for (const m of mounts) {
      const target: string = m.Destination ?? '';
      if (!target || target === DIND_SOCKET_MOUNT) continue;
      if (m.Type === 'bind') out.push({ Type: 'bind', Source: m.Source, Target: target, ReadOnly: m.RW === false });
      else if (m.Type === 'volume' && m.Name) out.push({ Type: 'volume', Source: m.Name, Target: target, ReadOnly: m.RW === false });
    }
    return out;
  } catch { return []; }
}

// Bij Huddle-herstart: zorg dat de sidecar draait voor een bestaande
// devcontainer (start indien gestopt, maak opnieuw indien weg).
export async function ensureDindSidecar(containerName: string, devcontainerId: string): Promise<void> {
  const name = dindContainerName(containerName);
  try {
    const info = await dockerRequest('GET', `/containers/${encodeURIComponent(name)}/json`);
    // The sidecar survives a gateway restart (RestartPolicy) with dockerd still
    // running under --authorization-plugin, but the plugin SERVER lives in the
    // gateway process and is now gone — so dockerd fails every request closed
    // until we re-establish it. Re-create the authz plugin BEFORE (re)starting so
    // the socket is present when dockerd reconnects. safeRoots (bind allowlist) are
    // derived from the devcontainer's shared mounts, same as createDindSidecar.
    if (!DIND_ROOTLESS) {
      const restoreRoots = (await sharedMountsFromDevcontainer(devcontainerId)).map(m => m.Target);
      await createDindAuthz(containerName, dindPluginSockPath(containerName), restoreRoots);
    }
    if (!info?.State?.Running) {
      await dockerRequest('POST', `/containers/${encodeURIComponent(name)}/start`, {});
      console.log(`[dind] sidecar ${name} restarted`);
    }
    // The socket-chmod loop lives in the (now-restarted) gateway process; re-arm it.
    if (DIND_ROOTLESS) chmodRootlessSocketWhenReady(containerName);
  } catch {
    const shared = await sharedMountsFromDevcontainer(devcontainerId);
    await createDindSidecar(containerName, devcontainerId, shared);
  }
}
