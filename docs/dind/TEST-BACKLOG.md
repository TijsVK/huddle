# DinD test backlog — hard-to-run scenarios

Beyond the passing suite (see RESULTS.md), these stress *distinct failure modes*.
Ranked by likelihood of exposing a real bug. ✅ = now covered, ⬜ = todo,
⚠️ = characterised limitation.

> **The harness now runs the real C1 filter.** `lib.sh up()` fronts the sidecar's
> `inner.sock` with the shipped `dind-filter` (via `filter-runner.mjs`), so every
> tool is driven through the exact device/kernel/bind guard the gateway enforces —
> not raw dockerd. Consequence: tools needing `--privileged` (kind, k3d, dind-in-
> dind) are now REFUSED and their scripts assert that limitation instead of a
> cluster spin-up.

## Covered
- ✅ compose, Testcontainers(node, **incl. Ryuk** via filter-socket passthrough),
  buildx (default builder /grpc), host-path binds, workspace bind-through,
  LocalStack, act, Dev Containers CLI, Tier-2 egress
- ⚠️ **Privileged-node k8s (kind/k3d) & dind-in-dind** — refused by the C1 filter
  (need `--privileged`). `tools/{kind,k3d,nested2}.sh` assert the clean refusal.
  Use classic (socket-proxy) mode or a real cluster for those.
- ✅ Full real-gateway Aspire **+ SqlServer** E2E (issues #12/#61) — DB answers queries
- ✅ Adversarial isolation (no host/peer visibility, sidecar-confined) — `tools/isolation.sh`
- ⚠️ Nested-container **runtime** HTTPS — `e2e-nested-egress.sh`: routes through the
  proxy, but a nested container doesn't carry the Huddle MITM CA, so TLS fails
  unless the CA is mounted / `SSL_CERT_FILE` is set. Expected (matches Docker
  Desktop behind a corporate MITM); not a regression from classic huddle.

## Tier 1 — most likely to break (distinct failure modes)
- ✅ **CA-trust matrix per toolchain** — `e2e-toolchain-ca.sh`: git/go/rustup/cargo
  all pass through the MITM (system store). rustls-break did NOT reproduce (modern
  rustup/cargo honor the system store). Found+fixed: sudo dropped proxy/CA env.
  (Still ⬜: Maven/Gradle Java truststore, pip — likely need per-tool CA config.)
- ✅ **Kafka** (Testcontainers) — `tools/kafka.sh`: advertised listener + localhost works.
- ⬜ **Aspire project + EF migrations** — project resource connects to sqlserver and
  runs a migration (service discovery + loopback + DB round-trip), deeper than the
  container-only repro.

## Tier 2 — realistic, moderate risk
- ✅ compose `build:` context from the workspace — `tools/compose-build.sh`.
- ✅ Restart resilience — `e2e-restart.sh` (egress/daemon/root-grant/sidecar restored).
- ✅ Local registry build→push→pull — `tools/registry.sh`.
- ✅ Resource limits on nested containers — `tools/resources.sh` (fixed cgroup-v2 delegation).
- ✅ Playwright — `tools/playwright.sh`. ✅ multi-DB, RabbitMQ, web/HMR websockets.
- ✅ **Migration** classic↔DinD — `e2e-migrate.sh` (+ `huddle migrate`).
- ✅ kind (kubeadm+systemd nodes, image sideload) — `tools/kind.sh`.
- ⬜ Java Testcontainers (Ryuk from JVM), Skaffold/Tilt/dagger dev loops, gradle CA,
  docker exec/logs streaming (portal terminal), IPv6/dual-stack.

## Can't run in this environment — matrix gaps to flag
- ⬜ **Real IDE attach** (JetBrains Gateway / VS Code Remote) — the actual user flow,
  unautomated; largest untested surface.
- ⬜ **Podman** runtime (rootless; sidecar `--privileged` differs), **rootless Docker
  host**, **ARM64**, **GPU passthrough** (`--gpus`/DeviceRequests), **host reboot**.

## Notes on the nested-CA limitation (workarounds)
For a nested container that must make MITM'd HTTPS calls: mount the Huddle CA
(present at `/usr/local/share/ca-certificates/huddle-ca.crt` in the devcontainer)
into the nested container and point the tool at it (`SSL_CERT_FILE`,
`NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`), or bake it into the
nested image. A generic auto-inject isn't possible (Docker has no "add file/env to
every container" daemon hook) — same constraint as any corporate MITM proxy.
