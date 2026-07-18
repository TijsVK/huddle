// DinD host-escape filter (mitigation for finding C1).
//
// In DinD mode the devcontainer talks to its private daemon through this thin
// per-container proxy instead of the socket directly. The private daemon's
// sidecar is --privileged, so an un-filtered `docker run --privileged`/`--device`/
// `-v /dev/…` nested container reaches the HOST's block devices and kernel — a
// host-takeover primitive. This filter denies ONLY the host-escape HostConfig
// vectors (validateDindEscape) on container-create and forwards EVERYTHING else
// UNMODIFIED. Unlike the classic socket-proxy it does NO ownership/grant/label/
// network/port filtering — and it ALLOWS ordinary host-path binds (which resolve
// against the disposable sidecar fs, not the host), so compose/testcontainers
// bind-mounts keep working; it denies only the device/kernel/namespace escape
// vectors plus a bind reaching the daemon's own control socket (filter bypass).
//
// It is a REAL streaming HTTP/1.1 proxy, not a first-request sniffer: it parses
// every request on a keep-alive connection (so pipelining a privileged create
// after a benign request cannot smuggle it past inspection) and forwards each
// unmodified. When a request initiates a hijack (interactive `docker exec`/
// `attach`, whose connection becomes a raw bidirectional stream) it stops parsing
// and raw-tunnels the rest — the earlier Connection:close approach broke those
// streams (empty output, silent data loss).
import net from 'net';
import fs from 'fs';
import path from 'path';
import { validateDindEscape } from './socket-proxy';

const filterServers = new Map<string, net.Server>();

const CRLF2 = Buffer.from('\r\n\r\n');

function deny403(client: net.Socket, msg: string): void {
  const body = JSON.stringify({ message: `blocked by Huddle: ${msg}` });
  client.write(`HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`);
  client.end();
}

function headerValue(headerText: string, name: string): string | null {
  const re = new RegExp(`^${name}:\\s*(.*)$`, 'im');
  const m = headerText.match(re);
  return m ? m[1].trim() : null;
}

// Strip a leading /v1.xx API-version prefix and the query string.
function normalizePath(rawPath: string): string {
  return rawPath.replace(/^\/v[\d.]+/, '').split('?')[0];
}

// Does this request turn the connection into a raw hijacked stream? Interactive
// exec-start (Detach!=true) and container attach both do; after them the bytes on
// the wire are no longer HTTP and must be tunnelled verbatim.
function isHijack(method: string, p: string, body: Buffer): boolean {
  if (method === 'POST' && /^\/exec\/[^/]+\/start$/.test(p)) {
    try {
      const j = JSON.parse(body.toString() || '{}');
      return j.Detach !== true; // detached exec returns normally — keep parsing
    } catch {
      return true;
    }
  }
  if (method === 'POST' && /^\/containers\/[^/]+\/attach$/.test(p)) return true;
  return false;
}

