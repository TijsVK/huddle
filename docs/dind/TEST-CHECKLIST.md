# DinD manual test checklist

Method: spin up a **real** gateway (DinD) + devcontainer and probe each item **by
hand**. Only write an automated test when a probe reveals a bug (red → fix →
green). Generic category → specific probes. Mark: `[ ]` todo, `[~]` probing,
`[x]` checked-ok, `[!]` finding (link the fix/test).

## 1. Isolation / security (untrusted devcontainer)
- [ ] devcontainer cannot reach the HOST docker daemon (no host socket; `-H unix:///var/run/docker.sock` = private daemon only)
- [ ] nested `--privileged -v /:/rootfs` = sidecar fs, not host root (compare /etc/hostname)
- [ ] nested `--pid=host` = sidecar pid ns, not host processes
- [ ] nested `--net=host` = firewalled devcontainer netns, still no direct internet
- [ ] cannot see/kill/inspect a PEER devcontainer's containers or private daemon
- [ ] cannot read a peer's dind socket/data volume
- [ ] cannot read the MITM CA private key (where is it? /data? reachable?)
- [ ] cannot read the operator token from inside a devcontainer
- [ ] cannot reach huddle's control-plane API (3000) except the public endpoints
- [ ] SSRF: can the devcontainer make huddle connect to 169.254.169.254 / host IP / internal ranges via the proxy?
- [ ] token-exchange: can container A steal container B's real Anthropic token? replay a placeholder?
- [ ] sudo-audit endpoint: can a devcontainer POST fake audit entries for another container?
- [ ] the private-daemon socket is 0666 — anything beyond the intended devcontainer reach it?

## 2. Egress firewall
- [ ] direct internet blocked without the proxy (internal net)
- [ ] allowlisted domain reachable via proxy; non-allowlisted blocked (deny)
- [ ] wildcard rule match; case-insensitive; path-mode rules
- [ ] nested container egress goes through the proxy (injected env) and is firewalled
- [ ] devcontainer with NET_ADMIN: can it flush its own iptables to bypass? (internal net should still block)
- [ ] IPv6 egress — blocked/allowed consistently? dual-stack hosts
- [ ] DNS: can a container exfiltrate via DNS? resolv.conf integrity
- [ ] the proxy retry doesn't amplify/bypass the firewall
- [ ] HTTP (not HTTPS) egress path; CONNECT to non-443 ports
- [ ] large response / streaming (SSE) through the proxy; slow-client backpressure

## 3. Docker tool compatibility (the goal)
- [ ] compose (multi-service, healthcheck, build context, watch, profiles, depends_on)
- [ ] Testcontainers (node/java/go/.NET); Ryuk reaper
- [ ] buildx / buildkit / bake (multi-target); registry push/pull
- [ ] k8s: k3d, kind, minikube(docker); helm; kubectl port-forward
- [ ] Aspire (container + project + EF migration + dashboard telemetry/gRPC)
- [ ] LocalStack, Kafka, RabbitMQ, multi-DB, dagger, act, skaffold, tilt, playwright
- [ ] docker-in-docker-in-docker (nested²)
- [ ] `docker` all verbs: run/exec/logs/cp/commit/save/load/stats/events/system prune

## 4. Workspace / files
- [ ] host workspace bind visible in devcontainer; edits persist to host
- [ ] workspace bind-through into nested containers (shared into sidecar)
- [ ] non-shared devcontainer path → empty in nested (documented limitation)
- [ ] git worktree idempotent across recreate (changes survive)
- [ ] folder-mapping volumes (AI CLI config) persist
- [ ] large files / many files in workspace; symlinks; permissions (chown)

## 5. Grants / portal
- [ ] docker action grant (temporary timer) + per-action toggles (classic)
- [ ] permanent docker grant
- [ ] root grant (vscode passwordless sudo): apply, use, time-expiry revoke, permanent
- [ ] root grant survives gateway restart; expiry actively revokes; extend-at-expiry
- [ ] `sudo apt install` works (proxy+CA env preserved across sudo)
- [ ] approved host ports; folder mappings CRUD; settings; airlock

## 6. Lifecycle
- [ ] gateway restart: sidecar/egress/root-grant/network restore
- [ ] devcontainer stop/start: sidecar + egress self-heal, no leak
- [ ] devcontainer delete: sidecar+volumes+network cleaned, no leak
- [ ] migrate classic↔DinD (workspace + portal state preserved; guard on non-devcontainer)
- [ ] in-place update (re-init same volume/token): all data survives
- [ ] concurrent devcontainers (same ports, isolation)
- [ ] sidecar dockerd crash → recovery; huddle crash → survive (unhandledRejection)
- [ ] host reboot (env-gated)

## 7. Resource / scale / robustness
- [ ] nested --memory/--cpus/--pids enforced (cgroup v2 delegation)
- [ ] OOM: a nested container over its --memory limit is killed
- [ ] many devcontainers (5-10): resource use, image duplication, startup time
- [ ] disk pressure / large image pulls
- [ ] transient network flakes → proxy retry (idempotent) absorbs; POST not retried
- [ ] malformed inputs to the proxy (odd paths, huge headers) don't crash the gateway
- [ ] audit_log unbounded growth (a container spams requests)

## 8. Runtime matrix (env-gated — document if unrunnable)
- [ ] Podman (rootless) + `podman machine`
- [ ] rootless Docker host
- [ ] ARM64
- [ ] GPU passthrough (`--gpus`) graceful when absent
- [ ] real IDE attach (JetBrains Gateway / VS Code Remote)
