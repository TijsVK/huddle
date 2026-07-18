// DinD host-escape mitigation (finding C1) — a Docker AUTHORIZATION PLUGIN.
//
// Each devcontainer's private daemon (sidecar dockerd) runs with
// `--authorization-plugin=huddle-authz`. dockerd calls this plugin for EVERY API
// request BEFORE executing it, so — unlike the old socket-proxy-in-front approach
// — there is no second "unfiltered" socket a devcontainer or nested container can
// reach to bypass the guard (review findings #1/#2), and dockerd handles all the
// hijack/stream/keep-alive/chunked framing natively (findings #4/#5/#6 dissolve).
//
// The sidecar is `--privileged`, so a nested `--privileged`/`--device`/host-
// namespace/masked-path container would reach the HOST kernel/block-devices. This
// plugin denies exactly those create-time vectors (validateDindEscape) plus
// privileged exec (validateExecEscape) and forwards everything else — so the DinD
// compat wins (Aspire, compose, buildx, Testcontainers incl. Ryuk, host-path
// binds, non-privileged run) all keep working.
//
// Protocol: dockerd speaks plain HTTP/1.1 over a unix socket. We implement the
// plugin handshake (/Plugin.Activate) and the authz hooks
// (/AuthZPlugin.AuthZReq before, /AuthZPlugin.AuthZRes after). We use Node's http
// server so request framing/keep-alive is handled by a battle-tested parser.
import http from 'http';
import fs from 'fs';
import path from 'path';
import { validateDindEscape, validateExecEscape, validateVolumeCreate, lowerKeysDeep } from './host-config-policy';

const authzServers = new Map<string, http.Server>();

interface AuthZReq {
  RequestMethod?: string;
  RequestUri?: string;
  RequestBody?: string; // base64, present for JSON bodies within dockerd's size limit
}

// Normalize the request URI the way we compare it: strip the /v1.xx API-version
// prefix and query, percent-decode, and collapse duplicate slashes so a crafted
// `//containers/create` or `%2f`-escaped path can't dodge the create match while
// still routing to create on the daemon (review finding #6).
function normUri(uri: string): string {
  let p = (uri || '').split('?')[0];
  try { p = decodeURIComponent(p); } catch { /* keep raw on bad escapes */ }
  p = p.replace(/^\/v[\d.]+(?=\/)/, '');   // drop version prefix
  p = '/' + p.split('/').filter(Boolean).join('/'); // collapse // and normalize
  return p === '/' ? '/' : p;
}

function decodeBody(b64: string | undefined): any {
  if (!b64) return undefined;
  try { return JSON.parse(Buffer.from(b64, 'base64').toString('utf8')); } catch { return undefined; }
}

// The core decision. Returns a denial reason, or null to allow.
export function authorize(req: AuthZReq): string | null {
  const method = (req.RequestMethod || '').toUpperCase();
  const uri = normUri(req.RequestUri || '');

  if (method === 'POST' && uri === '/containers/create') {
    const body = decodeBody(req.RequestBody);
    // A create always carries a JSON body. If dockerd didn't hand us one, we
    // cannot inspect it — fail CLOSED rather than allow an unseen HostConfig.
    if (body === undefined) return 'container create body not available for inspection';
    // dockerd matches keys case-insensitively, so extract HostConfig the same way
    // (finding #1) — `body.HostConfig` alone misses {"hostconfig":{...}}.
    return validateDindEscape(lowerKeysDeep(body).hostconfig);
  }
  // Exec-create: Privileged/CapAdd live at the top level of the body.
  if (method === 'POST' && /^\/containers\/[^/]+\/exec$/.test(uri)) {
    const body = decodeBody(req.RequestBody);
    if (body === undefined) return null; // exec without a body can't set Privileged
    return validateExecEscape(body); // lowercases keys internally
  }
  // Volume-create: a `local` volume with a device+o=bind option is a bind mount in
  // disguise whose sensitive path is set HERE, not at container-create (review #3).
  if (method === 'POST' && uri === '/volumes/create') {
    const body = decodeBody(req.RequestBody);
    if (body === undefined) return 'volume create body not available for inspection';
    return validateVolumeCreate(body);
  }
  // Swarm SERVICE create/update is a second container/mount factory: its
  // TaskTemplate.ContainerSpec carries Mounts + Privileges that never reach the
  // container-create guard (review #3 finding #2). Swarm mode inside a per-
  // devcontainer private daemon is not a supported workflow — refuse it wholesale.
  if (method === 'POST' && (uri === '/services/create' || /^\/services\/[^/]+\/update$/.test(uri))) {
    return 'swarm services not permitted in DinD';
  }
  return null;
}

function sendJson(res: http.ServerResponse, obj: unknown): void {
  const j = JSON.stringify(obj);
  res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(j) });
  res.end(j);
}

export function createDindAuthz(containerName: string, pluginSockPath: string): Promise<http.Server> {
  const existing = authzServers.get(containerName);
  if (existing) { existing.close(); authzServers.delete(containerName); }
  try { fs.mkdirSync(path.dirname(pluginSockPath), { recursive: true }); } catch {}
  try { fs.unlinkSync(pluginSockPath); } catch {}

  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        const url = req.url || '';
        if (url === '/Plugin.Activate') { sendJson(res, { Implements: ['authz'] }); return; }
        if (url === '/AuthZPlugin.AuthZReq') {
          let parsed: AuthZReq = {};
          try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { /* treat as empty → allow */ }
          let denial: string | null = null;
          try { denial = authorize(parsed); }
          catch { denial = 'authorization check failed'; } // fail closed on our own bug
          if (denial) sendJson(res, { Allow: false, Msg: `blocked by Huddle: ${denial}` });
          else sendJson(res, { Allow: true });
          return;
        }
        // /AuthZPlugin.AuthZRes and anything else: we don't restrict responses.
        sendJson(res, { Allow: true });
      });
      req.on('error', () => { try { res.destroy(); } catch { /* noop */ } });
    });

    // Only dockerd (a handful of connections) legitimately talks to this socket.
    // A nested container could bind + flood it; since all per-container authz
    // servers share the gateway process, cap connections and drop slow/idle ones
    // so one devcontainer can't exhaust the gateway's fds (finding #4 residual).
    server.maxConnections = 256;
    server.headersTimeout = 3000;
    server.requestTimeout = 5000;
    server.keepAliveTimeout = 5000;

    server.on('error', reject);
    server.listen(pluginSockPath, () => {
      try { fs.chmodSync(pluginSockPath, 0o600); } catch { /* best effort */ }
      authzServers.set(containerName, server);
      console.log(`[dind-authz] ${containerName}: authorization plugin on ${pluginSockPath}`);
      resolve(server);
    });
  });
}

export function removeDindAuthz(containerName: string): void {
  const s = authzServers.get(containerName);
  if (s) { s.close(); authzServers.delete(containerName); }
}
