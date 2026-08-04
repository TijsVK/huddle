#!/usr/bin/env bash
# Provision a Huddle *engine host*: a Linux box (native, or a WSL2 distro on
# Windows, or a Lima VM on macOS) that runs dockerd with the Sysbox runtime, so
# every devcontainer can be a Sysbox sandbox with its own Docker inside.
#
# Idempotent: safe to re-run. Refuses to do the disruptive parts when containers
# are running, because installing Sysbox restarts dockerd.
#
#   sudo bash huddle-engine-install.sh            # install/verify
#   sudo bash huddle-engine-install.sh --check    # verify only, change nothing
#
# On Windows this is meant to be run inside the dedicated distro:
#   wsl -d huddle-engine -u root -- bash /path/to/huddle-engine-install.sh
set -uo pipefail

SYSBOX_VERSION="${SYSBOX_VERSION:-0.7.1}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

ok(){ printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m[--]\033[0m %s\n' "$*"; }
info(){ printf '\033[36m==\033[0m %s\n' "$*"; }
fatal(){ printf '\033[31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fatal "run as root (sudo)."

# -- 1. prerequisites ---------------------------------------------------------
info "checking prerequisites"
rc=0
KVER=$(uname -r); KMAJ=${KVER%%.*}; KMIN=$(echo "$KVER" | cut -d. -f2)
if [ "$KMAJ" -gt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 19 ]; }; then
  ok "kernel $KVER (>= 5.19: ID-mapped mounts, no shiftfs needed)"
elif [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 12 ]; then
  ok "kernel $KVER (>= 5.12; 5.19+ recommended)"
else
  no "kernel $KVER is too old for Sysbox (needs >= 5.12, ideally >= 5.19)"; rc=1
fi
[ -e /dev/fuse ] && ok "/dev/fuse present (sysbox-fs is FUSE-based)" || { no "/dev/fuse missing"; rc=1; }
[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = cgroup2fs ] && ok "cgroup v2" || no "cgroup v1 - Sysbox prefers v2"
[ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" -gt 0 ] \
  && ok "user namespaces enabled" || { no "user namespaces disabled"; rc=1; }
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ]; then
  ok "systemd is PID 1 (Sysbox ships systemd units)"
else
  no "systemd is not PID 1 - on WSL2 set '[boot]\\nsystemd=true' in /etc/wsl.conf and 'wsl --shutdown'"; rc=1
fi
grep -qi microsoft /proc/version && info "WSL2 detected - Sysbox's installer handles this case explicitly"
[ $rc -eq 0 ] || fatal "prerequisites not met (see above)."

# -- 2. docker engine ---------------------------------------------------------
info "checking docker engine"
if command -v dockerd >/dev/null 2>&1; then
  ok "docker engine present ($(docker --version 2>/dev/null | head -1))"
else
  [ $CHECK_ONLY -eq 1 ] && { no "docker engine missing"; exit 1; }
  info "installing docker-ce"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends ca-certificates curl gnupg >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true
  ok "docker engine installed"
fi

# -- 2b. node (the Huddle CLI + gateway orchestration run ON the engine host) --
info "checking node"
if command -v node >/dev/null 2>&1; then
  ok "node present ($(node --version))"
else
  [ $CHECK_ONLY -eq 1 ] && no "node missing (needed to run the Huddle CLI on the engine)" || {
    info "installing node 24"
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs >/dev/null
    ok "node installed ($(node --version))"
  }
fi

# -- 3. sysbox ----------------------------------------------------------------
info "checking sysbox"
if command -v sysbox-runc >/dev/null 2>&1 && systemctl is-active --quiet sysbox 2>/dev/null; then
  ok "sysbox active ($(sysbox-runc --version 2>/dev/null | awk '/version/{print $2}' | head -1))"
else
  [ $CHECK_ONLY -eq 1 ] && { no "sysbox not installed/active"; exit 1; }
  # The installer must restart dockerd and refuses while containers exist.
  running=$(docker ps -aq 2>/dev/null | wc -l)
  if [ "$running" -gt 0 ]; then
    fatal "$running container(s) exist. Sysbox's installer must restart dockerd and refuses to proceed.
       Remove them first (this is why engine setup belongs in provisioning):
         docker rm -f \$(docker ps -aq)"
  fi
  info "installing sysbox-ce ${SYSBOX_VERSION}"
  arch=$(dpkg --print-architecture)
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  url="https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}-0.linux_${arch}.deb"
  alt="https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}.linux_${arch}.deb"
  curl -fsSL -o "$tmp/sysbox.deb" "$alt" || curl -fsSL -o "$tmp/sysbox.deb" "$url" \
    || fatal "could not download sysbox-ce ${SYSBOX_VERSION} for ${arch}"
  apt-get install -y --no-install-recommends jq fuse rsync iptables lsb-release >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/sysbox.deb" || fatal "sysbox install failed"
  ok "sysbox installed"
fi

# -- 4. docker runtime registration -------------------------------------------
info "checking runtime registration"
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'sysbox-runc'; then
  ok "dockerd knows the sysbox-runc runtime"
else
  no "sysbox-runc is not registered in dockerd"
  [ $CHECK_ONLY -eq 1 ] && exit 1
  fatal "add it to /etc/docker/daemon.json and restart docker:
       {\"runtimes\":{\"sysbox-runc\":{\"path\":\"/usr/bin/sysbox-runc\"}}}"
fi

# -- 5. smoke test ------------------------------------------------------------
if [ $CHECK_ONLY -eq 0 ]; then
  info "smoke test: unprivileged container under sysbox-runc"
  # sysbox-mgr/sysbox-fs come up right after install; give them a moment.
  for _i in $(seq 1 15); do systemctl is-active --quiet sysbox && break; sleep 2; done
  if ! docker image inspect alpine >/dev/null 2>&1; then
    info "  pulling alpine for the smoke test"
    docker pull -q alpine >/dev/null 2>&1 || no "  could not pull alpine (network/proxy?)"
  fi
  if docker image inspect alpine >/dev/null 2>&1; then
    smoke=$(docker run --rm --runtime=sysbox-runc alpine sh -c 'head -1 /proc/self/uid_map' 2>&1)
    host_uid=$(echo "$smoke" | awk '{print $2}')
    if [ -n "$host_uid" ] && [ "$host_uid" != 0 ]; then
      ok "sysbox container runs and is user-namespaced (uid_map:$smoke)"
    else
      no "sysbox smoke test failed. Output was:"
      printf '      %s\n' "$smoke"
      no "check: systemctl status sysbox sysbox-mgr sysbox-fs"
    fi
  else
    no "smoke test skipped (no alpine image)"
  fi
  fi

# -- 6. address-pool advisory -------------------------------------------------
# Sysbox's installer wants bip 172.20.0.1/16 + default-address-pool 172.25.0.0/16
# and silently skips them when they overlap existing subnets. Huddle's dc-net-*
# networks are allocated from Docker's default pool, so a clash shows up as
# devcontainers that cannot reach the gateway.
info "docker address pools"
docker network inspect bridge --format '  bridge subnet: {{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true
grep -qE '"(bip|default-address-pool)"' /etc/docker/daemon.json 2>/dev/null \
  && ok "daemon.json pins bip/default-address-pool" \
  || info "  advisory: pin \"default-address-pool\" in /etc/docker/daemon.json if you see dc-net conflicts"

info "engine host ready - start Huddle with HUDDLE_SYSBOX=1"
