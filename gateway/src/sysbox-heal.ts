import http from 'http';
import { dockerRequest, execContainerOutput } from './docker';

// ── Een devcontainer repareren die zijn uid-shift kwijt is ───────────────────
//
// Sysbox shift de rootfs van een container met een ID-mapped mount (een kernel-
// mount) of met een gechownde kloon onder /var/lib/sysbox, en kiest zelf welke.
// Verdwijnt de host onder een ID-mapped container die DRAAIT - op Windows sloopt
// WSL de distro zonder systemd-shutdown - dan start hij daarna zonder shift: de
// hele image staat binnenin op nobody:nogroup. Geen sudo, geen apt, kapotte
// setuid-binaries. Sysbox' eigen troubleshooting zegt hierover dat je "all the
// active Sysbox containers" opnieuw moet aanmaken; stoppen en starten repareert
// het aantoonbaar niet (gemeten).
//
// De gebruiker hoort daar niets van te merken: die klikt start en werkt verder
// met al zijn data. Vandaar deze reparatie. Wat waar staat, is de crux:
//
//   * de IMAGE-lagen zijn stuk in de kapotte container, maar staan goed in een
//     verse container van dezelfde image;
//   * de WRITABLE layer (alles wat de gebruiker installeerde en schreef) is IN
//     de kapotte container juist wél met de goede uid's te lezen.
//
// Dus: verse container van de originele image + de writable layer daar naartoe
// kopiëren. Van binnen naar binnen, zodat de uid's logisch blijven en elke
// container zijn eigen shift toepast. `docker commit` kan dit NIET: dat bakt de
// geshifte uid's in de image en de volgende container heeft een andere basis,
// waardoor alles alsnog op nobody uitkomt (gemeten).

const SOCK = '/var/run/docker.sock';
const HEAL_TAR = '/tmp/.huddle-heal.tar';

/** uid van een bestand IN de container. 65534 (nobody) op een image-bestand
 *  betekent dat de uid-shift weg is. */
export async function rootfsIsUnshifted(containerName: string): Promise<boolean> {
  try {
    const uid = await execContainerOutput(containerName, ['stat', '-c', '%u', '/bin/sh']);
    return uid.trim() === '65534';
  } catch {
    return false;
  }
}

/** Shell die de te kopiëren paden bepaalt en in één tar zet, IN de container.
 *
 *  - `docker diff` geeft de writable layer; alleen daar zit wat de gebruiker
 *    heeft veranderd.
 *  - alles wat in de container GEMOUNT is valt af: dat is host-state of een
 *    apart volume (de workspace-bind, het /var/lib/docker-volume van de
 *    binnendaemon, sysbox' /lib/modules). Die overleven de reparatie sowieso en
 *    /lib/modules is read-only, waar tar anders op afbreekt.
 *  - ook de ouders van een mountpoint vallen af: zo'n map wordt anders een
 *    "leaf" en dan loopt tar alsnog de mount in (dat was 143 MB aan
 *    kernelmodules in plaats van 900 KB).
 *  - en alleen leaves, anders pakt tar de onveranderde image-inhoud eronder mee.
 */
function buildTarScript(): string {
  return `set -u
cut -d' ' -f5 /proc/self/mountinfo 2>/dev/null | awk 'NF' | sort -u > /tmp/.huddle-excl
printf '%s\\n' /proc /sys /dev /tmp /run /etc/hosts /etc/hostname /etc/resolv.conf /etc/mtab >> /tmp/.huddle-excl
sort -u -o /tmp/.huddle-excl /tmp/.huddle-excl
cat > /tmp/.huddle-filter <<'AWK'
NR==FNR { e[$0]; next }
{ for (p in e) if ($0 == p || index($0, p "/") == 1 || index(p, $0 "/") == 1) next; print }
AWK
cat > /tmp/.huddle-leaves <<'AWK'
NR==FNR { a[$0]; next }
{ for (p in a) if (p != $0 && index(p, $0 "/") == 1) next; print }
AWK
sort /tmp/.huddle-changed > /tmp/.huddle-sorted
awk -f /tmp/.huddle-filter /tmp/.huddle-excl /tmp/.huddle-sorted > /tmp/.huddle-kept
awk -f /tmp/.huddle-leaves /tmp/.huddle-kept /tmp/.huddle-kept > /tmp/.huddle-list
rm -f ${HEAL_TAR}
[ -s /tmp/.huddle-list ] || { : > ${HEAL_TAR}; echo 0; exit 0; }
tar -cf ${HEAL_TAR} -T /tmp/.huddle-list 2>/dev/null || true
wc -l < /tmp/.huddle-list`;
}

