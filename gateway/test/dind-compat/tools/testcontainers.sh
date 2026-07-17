#!/usr/bin/env bash
# Testcontainers (Node): the canonical "docker from inside my dev env" library.
# Exercises the operations the socket-proxy filters break: container create with
# an exposed port, getMappedPort() (inspect), a wait strategy, exec, and the
# Ryuk resource-reaper (a privileged-ish sidecar that connects back to the
# daemon and cleans up labelled resources).
source "$(dirname "$0")/../lib.sh"
NAME=tc
NET="${1:-bridge}"
rc=0

up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'mkdir -p /home/dev/tc && cat > /home/dev/tc/test.mjs' <<'JS'
import { GenericContainer, Wait } from "testcontainers";

const c = await new GenericContainer("redis:7-alpine")
  .withExposedPorts(6379)
  .withWaitStrategy(Wait.forLogMessage("Ready to accept connections"))
  .start();

const port = c.getMappedPort(6379);
const host = c.getHost();
console.error(`mapped ${host}:${port}`);

// exec inside the container (Testcontainers exec path)
const { output, exitCode } = await c.exec(["redis-cli", "ping"]);
if (exitCode !== 0 || !output.includes("PONG")) {
  console.log("EXEC_FAIL:" + JSON.stringify({ exitCode, output }));
  process.exit(2);
}

// reach the mapped port over the network (host networking / port mapping works)
const net = await import("node:net");
await new Promise((res, rej) => {
  const s = net.connect(port, "127.0.0.1", () => { s.write("PING\r\n"); });
  s.on("data", (d) => { s.end(); d.toString().includes("PONG") ? res() : rej(new Error("no pong: " + d)); });
  s.on("error", rej);
  setTimeout(() => rej(new Error("timeout")), 8000);
});

console.log("MAPPED_OK");
await c.stop();
console.log("STOPPED_OK");
JS

log "$NAME: installing testcontainers (npm)"
if ! dcsh "$NAME" 'cd /home/dev/tc && npm init -y >/dev/null 2>&1 && npm i testcontainers@11 >/tmp/npm.log 2>&1'; then
  fail "$NAME: npm install testcontainers"; down "$NAME"; exit 1
fi

out=$(dcsh "$NAME" 'cd /home/dev/tc && node test.mjs' 2>/tmp/tc.err)
err=$(cat /tmp/tc.err 2>/dev/null | tail -3)
assert_contains "$out" "MAPPED_OK" "$NAME: container start + getMappedPort + exec (PONG)" || rc=1
assert_contains "$out" "STOPPED_OK" "$NAME: container stop" || rc=1
[ $rc -ne 0 ] && log "$NAME stderr: $err"

# Ryuk reaper container should have been spawned (proves the reaper path works).
ryuk=$(dcsh "$NAME" 'docker ps -a --filter ancestor=testcontainers/ryuk --format "{{.Image}}" | head -1' 2>/dev/null)
[ -n "$ryuk" ] && pass "$NAME: Ryuk reaper ran ($ryuk)" || fail "$NAME: Ryuk reaper not observed (non-fatal)"

down "$NAME"
exit $rc
