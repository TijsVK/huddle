#!/usr/bin/env bash
# Kafka via Testcontainers — the notorious DinD case: the broker advertises a
# listener address that the client must be able to reconnect to. Testcontainers
# wires advertised.listeners to the mapped port; with the sidecar sharing the
# devcontainer netns, that mapped port is on the devcontainer's localhost, so a
# kafkajs client in the devcontainer can produce AND consume.
source "$(dirname "$0")/../lib.sh"
NAME=kafka
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

dcsh "$NAME" 'mkdir -p /home/dev/k && cat > /home/dev/k/test.mjs' <<'JS'
import { KafkaContainer } from "@testcontainers/kafka";
import { Kafka, logLevel } from "kafkajs";

const c = await new KafkaContainer("confluentinc/cp-kafka:7.6.1").withStartupTimeout(180000).start();
const broker = `${c.getHost()}:${c.getMappedPort(9093)}`;
console.error("broker " + broker);

const kafka = new Kafka({ brokers: [broker], logLevel: logLevel.NOTHING });
const admin = kafka.admin(); await admin.connect();
await admin.createTopics({ topics: [{ topic: "t1", numPartitions: 1 }] });
await admin.disconnect();

const producer = kafka.producer(); await producer.connect();
await producer.send({ topic: "t1", messages: [{ value: "HUDDLE_KAFKA_OK" }] });
await producer.disconnect();

const consumer = kafka.consumer({ groupId: "g1" });
await consumer.connect();
await consumer.subscribe({ topic: "t1", fromBeginning: true });
const got = await new Promise(async (res, rej) => {
  const to = setTimeout(() => rej(new Error("consume timeout")), 30000);
  await consumer.run({ eachMessage: async ({ message }) => {
    if (message.value?.toString() === "HUDDLE_KAFKA_OK") { clearTimeout(to); res(true); }
  }});
});
await consumer.disconnect();
console.log(got ? "CONSUME_OK" : "CONSUME_FAIL");
await c.stop();
console.log("STOPPED_OK");
JS

log "$NAME: installing @testcontainers/kafka + kafkajs"
if ! dcsh "$NAME" 'cd /home/dev/k && npm init -y >/dev/null 2>&1 && npm i @testcontainers/kafka@11 kafkajs@2 >/tmp/knpm.log 2>&1'; then
  fail "$NAME: npm install"; tail -5 /tmp/knpm.log >&2 2>/dev/null; down "$NAME"; exit 1
fi

out=$(dcsh "$NAME" 'cd /home/dev/k && node test.mjs' 2>/tmp/kafka.err)
assert_contains "$out" "CONSUME_OK" "$NAME: produce+consume via advertised listener (mapped port on localhost)" || rc=1
assert_contains "$out" "STOPPED_OK" "$NAME: broker container stopped" || rc=1
[ $rc -ne 0 ] && tail -8 /tmp/kafka.err >&2 2>/dev/null

down "$NAME"
exit $rc