export function createDindFilter(containerName: string, filterSockPath: string, upstreamSockPath: string): Promise<net.Server> {
  const existing = filterServers.get(containerName);
  if (existing) { existing.close(); filterServers.delete(containerName); }
  try { fs.mkdirSync(path.dirname(filterSockPath), { recursive: true }); } catch {}
  try { fs.unlinkSync(filterSockPath); } catch {}

  return new Promise((resolve, reject) => {
    // allowHalfOpen is essential: docker's hijacked streams (exec/attach/run -i)
    // half-close their write side to signal stdin-EOF while still reading output.
    // Without it Node tears down the whole socket on the first FIN and the exec
    // output is silently dropped (empty result, exit 0).
    const server = net.createServer({ allowHalfOpen: true }, (client) => {
      const upstream = net.createConnection({ path: upstreamSockPath, allowHalfOpen: true });
      let buf = Buffer.alloc(0);
      let raw = false;        // hijacked → tunnel verbatim, stop parsing
      let closed = false;

      function destroy(): void {
        if (closed) return;
        closed = true;
        client.destroy();
        upstream.destroy();
      }

      upstream.on('error', destroy);
      client.on('error', destroy);
      // Forward half-close (FIN) rather than tearing down, so the peer can still
      // flush its remaining direction (e.g. exec output after stdin-EOF).
      client.on('end', () => { try { upstream.end(); } catch {} });
      upstream.on('end', () => { try { client.end(); } catch {} });

      // Responses (and hijacked upstream→client bytes) always flow straight back.
      upstream.pipe(client);

      // Parse as many complete requests out of `buf` as possible, forwarding each.
      function pump(): void {
        while (!raw && buf.length > 0) {
          const hdrEnd = buf.indexOf(CRLF2);
          if (hdrEnd === -1) return; // headers incomplete — wait for more
          const headerText = buf.slice(0, hdrEnd).toString('latin1');
          const bodyStart = hdrEnd + 4;

          const firstLine = headerText.split('\r\n')[0] ?? '';
          const [methodRaw, rawPath = ''] = firstLine.split(' ');
          const method = (methodRaw ?? '').toUpperCase();
          const p = normalizePath(rawPath);

          // Determine body length: chunked or Content-Length (else no body).
          const te = headerValue(headerText, 'transfer-encoding');
          const clStr = headerValue(headerText, 'content-length');
          let bodyEnd: number; // index in buf just past the body

          if (te && /chunked/i.test(te)) {
            const end = findChunkedEnd(buf, bodyStart);
            if (end === -1) return; // body incomplete
            bodyEnd = end;
          } else if (clStr) {
            const cl = parseInt(clStr, 10) || 0;
            if (buf.length < bodyStart + cl) return; // body incomplete
            bodyEnd = bodyStart + cl;
          } else {
            bodyEnd = bodyStart; // no body
          }

          const reqBytes = buf.slice(0, bodyEnd);
          const bodyBytes = buf.slice(bodyStart, bodyEnd);

          // Inspect container-create for host-escape vectors.
          if (method === 'POST' && p === '/containers/create') {
            let parsed: any;
            try { parsed = JSON.parse(bodyBytes.toString()); }
            catch { deny403(client, 'invalid container create body'); destroy(); return; }
            const denial = validateDindEscape(parsed.HostConfig);
            if (denial) { deny403(client, denial); destroy(); return; }
          }

          // Forward the request unmodified.
          if (process.env.HUDDLE_DIND_FILTER_DEBUG) {
            console.error(`[dind-filter dbg] ${method} ${p} bodyLen=${bodyBytes.length} hijack=${isHijack(method, p, bodyBytes)}`);
          }
          upstream.write(reqBytes);
          buf = buf.slice(bodyEnd);

          if (isHijack(method, p, bodyBytes)) {
            raw = true;
            if (buf.length > 0) { upstream.write(buf); buf = Buffer.alloc(0); }
            return;
          }
        }
      }

      client.on('data', (chunk: Buffer) => {
        if (raw) { upstream.write(chunk); return; }
        buf = Buffer.concat([buf, chunk]);
        pump();
      });
    });

    server.on('error', reject);
    server.listen(filterSockPath, () => {
      try { fs.chmodSync(filterSockPath, 0o666); } catch {}
      filterServers.set(containerName, server);
      console.log(`[dind-filter] ${containerName}: ${filterSockPath} → ${upstreamSockPath} (host-escape denied)`);
      resolve(server);
    });
  });
}

// Given `buf` and the offset where a chunked body starts, return the index just
// past the terminating 0-length chunk (incl. its trailing CRLF), or -1 if the
// body has not fully arrived yet.
function findChunkedEnd(buf: Buffer, start: number): number {
  let i = start;
  while (true) {
    const lineEnd = buf.indexOf('\r\n', i);
    if (lineEnd === -1) return -1;
    const sizeStr = buf.slice(i, lineEnd).toString('latin1').split(';')[0].trim();
    const size = parseInt(sizeStr, 16);
    if (isNaN(size)) return -1;
    if (size === 0) {
      // last chunk: skip trailers up to the final CRLF CRLF
      const term = buf.indexOf(CRLF2, lineEnd);
      if (term === -1) {
        // possibly no trailers: "0\r\n\r\n" — the CRLF2 search from lineEnd finds it
        return -1;
      }
      return term + 4;
    }
    const dataStart = lineEnd + 2;
    const dataEnd = dataStart + size;
    if (buf.length < dataEnd + 2) return -1; // data + trailing CRLF not all here
    i = dataEnd + 2;
  }
}

export function removeDindFilter(containerName: string): void {
  const s = filterServers.get(containerName);
  if (s) { s.close(); filterServers.delete(containerName); }
}
