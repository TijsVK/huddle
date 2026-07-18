import { initDb } from './db';
import { createProxyServer } from './proxy';
import { createApiServer } from './api';
import { listDevcontainers, networkExists, connectNetwork, refreshContainerIptables, inspectContainer, needsMigration, DIND_ENABLED } from './docker';
import { createContainerProxy } from './socket-proxy';
import { ensureDindSidecar } from './dind';
import { initRootGrants } from './root-grant';
import { initCa } from './tls-ca';
import { sanitizeResolvConf, scheduleSettlingSanitize } from './dns-egress';

// ECONNRESET / EPIPE are normal client-disconnect events on a TCP server.
// Without this handler Node.js crashes the process on unhandled 'error' events
// from sockets that lose their connection unexpectedly.
process.on('uncaughtException', (err: NodeJS.ErrnoException) => {
  if (err.code === 'ECONNRESET' || err.code === 'EPIPE') return;
  // A malformed client request (e.g. a proxied path with unescaped characters)
  // must never crash the gateway — that would take every devcontainer's egress
  // and Docker access down with it. Log and keep serving.
  if (err.code === 'ERR_UNESCAPED_CHARACTERS' || err.code === 'ERR_INVALID_HTTP_TOKEN' || err.code === 'ERR_INVALID_CHAR') {
    console.warn('[proxy] dropped malformed request:', err.code);
    return;
  }
  console.error('[fatal] uncaught exception:', err);
  process.exit(1);
});

// An unhandled promise rejection (e.g. a URIError thrown deep in a request
// handler) must not silently terminate the gateway and take every devcontainer's
// egress + Docker access down. Log and keep serving.
process.on('unhandledRejection', (reason: any) => {
  console.error('[proxy] unhandled rejection (kept alive):', reason?.message ?? reason);
});

const SOCKET_DIR = '/tmp/dc-sockets';

initDb();
initCa();
createProxyServer();
createApiServer().catch(err => {
  console.error('[api] failed to start', err);
  process.exit(1);
});

// Re-create proxy sockets for all existing devcontainers (survives huddle restart).
// In DinD-modus is er geen socket-proxy; dan herstellen we de private-daemon-
// sidecars i.p.v. de proxy-sockets.
async function initContainerProxies(): Promise<void> {
  try {
    const containers = await listDevcontainers();
    for (const c of containers) {
      if (DIND_ENABLED) {
        await ensureDindSidecar(c.name, c.id);
      } else {
        await createContainerProxy(c.name, SOCKET_DIR);
      }
    }
    if (containers.length) {
      console.log(
        DIND_ENABLED
          ? `[dind] restored ${containers.length} private-daemon sidecar(s)`
          : `[socket-proxy] restored ${containers.length} proxy socket(s)`,
      );
    }
  } catch (err: any) {
    console.error('[init] container docker-access restore failed:', err.message);
  }
}

async function initContainerNetworks(): Promise<void> {
  try {
    const containers = await listDevcontainers();
    for (const c of containers) {
      const netName = `dc-net-${c.name}`;
      if (await networkExists(netName)) {
        try { await connectNetwork(netName, 'huddle'); } catch {} // already connected is fine
      }
    }
  } catch (err: any) {
    console.error('[network] init failed:', err.message);
  }
}

async function initContainerIptables(): Promise<void> {
  try {
    const containers = await listDevcontainers();
    for (const c of containers) {
      await refreshContainerIptables(c.id, c.name);
    }
  } catch (err: any) {
    console.error('[iptables] init failed:', err.message);
  }
}

initContainerProxies();
// Root-grants herstellen: verlopen intrekken, actieve opnieuw toepassen + timer.
initRootGrants().catch(err => console.error('[root-grant] init failed:', err?.message));

// Niet-destructieve migratie-hint: log welke devcontainers nog in de andere modus
// draaien (bv. klassiek terwijl HUDDLE_DIND aanstaat). Recreatie migreert ze —
// `huddle migrate <naam>` of POST /api/docker/containers/:name/migrate.
async function hintMigration(): Promise<void> {
  try {
    const containers = await listDevcontainers();
    const stale: string[] = [];
    for (const c of containers) {
      try { if (needsMigration(await inspectContainer(c.name))) stale.push(c.name); } catch {}
    }
    if (stale.length) {
      console.log(
        `[migrate] ${stale.length} devcontainer(s) not in ${DIND_ENABLED ? 'DinD' : 'classic'} mode: ${stale.join(', ')}. ` +
        `Recreate to migrate: 'huddle migrate <name>' (forced recreate; workspace + portal state preserved).`,
      );
    }
  } catch (err: any) {
    console.error('[migrate] hint failed:', err?.message);
  }
}
hintMigration();
// Reconnecten aan de devcontainer-netwerken vervuilt resolv.conf (Podman zet de
// internal-net aardvark-DNS erin); sanitize erna zodat egress-DNS blijft werken,
// óók als er (nog) geen devcontainers zijn. De settling-runs vangen bovendien de
// devcontainer-net-connect op die `huddle init` pas ná de start uitvoert.
initContainerNetworks().finally(() => { void sanitizeResolvConf(); });
scheduleSettlingSanitize();
initContainerIptables();
