'use strict';

// Direct Docker-socket access.
//
// The ExtensionContext gives us `runInContainer`, but it execs as the image's
// default user (`USER vscode` in base-devimage) and detaches without an exit
// code. Writing /etc/sudoers.d/* needs uid 0 and needs to be verified, so this
// module talks to the socket itself — same approach the aikido extension takes.
const net = require('net');

const SOCK = process.env.DOCKER_SOCKET || '/var/run/docker.sock';

// ── Raw HTTP over the unix socket ────────────────────────────────────────────

function rawRequest(method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const payload = body !== undefined ? JSON.stringify(body) : undefined;
    const head = [
      `${method} ${urlPath} HTTP/1.1`,
      'Host: localhost',
      'Content-Type: application/json',
      `Content-Length: ${payload ? Buffer.byteLength(payload) : 0}`,
      'Connection: close',
    ].join('\r\n') + '\r\n\r\n' + (payload ?? '');

    const sock = net.connect(SOCK);
    const chunks = [];
    sock.on('data', (d) => chunks.push(d));
    sock.on('end', () => {
      const raw = Buffer.concat(chunks);
      const sep = raw.indexOf('\r\n\r\n');
      if (sep < 0) return reject(new Error(`Docker ${method} ${urlPath}: malformed response`));
      const headers = raw.subarray(0, sep).toString('latin1');
      const status = parseInt((headers.split('\r\n')[0] ?? '').split(' ')[1] ?? '0', 10);
      let bodyBuf = raw.subarray(sep + 4);
      if (/\r\ntransfer-encoding:\s*chunked/i.test('\r\n' + headers)) bodyBuf = dechunk(bodyBuf);
      resolve({ status, body: bodyBuf, headers });
    });
    sock.on('error', reject);
    sock.write(head);
  });
}

// Docker replies chunked on most endpoints. Decode properly instead of
// regex-stripping the chunk headers, which corrupts binary exec output.
function dechunk(buf) {
  const out = [];
  let i = 0;
  while (i < buf.length) {
    const nl = buf.indexOf('\r\n', i, 'latin1');
    if (nl < 0) break;
    const size = parseInt(buf.subarray(i, nl).toString('latin1').split(';')[0], 16);
    if (!Number.isFinite(size) || size <= 0) break;
    const start = nl + 2;
    out.push(buf.subarray(start, start + size));
    i = start + size + 2;
  }
  return Buffer.concat(out);
}

// Docker's attached exec stream is frame-multiplexed: 8-byte header
// (stream-type + 3 pad + 4-byte big-endian length) per frame.
function demux(buf) {
  let i = 0;
  let text = '';
  while (i + 8 <= buf.length) {
    const len = buf.readUInt32BE(i + 4);
    text += buf.subarray(i + 8, i + 8 + len).toString('utf8');
    i += 8 + len;
  }
  // Not a multiplexed stream (Tty:true or a plain body) — take it verbatim.
  return i === 0 ? buf.toString('utf8') : text;
}

async function dockerJson(method, urlPath, body) {
  const res = await rawRequest(method, urlPath, body);
  const text = res.body.toString('utf8');
  if (res.status >= 400) throw new Error(`Docker ${method} ${urlPath} -> ${res.status}: ${text.trim()}`);
  try {
    return text ? JSON.parse(text) : {};
  } catch {
    return {};
  }
}

// ── Public helpers ───────────────────────────────────────────────────────────

async function inspectContainer(name) {
  return dockerJson('GET', `/containers/${encodeURIComponent(name)}/json`);
}

// Devcontainers carry the IntelliJ devcontainer label — same filter core uses in
// listDevcontainers(). Everything else (huddle itself, sidecars, the user's own
// containers) is deliberately out of scope for this extension.
async function listDevcontainers() {
  const filters = encodeURIComponent(JSON.stringify({ label: ['com.intellij.devcontainer.id'] }));
  const containers = await dockerJson('GET', `/containers/json?all=1&filters=${filters}`);
  return (containers || []).map((c) => ({
    id: c.Id,
    name: ((c.Names && c.Names[0]) || '').replace(/^\//, ''),
    state: c.State,
    status: c.Status,
    running: c.State === 'running',
    presentableName: (c.Labels || {})['com.intellij.devcontainer.presentable.name'] || '',
    ide: (c.Labels || {})['com.devcontainer.ide'] || '',
  }));
}

/** Run a shell script as root in a running container and wait for its exit code. */
async function execAsRoot(containerName, script) {
  const created = await dockerJson('POST', `/containers/${encodeURIComponent(containerName)}/exec`, {
    User: 'root',
    Cmd: ['sh', '-c', script],
    AttachStdout: true,
    AttachStderr: true,
    Tty: false,
  });
  if (!created.Id) throw new Error(`exec create failed for ${containerName}`);

  // Detach:false — the socket stays open until the command finishes, which is
  // what lets us read the exit code afterwards instead of firing and forgetting.
  const started = await rawRequest('POST', `/exec/${created.Id}/start`, { Detach: false, Tty: false });
  const output = demux(started.body).trim();

  const info = await dockerJson('GET', `/exec/${created.Id}/json`);
  const exitCode = typeof info.ExitCode === 'number' ? info.ExitCode : null;
  return { exitCode, output };
}

module.exports = { rawRequest, dockerJson, inspectContainer, listDevcontainers, execAsRoot, demux, dechunk };
