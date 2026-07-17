#!/usr/bin/env bash
# Web dev workflow mechanics: a nested container publishing an HTTP+WebSocket
# service, reached from the devcontainer over localhost (shared netns). This is
# the mechanism behind dev servers + HMR (Vite/webpack) and live reload — HTTP on
# a mapped port plus a WebSocket upgrade on localhost.
source "$(dirname "$0")/../lib.sh"
NAME=webdev
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

# jmalloc/echo-server answers HTTP and echoes WebSocket frames.
dcsh "$NAME" 'docker run -d --name echo -p 8090:8080 jmalloc/echo-server >/dev/null 2>&1' >/dev/null 2>&1
ok=""; for i in $(seq 1 20); do code=$(dcsh "$NAME" 'curl -s -o /dev/null -w %{http_code} http://localhost:8090' 2>/dev/null); [ "$code" = 200 ] && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] && pass "$NAME: dev-server HTTP on localhost:8090 (mapped port)" || { fail "$NAME: HTTP not reachable"; down "$NAME"; exit 1; }

# WebSocket round-trip over localhost (the HMR channel).
dcsh "$NAME" 'mkdir -p /home/dev/ws && cat > /home/dev/ws/w.mjs' <<'JS'
import WebSocket from "ws";
const ws = new WebSocket("ws://localhost:8090/.ws");
// echo-server sends a "Request served by ..." preamble frame first, then echoes
// our frames — so scan all messages for our marker, not just the first.
const got = await new Promise((res, rej) => {
  const to = setTimeout(() => rej(new Error("timeout")), 12000);
  ws.on("open", () => ws.send("HUDDLE_WS_OK"));
  ws.on("message", (d) => { if (d.toString().includes("HUDDLE_WS_OK")) { clearTimeout(to); res("HUDDLE_WS_OK"); } });
  ws.on("error", rej);
});
console.log(got.includes("HUDDLE_WS_OK") ? "WS_OK" : "WS_FAIL:" + got);
ws.close();
JS
dcsh "$NAME" 'cd /home/dev/ws && npm init -y >/dev/null 2>&1 && npm i ws >/tmp/wsnpm.log 2>&1' || { fail "$NAME: npm install ws"; down "$NAME"; exit 1; }
out=$(dcsh "$NAME" 'cd /home/dev/ws && node w.mjs' 2>/tmp/ws.err)
assert_contains "$out" "WS_OK" "$NAME: WebSocket round-trip over localhost (HMR channel)" || { rc=1; tail -4 /tmp/ws.err >&2 2>/dev/null; }

dcsh "$NAME" 'docker rm -f echo >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
