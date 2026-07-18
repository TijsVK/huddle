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
import { createDindFilter, removeDindFilter } from './dind-filter';

const DIND_IMAGE = process.env.HUDDLE_DIND_IMAGE ?? 'docker:28-dind';

// Socket topology (C1 mitigation): the sidecar dockerd listens on `inner.sock`
// and the gateway runs a host-escape FILTER (dind-filter.ts) that serves
// `docker.sock`; the devcontainer's DOCKER_HOST points at the filter. Both live
// in the shared host dir /tmp/dc-sockets/<name> (the one dir the long-running
// gateway can reach), mounted at /var/run/dind in the sidecar AND the devcontainer.
export const SOCKET_DIR = '/tmp/dc-sockets';
export const DIND_SOCKET_MOUNT = '/var/run/dind';
export const DIND_SOCKET_PATH = `${DIND_SOCKET_MOUNT}/docker.sock`;   // filter (devcontainer-facing)
export const DIND_INNER_SOCK_PATH = `${DIND_SOCKET_MOUNT}/inner.sock`; // sidecar dockerd
export const DIND_DOCKER_HOST = `unix://${DIND_SOCKET_PATH}`;

// Per-container socket dir on the host (== gateway's /tmp/dc-sockets/<name>).
export function dindSockDir(containerName: string): string {
  return `${SOCKET_DIR}/${containerName}`;
}
export function dindFilterSockPath(containerName: string): string {
  return `${dindSockDir(containerName)}/docker.sock`;
}
export function dindInnerSockPath(containerName: string): string {
  return `${dindSockDir(containerName)}/inner.sock`;
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

// De gedeelde socket-DIR (host-bind, geen named volume) moet bestaan vóór de
// devcontainer start: de gateway moet inner.sock kunnen bereiken om er de
// host-escape filter voor te zetten. Aangeroepen vanuit createAndStartContainer.
export async function ensureDindSockVolume(containerName: string): Promise<void> {
  try { fs.mkdirSync(dindSockDir(containerName), { recursive: true, mode: 0o777 }); } catch {}
  try { fs.chmodSync(dindSockDir(containerName), 0o777); } catch {}
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

  await ensureImage(DIND_IMAGE);
  await ensureDindSockVolume(containerName);
  await ensureVolume(dindDataVolume(containerName), containerName);

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
  const cmd = [
    'sh', '-c',
    `mkdir -p /usr/local/share/ca-certificates; ` +
    `echo "$HUDDLE_CA_B64" | base64 -d > /usr/local/share/ca-certificates/huddle-ca.crt; ` +
    `update-ca-certificates 2>/dev/null || cat /usr/local/share/ca-certificates/huddle-ca.crt >> /etc/ssl/certs/ca-certificates.crt; ` +
    cgroupPrep +
    `dockerd --host=unix://${DIND_INNER_SOCK_PATH} --mtu=1400 & DPID=$!; ` +
    `i=0; while [ ! -S ${DIND_INNER_SOCK_PATH} ] && [ $i -lt 240 ]; do sleep 0.5; i=$((i+1)); done; ` +
    `chmod 0666 ${DIND_INNER_SOCK_PATH} 2>/dev/null || true; wait $DPID`,
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
        // Shared host socket dir (bind), NOT a named volume: the gateway must be
        // able to reach inner.sock to run the host-escape filter in front of it.
        { Type: 'bind', Source: dindSockDir(containerName), Target: DIND_SOCKET_MOUNT },
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
  await dockerRequest('POST', `/containers/${id}/start`, {});

  console.log(`[dind] sidecar ${name} started (netns of ${containerName})`);

  // Wacht tot dockerd's inner.sock bestaat, zet er dan de host-escape filter
  // (C1) voor. De devcontainer's DOCKER_HOST wijst naar de filter-socket, niet
  // rechtstreeks naar inner.sock.
  const innerHostPath = dindInnerSockPath(containerName);
  for (let i = 0; i < 240 && !fs.existsSync(innerHostPath); i++) {
    await new Promise(r => setTimeout(r, 500));
  }
  if (!fs.existsSync(innerHostPath)) {
    console.warn(`[dind] inner.sock not present for ${containerName} after wait; filter not started`);
  } else {
    await createDindFilter(containerName, dindFilterSockPath(containerName), innerHostPath);
  }
  return id;
}

// Sidecar + zijn volumes verwijderen wanneer de devcontainer wordt opgeruimd.
export async function removeDindSidecar(containerName: string): Promise<void> {
  const name = dindContainerName(containerName);
  removeDindFilter(containerName);
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
    if (!info?.State?.Running) {
      await dockerRequest('POST', `/containers/${encodeURIComponent(name)}/start`, {});
      console.log(`[dind] sidecar ${name} restarted`);
    }
    // De sidecar overleeft een gateway-herstart (RestartPolicy), maar de
    // host-escape FILTER draait in het gateway-proces en is dan weg (de oude
    // docker.sock is een dode inode). Herstel hem altijd zodat DOCKER_HOST van
    // de devcontainer weer werkt na een herstart.
    const innerHostPath = dindInnerSockPath(containerName);
    for (let i = 0; i < 240 && !fs.existsSync(innerHostPath); i++) {
      await new Promise(r => setTimeout(r, 500));
    }
    if (fs.existsSync(innerHostPath)) {
      await createDindFilter(containerName, dindFilterSockPath(containerName), innerHostPath);
    } else {
      console.warn(`[dind] inner.sock missing for ${containerName}; filter not restored`);
    }
  } catch {
    const shared = await sharedMountsFromDevcontainer(devcontainerId);
    await createDindSidecar(containerName, devcontainerId, shared);
  }
}
