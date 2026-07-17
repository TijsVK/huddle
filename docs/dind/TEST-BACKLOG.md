# DinD test backlog — hard-to-run scenarios

Beyond the passing suite (see RESULTS.md), these stress *distinct failure modes*.
Ranked by likelihood of exposing a real bug. ✅ = now covered, ⬜ = todo,
⚠️ = characterised limitation.

## Covered
- ✅ compose, Testcontainers(node), buildx, privileged/host-bind/volumes-from,
  k3d, LocalStack, act, Dev Containers CLI, workspace bind-through, Tier-2 egress
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
- ⬜ compose with a **`build:` context from the workspace** (build an image from a
  repo Dockerfile) — exercises the workspace→sidecar bridge for build contexts.
- ⬜ **Restart resilience** — restart huddle + the devcontainer mid-workload; confirm
  sidecar + root-grant + network restore (code exists, never E2E'd).
- ⬜ **Local registry** (`registry:2`) build→push→pull (push was socket-proxy-blocked).
- ⬜ **Resource limits** on nested containers (`--memory/--cpus`) actually enforce
  (a cgroup-v2 delegation warning was seen in the Aspire run).
- ⬜ Playwright (browser download + headless HTTPS via MITM), Java Testcontainers
  (Ryuk + copyFileToContainer), kind `load docker-image` + Ingress,
  Skaffold/Tilt/dagger dev loops.

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
