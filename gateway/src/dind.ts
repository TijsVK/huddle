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

import { dockerRequest } from './docker';
import { getCaCertPem } from './tls-ca';

const DIND_IMAGE = process.env.HUDDLE_DIND_IMAGE ?? 'docker:28-dind';

// Pad (in de gedeelde volume) waar de private daemon zijn unix-socket neerzet.
// Zowel de sidecar als de devcontainer mounten deze volume op /var/run/dind.
export const DIND_SOCKET_MOUNT = '/var/run/dind';
export const DIND_SOCKET_PATH = `${DIND_SOCKET_MOUNT}/docker.sock`;
export const DIND_DOCKER_HOST = `unix://${DIND_SOCKET_PATH}`;

export function dindSockVolume(containerName: string): string {
  return `huddle-dind-sock-${containerName}`;
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
  // Splits repo:tag alleen op een `:` ná de laatste `/` (zodat registry:port
  // intact blijft). Geen tag → latest.
  const lastSlash = image.lastIndexOf('/');
  const colon = image.indexOf(':', lastSlash + 1);
  const repo = colon === -1 ? image : image.slice(0, colon);
  const tag = colon === -1 ? 'latest' : image.slice(colon + 1);
  console.log(`[dind] pulling ${image} ...`);
  await dockerRequest('POST', `/images/create?fromImage=${encodeURIComponent(repo)}&tag=${encodeURIComponent(tag)}`);
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

// De gedeelde socket-volume moet bestaan vóór de devcontainer start (die mount
// hem op /var/run/dind). Aangeroepen vanuit createAndStartContainer.
export async function ensureDindSockVolume(containerName: string): Promise<void> {
  await ensureVolume(dindSockVolume(containerName), containerName);
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
    `dockerd --host=unix://${DIND_SOCKET_PATH} --mtu=1400 & DPID=$!; ` +
    `i=0; while [ ! -S ${DIND_SOCKET_PATH} ] && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done; ` +
    `chmod 0666 ${DIND_SOCKET_PATH} 2>/dev/null || true; wait $DPID`,
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
        { Type: 'volume', Source: dindSockVolume(containerName), Target: DIND_SOCKET_MOUNT },
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
  return id;
}

// Sidecar + zijn volumes verwijderen wanneer de devcontainer wordt opgeruimd.
export async function removeDindSidecar(containerName: string): Promise<void> {
  const name = dindContainerName(containerName);
  try { await dockerRequest('DELETE', `/containers/${encodeURIComponent(name)}?force=true`); } catch {}
  for (const vol of [dindSockVolume(containerName), dindDataVolume(containerName)]) {
    try { await dockerRequest('DELETE', `/volumes/${encodeURIComponent(vol)}?force=true`); } catch {}
  }
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
    if (info?.State?.Running) return;
    await dockerRequest('POST', `/containers/${encodeURIComponent(name)}/start`, {});
    console.log(`[dind] sidecar ${name} restarted`);
  } catch {
    const shared = await sharedMountsFromDevcontainer(devcontainerId);
    await createDindSidecar(containerName, devcontainerId, shared);
  }
}
