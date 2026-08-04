# S2′ results — Sysbox conformance spike on WSL2

**Date:** 2026-08-04. **Host:** WSL2, kernel `6.6.114.1-microsoft-standard-WSL2`, Debian 13
(trixie), Docker 29.6.2 (containerd snapshotter), cgroup v2, systemd as PID 1.
**Runtime under test:** Sysbox CE 0.7.1 (`sysbox-ce_0.7.1.linux_amd64.deb`).
**Raw logs:** `s2-results.txt`, `s2-results2.txt`, `s2-results3.txt`, `s2-results4.txt` in the
job scratch dir (not committed).

## Headline

**Sysbox works on WSL2, gives unprivileged Docker-in-Docker, and blocks every host-escape
vector that Huddle's DinD red test exploited — without an authorization plugin, a bind
allowlist, or a `nosymfollow` remount.**

The installer has explicit WSL2 handling; it printed `WSL2 detected, enable_unprivileged_userns
skipped.` and `WSL2 detected, check_kernel_headers skipped.` and then installed cleanly. All
three daemons (`sysbox`, `sysbox-mgr`, `sysbox-fs`) came up active, and `sysbox-runc` registered
itself in `/etc/docker/daemon.json`.

## Install notes (operational, matter for Huddle)

- The postinst **refuses to run while any container exists** ("requires a docker service restart
  … cannot proceed due to existing Docker containers"). It has to restart `dockerd`, so
  installation is disruptive by nature — for Huddle this means Sysbox belongs in the **engine
  host image/provisioning step**, never as a live migration on a running host.
- It wanted to set Docker's `bip` to `172.20.0.1/16` and `default-address-pool` to
  `172.25.0.0/16`, and **skipped both** because they overlap subnets already in use on this
  host. Huddle's `dc-net-*` address planning has to be reconciled with Sysbox's expectations.
- It raises system-wide sysctls (`fs.inotify.*` to 1048576, `kernel.keys.maxkeys=20000`,
  `kernel.pid_max=4194304`) via `/lib/sysctl.d/99-sysbox-sysctl.conf`.

## Escape matrix — measured, same host, same probes

| Probe | Plain `runc` + `--privileged` (Huddle's DinD sidecar today) | Sysbox container | Privileged container **nested inside** Sysbox |
|---|---|---|---|
| Host block devices (`ls /dev/sd*`) | **`/dev/sda`–`/dev/sdh` visible** | absent | absent |
| `/dev` contents | full host device set | `core fd full kmsg mqueue null ptmx pts random shm std* tty urandom zero` | same minimal set |
| `uid_map` | `0 0 4294967295` (**container root = host root**) | `0 165536 65536` | mapped |
| Mount a host disk | possible (proven in the DinD red test: read host `/etc/shadow`) | `mount: /mnt: permission denied` | n/a — no device nodes |
| Write host `/proc/sys/kernel/core_pattern` | possible | `Permission denied`, host value unchanged | `Permission denied` |
| Bind `/proc/sys` into a container then write | possible (round-3 finding) | — | `can't create /hostproc/kernel/core_pattern: Permission denied` |
| Load a kernel module | possible | `could not insert 'dummy': Operation not permitted` | — |
| `/proc/kcore`, `/dev/mem`, `/sys/firmware` | readable | read fails / empty | — |
| `--pid=host` / `--network=host` | allowed | **refused by the runtime**: "sysbox containers can't share namespaces [pid] with the host" | — |
| Bind `/` and read the host filesystem | yes | yes *if the operator asks for it* (`-v /:/hostroot` → `/hostroot/home` = `tijs`) | **no** — inner `-v /:/h` shows only the sandbox's own fs (`/h/home` = `admin`) |
| Container rootfs owner on the host | root | **uid 165536** | — |

### The one nuance worth stating precisely

An **outer** container started `--privileged` under Sysbox *does* get host block-device **nodes**
in `/dev` — but they are owned `nobody:nobody` and unusable:

```
brw-rw----  1 nobody nobody 8, 96 /dev/sdg
dd: can't open '/dev/sdg': Permission denied
mount: permission denied (are you root?)
head: /dev/mem: Permission denied
```

Same for explicit `--device /dev/sdg` passthrough: node present, `open()` denied. So the user
namespace holds even when the privileged flag is passed. Nonetheless the rule for Huddle is
simple and should be enforced anyway: **the devcontainer is created by Huddle, so don't pass
`--privileged` or `--device` at the outer layer.** Inside the sandbox they are harmless.

### Why this deletes the authz plugin

The plugin exists because a nested container could bind arbitrary sidecar paths (and symlinks
out of the workspace) and reach the host's writable `/proc`, `/sys`, `/dev`. Under Sysbox the
nested Docker daemon lives **inside** the sandbox's own filesystem and user namespace: binding
`/` from a nested container yields the sandbox's root, not the host's. There is nothing to
filter, so `dind-authz.ts`, the bind-source allowlist, the `nosymfollow` remount and the
masked-paths modelling all become unnecessary.

## Compatibility — what ran

| Test | Result |
|---|---|
| Sysbox container starts with **no** `--privileged` | ✅ |
| systemd as PID 1 inside the sandbox | ✅ (`systemctl is-active docker` → active) |
| Inner `dockerd`, unprivileged outer container | ✅ `innerd=20.10.17 storage=overlay2` |
| Nested `docker run hello-world` | ✅ |
| Nested container egress (`curl https://example.com`) | ✅ `egress=200` |
| Nested `docker build` + run the built image | ✅ `built-inside-sysbox` |
| Nested user-defined network, container→container by name | ✅ (`wget http://web` → `<!DOCTYPE html>`) |
| Nested `--privileged` container | ✅ runs, sees no host devices |
| `docker compose` multi-service + service-name DNS | ✅ `c-probe-1 \| <!DOCTYPE html>`, nginx logged the `GET / 200` |
| buildx plugin present | ✅ `v0.8.2-docker` (image ships an old one; ours would be current) |
| **docker-in-docker-in-docker** (`docker:24-dind` nested, privileged) | ✅ `inner2=24.0.9` + `Hello from Docker!` |
| **kind / Kubernetes inside the sandbox** | ✅ node `Ready`, all 9 `kube-system` pods `Running`, workload pod `Running` — see below |

### kind works — and this is a capability the current model cannot offer

Today's DinD documentation states the limitation plainly: "Tools that need a genuinely
`--privileged` nested container (kind/k3d/minikube worker nodes, dind-in-dind, some
nested-systemd setups) are refused in DinD mode." Under Sysbox both work.

First attempt with an unmodified `kind create cluster` **failed**, and the failure is worth
recording because it is the one real friction point found:

```
kubelet: Failed to create an oomWatcher (running in UserNS, Hint: enable
         KubeletInUserNamespace feature flag to ignore the error) err="open /dev/kmsg: no such file or directory"
kubelet: command failed err="failed to run Kubelet: failed to create kubelet: open /dev/kmsg: no such file or directory"
```

One kubeadm patch fixes it — no privileged outer container, no host access:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    featureGates:
      KubeletInUserNamespace: true
```

Result: `s2-control-plane Ready control-plane 29s v1.34.0`, with `etcd`, `kube-apiserver`,
`kube-controller-manager`, `kube-scheduler`, `kube-proxy`, `kindnet`, both `coredns` replicas and
`local-path-provisioner` all `Running`, and a test pod `t 1/1 Running`. For Huddle this means
kind/k3d support is a matter of shipping a documented kind config (or Nestybox's patched
`kindestnode` images), not a runtime limitation.

**Not yet tested (follow-up):** Huddle's real `base-devimage-*` images and the JetBrains/VS Code
backends under Sysbox; the full `dind-compat` battery driven by the gateway with
`socket-proxy`/`dind-authz` disabled; Aspire E2E; workspace-mount performance; macOS (Lima) and
native-Linux engine hosts.

## Observations to carry forward

- **Bind-mount uid behaviour:** a file created by container root in a bind-mounted host dir
  appears as `uid 0` on the host, while files in the container's own rootfs are `165536`. So
  ID-mapped mounts make bind mounts behave like plain Docker (good for the workspace UX), and
  Huddle's existing volume-permission handling probably carries over unchanged — but this is
  exactly where the current volume-perms pain lives, so it deserves its own check.
- **Minor info leak:** `cat /proc/sys/kernel/hostname` inside the sandbox returns the *host*
  hostname (`ISNL-HBJ7BH4`) even though `hostname` returns the container ID and `hostname
  <new>` works. Cosmetic, no privilege, worth a note in the threat write-up.
- **Inner Docker version is old (20.10.17)** in Nestybox's demo image — irrelevant to the
  finding, but Huddle's own images should ship a current engine.
- **`dind-squared`** initially looked broken but was a harness artefact — the `docker:24-dind`
  image's client defaults to `tcp://docker:2375`. With `-H unix:///var/run/docker.sock` it works:
  `inner2=24.0.9` and `hello-world` runs. So dockerd → dockerd → container is fine under Sysbox.
- **Workloads needing `/dev/kmsg` need a userns flag.** kind is the worked example above; expect
  the same class of fix for anything that reads kernel ring buffers or expects host devices.

## Verdict against S2′'s pass criteria

| Criterion | Outcome |
|---|---|
| Sysbox installs and runs on WSL2 | **pass** (with explicit upstream WSL2 handling) |
| Inner dockerd needs no `--privileged` | **pass** |
| Escape vectors from the DinD red test fail at the runtime | **pass** (devices, mounts, `core_pattern`, `/proc/sys` bind, modules, host-namespace sharing) |
| Tool compatibility (build, network, nested privileged) | **pass**: compose, buildx, nested build, nested privileged, dind², kind/k8s. Huddle's own images + Aspire E2E still to run |
| Honest residuals recorded | outer `--privileged`/`--device` shows unusable device nodes; operator-chosen host binds still expose the host; hostname info leak |

## Teardown / state left on this machine

- Sysbox CE 0.7.1 is **installed** (`sudo apt-get purge sysbox-ce` to remove; it will want a
  docker restart again).
- `/etc/docker/daemon.json` was **created** by the installer with only the `sysbox-runc` runtime
  entry (there was no such file before; backup at `daemon.json.bak` in the job scratch dir).
- Docker was restarted by the installer, so the three `sqlserver-*` Aspire containers were
  removed first (explicitly authorised). Their **named volumes were not touched**.
- Spike containers/images: `sbx-spike` (running), plus pulled images
  `nestybox/ubuntu-jammy-systemd-docker`, `nginx:alpine`, `docker:24-dind`, `hello-world`.
  Remove with `docker rm -f sbx-spike`.