/** Streamt één bestand van de ene container naar de andere via de archive-API
 *  (hetzelfde als `docker cp`). Pipen in plaats van bufferen: de tar kan
 *  gigabytes zijn. De uid's in de BUITENSTE tar doen er niet toe - alleen de
 *  bytes van het bestand - want de binnenste tar wordt straks IN de container
 *  uitgepakt, en daar gelden de logische uid's weer. */
function pipeArchive(fromId: string, srcPath: string, toId: string, destDir: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const get = http.request(
      { socketPath: SOCK, method: 'GET', path: `/containers/${encodeURIComponent(fromId)}/archive?path=${encodeURIComponent(srcPath)}` },
      (getRes) => {
        if (getRes.statusCode !== 200) {
          getRes.resume();
          reject(new Error(`archive GET ${srcPath} → ${getRes.statusCode}`));
          return;
        }
        const put = http.request(
          {
            socketPath: SOCK,
            method: 'PUT',
            path: `/containers/${encodeURIComponent(toId)}/archive?path=${encodeURIComponent(destDir)}`,
            headers: { 'content-type': 'application/x-tar' },
          },
          (putRes) => {
            putRes.resume();
            if (putRes.statusCode && putRes.statusCode < 400) resolve();
            else reject(new Error(`archive PUT → ${putRes.statusCode}`));
          }
        );
        put.on('error', reject);
        getRes.on('error', reject);
        getRes.pipe(put);
      }
    );
    get.on('error', reject);
    get.end();
  });
}

/**
 * Maakt `containerName` opnieuw aan met dezelfde configuratie en zet de writable
 * layer terug. De aanroeper heeft al vastgesteld dat de shift weg is.
 *
 * De oude container blijft tijdens het kopiëren draaien (we moeten erin execen)
 * en wordt pas verwijderd als de nieuwe staat. Gaat er iets mis, dan draait de
 * oude nog onder zijn tijdelijke naam en is er niets weggegooid.
 */
export async function healUnshiftedDevcontainer(containerRef: string): Promise<void> {
  const old = await dockerRequest('GET', `/containers/${encodeURIComponent(containerRef)}/json`);
  // De aanroeper geeft soms een id door; de naam moet van de container zelf komen,
  // anders heet de nieuwe container naar een hex-id.
  const containerName = ((old.Name as string) ?? containerRef).replace(/^\//, '');
  const stale = `${containerName}-huddle-stale`;

  // 1. lijst van veranderde paden, en die in één tar IN de oude container
  const changes: any[] = await dockerRequest('GET', `/containers/${encodeURIComponent(containerRef)}/changes`);
  const paths = (changes ?? []).filter((c) => c.Kind !== 2).map((c) => c.Path);
  await execContainerOutput(containerRef, [
    'sh', '-c', `cat > /tmp/.huddle-changed <<'EOF'\n${paths.join('\n')}\nEOF`,
  ]);
  const count = (await execContainerOutput(containerRef, ['sh', '-c', buildTarScript()])).trim();
  console.log(`[sysbox] ${containerName}: uid-shift lost, recreating with ${count} changed path(s) preserved`);

  // 2. naam vrijmaken en een verse container van dezelfde image + config maken
  await dockerRequest('POST', `/containers/${encodeURIComponent(containerRef)}/rename?name=${encodeURIComponent(stale)}`);
  let created: any;
  try {
    created = await dockerRequest('POST', `/containers/create?name=${encodeURIComponent(containerName)}`, {
      ...old.Config,
      HostConfig: old.HostConfig,
      NetworkingConfig: { EndpointsConfig: old.NetworkSettings?.Networks ?? {} },
    });
    await dockerRequest('POST', `/containers/${created.Id}/start`);
  } catch (err) {
    // niets kwijt: de oude container staat er nog, alleen onder een andere naam
    await dockerRequest('POST', `/containers/${encodeURIComponent(stale)}/rename?name=${encodeURIComponent(containerName)}`).catch(() => {});
    throw err;
  }

  // 3. de writable layer overzetten en IN de nieuwe container uitpakken
  if (count !== '0') {
    await pipeArchive(stale, HEAL_TAR, created.Id, '/tmp');
    await execContainerOutput(created.Id, ['sh', '-c', `tar -xf ${HEAL_TAR} -C / 2>/dev/null; rm -f ${HEAL_TAR}`]);
  }

  // 4. pas nu de oude weg
  await dockerRequest('DELETE', `/containers/${encodeURIComponent(stale)}?force=1&v=0`);
  console.log(`[sysbox] ${containerName}: recreated, data preserved`);
}
