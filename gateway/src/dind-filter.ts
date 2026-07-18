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

// Does this request turn the connection into a raw hijacked/upgraded stream?
// After it the bytes on the wire are no longer HTTP/1 and must be tunnelled
// verbatim. Covers: interactive exec-start (Detach!=true), container attach, the
// BuildKit control endpoint `/grpc` (h2c upgrade — the DEFAULT `docker build`
// path), and generally any request carrying an `Upgrade:` header (websockets,
// future upgrades). Missing any of these makes the filter misparse the post-
// upgrade frames as new HTTP requests and the connection dies with EOF.
function isHijack(method: string, p: string, body: Buffer, headerText: string): boolean {
  if (/^upgrade:/im.test(headerText)) return true;
  if (/^connection:\s*.*\bupgrade\b/im.test(headerText)) return true;
  if (p === '/grpc' || p === '/session') return true;
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
      // 'parse'       — parsing client requests; upstream responses pipe through.
      // 'awaitHijack' — forwarded a hijack CANDIDATE; watching its response to
      //                 confirm (101 / docker raw-stream) before going raw. This
      //                 is the safety hinge: a create can never reach the daemon
      //                 uninspected, because we only stop parsing once the daemon
      //                 has actually switched protocols (and then it no longer
      //                 interprets bytes as container-create calls).
      // 'raw'         — confirmed hijack; tunnel both directions verbatim.
      let mode: 'parse' | 'awaitHijack' | 'raw' = 'parse';
      let buf = Buffer.alloc(0);          // unparsed client bytes (parse mode)
      let pendingClient = Buffer.alloc(0); // client bytes held during awaitHijack
      let respBuf = Buffer.alloc(0);       // upstream bytes buffered during awaitHijack
      let clientEnded = false;
      let closed = false;

      function destroy(): void {
        if (closed) return;
        closed = true;
        client.destroy();
        upstream.destroy();
      }

      upstream.on('error', destroy);
      client.on('error', destroy);
      upstream.on('end', () => { try { client.end(); } catch {} });
      // Forward half-close (stdin-EOF) so the daemon-side process finishes, but
      // keep both sides readable (allowHalfOpen) so exec output still flows back.
      client.on('end', () => {
        clientEnded = true;
        if (mode !== 'awaitHijack') { try { upstream.end(); } catch {} }
      });

      // Decide, from the buffered upstream response headers, whether the candidate
      // actually hijacked. Returns 'yes' | 'no' | 'need-more'.
      function hijackVerdict(): 'yes' | 'no' | 'need-more' {
        const end = respBuf.indexOf(CRLF2);
        if (end === -1) return respBuf.length > 65536 ? 'no' : 'need-more';
        const head = respBuf.slice(0, end).toString('latin1');
        const status = head.split('\r\n')[0] ?? '';
        if (/\b101\b/.test(status)) return 'yes';                 // Switching Protocols
        const ct = headerValue(head, 'content-type') ?? '';
        if (/vnd\.docker\.(raw|multiplexed)-stream/i.test(ct)) return 'yes'; // exec/attach
        return 'no';
      }

      upstream.on('data', (chunk: Buffer) => {
        if (mode !== 'awaitHijack') { client.write(chunk); return; }
        respBuf = Buffer.concat([respBuf, chunk]);
        const verdict = hijackVerdict();
        if (verdict === 'need-more') return;
        // Flush what we buffered of the response to the client either way.
        client.write(respBuf);
        respBuf = Buffer.alloc(0);
        if (verdict === 'yes') {
          mode = 'raw';
          if (pendingClient.length) { upstream.write(pendingClient); pendingClient = Buffer.alloc(0); }
          if (clientEnded) { try { upstream.end(); } catch {} }
        } else {
          // Not a hijack: resume normal request parsing on the held client bytes.
          mode = 'parse';
          buf = pendingClient; pendingClient = Buffer.alloc(0);
          pump();
          if (clientEnded) { try { upstream.end(); } catch {} }
        }
      });

      // Parse as many complete requests out of `buf` as possible, forwarding each.
      function pump(): void {
        while (mode === 'parse' && buf.length > 0) {
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

          if (process.env.HUDDLE_DIND_FILTER_DEBUG) {
            console.error(`[dind-filter dbg] ${method} ${p} bodyLen=${bodyBytes.length} candidate=${isHijack(method, p, bodyBytes, headerText)}`);
          }
          upstream.write(reqBytes);
          buf = buf.slice(bodyEnd);

          if (isHijack(method, p, bodyBytes, headerText)) {
            // Don't go raw yet — hold remaining client bytes and confirm from the
            // response. A create pipelined after the candidate stays UNforwarded
            // (in pendingClient) until we know the daemon hijacked; if it didn't,
            // pump() re-parses and re-inspects it.
            mode = 'awaitHijack';
            pendingClient = buf; buf = Buffer.alloc(0);
            return;
          }
        }
      }

      client.on('data', (chunk: Buffer) => {
        if (mode === 'raw') { upstream.write(chunk); return; }
        if (mode === 'awaitHijack') { pendingClient = Buffer.concat([pendingClient, chunk]); return; }
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
