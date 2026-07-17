#!/usr/bin/env bash
# RabbitMQ: broker in a nested container, publish + consume over AMQP from the
# devcontainer (amqplib) via the published port on localhost (shared netns).
source "$(dirname "$0")/../lib.sh"
NAME=rabbit
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'docker run -d --name mq -p 5672:5672 rabbitmq:4 >/dev/null 2>&1' >/dev/null 2>&1
pass "$NAME: rabbitmq broker container started"

dcsh "$NAME" 'mkdir -p /home/dev/mq && cat > /home/dev/mq/t.mjs' <<'JS'
import amqp from "amqplib";
// The broker takes ~15-30s to accept AMQP; retry the connect as the readiness gate.
let c;
for (let i = 0; i < 40; i++) {
  try { c = await amqp.connect("amqp://guest:guest@localhost:5672"); break; }
  catch { await new Promise(r => setTimeout(r, 3000)); }
}
if (!c) { console.log("CONNECT_FAIL"); process.exit(2); }
const ch = await c.createChannel();
await ch.assertQueue("q1");
ch.sendToQueue("q1", Buffer.from("HUDDLE_MQ_OK"));
const msg = await new Promise((res, rej) => {
  const to = setTimeout(() => rej(new Error("timeout")), 15000);
  ch.consume("q1", (m) => { if (m) { clearTimeout(to); res(m.content.toString()); } }, { noAck: true });
});
console.log(msg === "HUDDLE_MQ_OK" ? "MQ_OK" : "MQ_FAIL");
await c.close();
JS
dcsh "$NAME" 'cd /home/dev/mq && npm init -y >/dev/null 2>&1 && npm i amqplib >/tmp/mqnpm.log 2>&1' || { fail "$NAME: npm install amqplib"; down "$NAME"; exit 1; }
out=$(dcsh "$NAME" 'cd /home/dev/mq && node t.mjs' 2>/tmp/mq.err)
assert_contains "$out" "MQ_OK" "$NAME: AMQP publish+consume over localhost:5672" || { rc=1; tail -4 /tmp/mq.err >&2 2>/dev/null; }

dcsh "$NAME" 'docker rm -f mq >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
