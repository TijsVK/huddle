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
# Set to 0 by any check that proves the engine is NOT usable. The script used to
# end with "engine host ready" no matter what came before it.
VERIFIED=1

ok(){ printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m[--]\033[0m %s\n' "$*"; }
info(){ printf '\033[36m==\033[0m %s\n' "$*"; }
fatal(){ printf '\033[31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# After a distro restart systemd is still bringing services up, so every check
# below must wait instead of concluding "not installed" from a race.
wait_for_docker(){
  for _i in $(seq 1 30); do docker info >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}
wait_for_sysbox(){
  for _i in $(seq 1 15); do systemctl is-active --quiet sysbox 2>/dev/null && return 0; sleep 2; done
  return 1
}

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

# -- 2c. fuse3 / fusermount3 ---------------------------------------------------
# sysbox-fs virtualizes /proc and /sys over FUSE and shells out to fusermount3.
# Without it EVERY sysbox container dies at
#   "failed to pre-register with sysbox-fs ... Initialization error"
# and sysbox-fs logs: fusermount: exec: "fusermount3": executable file not found.
# The sysbox package only depends on 'fuse' (FUSE 2) on some distros, so check
# this unconditionally - an engine that already has sysbox skips the install path.
info "checking fusermount3 (sysbox-fs FUSE helper)"
if command -v fusermount3 >/dev/null 2>&1; then
  ok "fusermount3 present ($(command -v fusermount3))"
else
  if [ $CHECK_ONLY -eq 1 ]; then
    no "fusermount3 MISSING - install fuse3 (every sysbox container will fail without it)"
  else
    info "installing fuse3"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fuse3 >/dev/null 2>&1
    if command -v fusermount3 >/dev/null 2>&1; then
      ok "fuse3 installed ($(command -v fusermount3))"
      # sysbox-fs caches the lookup failure; restart the stack so it picks it up.
      systemctl restart sysbox >/dev/null 2>&1 || true
      sleep 2
      ok "sysbox restarted so sysbox-fs picks up fusermount3"
    else
      no "could not install fuse3 - sysbox containers will not start"
    fi
  fi
fi

# -- 2d. a real (non-root) user ------------------------------------------------
# A distro whose only user is root makes every WSL session a root session, and
# WSL then prints "Failed to start the systemd user session for 'root'" - noise
# that lands in stdout and breaks tools which parse command output as JSON (the
# VS Code Dev Containers extension does exactly that). It is also what VS Code
# connects as over Remote-WSL. So give the engine a normal user in the docker
# group and make it the default.
HUDDLE_ENGINE_USER="${HUDDLE_ENGINE_USER:-huddle}"
info "checking engine user '$HUDDLE_ENGINE_USER'"
if id "$HUDDLE_ENGINE_USER" >/dev/null 2>&1; then
  ok "user '$HUDDLE_ENGINE_USER' exists"
elif [ $CHECK_ONLY -eq 1 ]; then
  no "user '$HUDDLE_ENGINE_USER' missing (sessions run as root; WSL will warn about the systemd user session)"
else
  useradd -m -s /bin/bash "$HUDDLE_ENGINE_USER" 2>/dev/null || true
  ok "created user '$HUDDLE_ENGINE_USER'"
fi
if id "$HUDDLE_ENGINE_USER" >/dev/null 2>&1 && [ $CHECK_ONLY -eq 0 ]; then
  groupadd -f docker
  usermod -aG docker,sudo "$HUDDLE_ENGINE_USER" 2>/dev/null || usermod -aG docker "$HUDDLE_ENGINE_USER" 2>/dev/null || true
  printf '%s\n' "$HUDDLE_ENGINE_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-huddle-engine
  chmod 0440 /etc/sudoers.d/90-huddle-engine
  ok "'$HUDDLE_ENGINE_USER' is in the docker group with passwordless sudo"
  # make it the DEFAULT wsl user, preserving the rest of wsl.conf
  if ! grep -q "^default=$HUDDLE_ENGINE_USER" /etc/wsl.conf 2>/dev/null; then
    if grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
      sed -i "/^\[user\]/,/^\[/ s/^default=.*/default=$HUDDLE_ENGINE_USER/" /etc/wsl.conf
    else
      printf '%s\n' '' '[user]' "default=$HUDDLE_ENGINE_USER" >> /etc/wsl.conf
    fi
    # NB: the distro name, not $(hostname) - inside WSL that is the WINDOWS
    # machine name, so the hint used to print a --terminate for a distro that
    # does not exist.
    ok "default WSL user set to '$HUDDLE_ENGINE_USER' (takes effect after: wsl --terminate ${HUDDLE_ENGINE_DISTRO:-huddle-engine})"
  fi
fi

# -- 3. sysbox ----------------------------------------------------------------
info "waiting for dockerd"
if wait_for_docker; then ok "dockerd responding"; else no "dockerd not responding yet"; fi
info "checking sysbox"
if command -v sysbox-runc >/dev/null 2>&1 && wait_for_sysbox; then
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
  # fuse3 and ONLY fuse3: sysbox-fs mounts through fusermount3. On Ubuntu 24.04
  # the FUSE-2 'fuse' package conflicts with 'fuse3', so asking for both fails
  # and any fallback that installs plain 'fuse' REMOVES fusermount3 - leaving an
  # engine that provisions "successfully" and then fails every container with
  # "failed to pre-register with sysbox-fs".
  apt-get install -y --no-install-recommends jq fuse3 rsync iptables lsb-release >/dev/null 2>&1 || \
    no "could not install jq/fuse3/rsync/iptables - sysbox may fail to start containers"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/sysbox.deb" || fatal "sysbox install failed"
  ok "sysbox installed"
fi

# -- 4. docker runtime registration -------------------------------------------
info "checking runtime registration"
wait_for_docker || true
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'sysbox-runc'; then
  ok "dockerd knows the sysbox-runc runtime"
elif [ $CHECK_ONLY -eq 1 ]; then
  no "sysbox-runc is not registered in dockerd"
  exit 1
else
  # Register it ourselves instead of telling the user to hand-edit JSON. Merge,
  # never overwrite: the file may hold the user's own daemon settings.
  info "registering the sysbox-runc runtime in /etc/docker/daemon.json"
  [ -s /etc/docker/daemon.json ] || echo '{}' > /etc/docker/daemon.json
  tmp=$(mktemp)
  if jq '.runtimes."sysbox-runc".path = "/usr/bin/sysbox-runc"' /etc/docker/daemon.json > "$tmp" 2>/dev/null; then
    cp /etc/docker/daemon.json /etc/docker/daemon.json.huddle-backup 2>/dev/null || true
    cp "$tmp" /etc/docker/daemon.json
    rm -f "$tmp"
    systemctl restart docker
    wait_for_docker || true
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q 'sysbox-runc'; then
      ok "sysbox-runc registered and dockerd restarted"
    else
      no "still not registered - check: journalctl -u docker -n 30"
      exit 1
    fi
  else
    rm -f "$tmp"
    no "could not edit /etc/docker/daemon.json (is jq installed?). Add manually:"
    printf '      %s\n' '{"runtimes":{"sysbox-runc":{"path":"/usr/bin/sysbox-runc"}}}'
    exit 1
  fi
fi

# -- 5. smoke test ------------------------------------------------------------
if [ $CHECK_ONLY -eq 0 ]; then
  info "smoke test: unprivileged container under sysbox-runc"
  # sysbox-mgr/sysbox-fs come up right after install; give them a moment.
  for _i in $(seq 1 15); do systemctl is-active --quiet sysbox && break; sleep 2; done
  if ! docker image inspect alpine >/dev/null 2>&1; then
    info "  pulling alpine for the smoke test"
    # Show the pull error instead of swallowing it: the usual cause is a docker
    # credential helper inherited from the Windows PATH (Rancher/Docker Desktop),
    # which fails with "exit status 127" and has nothing to do with the network.
    pull_err=$(docker pull -q alpine 2>&1) || {
      no "  could not pull alpine: $pull_err"
      case "$PATH" in
        */mnt/c/*) no "  the Windows PATH is injected into this distro; set appendWindowsPath=false in /etc/wsl.conf (or run huddle-engine.ps1 -IsolatePath) and retry" ;;
      esac
    }
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
      VERIFIED=0
    fi
  else
    # The smoke test is the ONLY proof that sysbox actually works here; skipping
    # it silently is how an engine gets declared ready and then fails on the
    # first devcontainer.
    no "smoke test could NOT run (no alpine image) - sysbox is unverified"
    VERIFIED=0
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

# -- 7. fuse / apparmor advisory ----------------------------------------------
# sysbox-fs virtualizes /proc and /sys through FUSE. If fusermount3 is missing or
# AppArmor denies it, every container fails at
#   "failed to pre-register with sysbox-fs: ... Initialization error"
if command -v fusermount3 >/dev/null 2>&1; then
  ok "fusermount3 present ($(command -v fusermount3))"
else
  no "fusermount3 MISSING - install fuse3; sysbox-fs cannot mount without it"
  VERIFIED=0
fi
if command -v aa-enabled >/dev/null 2>&1 && aa-enabled >/dev/null 2>&1; then
  info "AppArmor is enabled; if containers fail to pre-register with sysbox-fs, check"
  info "  journalctl -u sysbox-fs -n 50   (look for: fusermount3: mount failed: Permission denied)"
fi

if [ "$VERIFIED" -eq 1 ]; then
  info "engine host ready - start Huddle with HUDDLE_SYSBOX=1"
else
  no "engine provisioned but NOT verified (see the [--] lines above)"
  no "do not expect devcontainers to start until those are resolved"
  exit 1
fi
