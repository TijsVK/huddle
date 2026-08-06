#!/usr/bin/env bash
# Repair Sysbox containers whose uid-shift was interrupted by an unclean host
# shutdown. Run on the ENGINE HOST (needs /var/lib/docker), safe to run any time.
#
# Why this is needed
# ------------------
# For a container whose rootfs is on overlayfs, Sysbox ID-maps the lower layers
# and CHOWNS the upper (writable) layer, because overlayfs upper layers cannot be
# ID-mapped. That chown is reverted when the container stops - see sysbox-mgr's
# update(): "sysbox-runc will chown the upper layer ... Track this fact so we can
# revert that chown when the container is stopped or paused."
#
# If the host dies while the container is running - on Windows, WSL tears the
# distro down without running systemd shutdown - that revert never happens. The
# upper layer stays owned by the container's subuid base, and at the next start
# sysbox-runc's needUidShiftOnRootfs() stats the rootfs, sees an owner that is not
# true root, and concludes no shifting is needed:
#
#     if rootfsUid == 0 && rootfsGid == 0 && hostUidMap != rootfsUid ... { return true }
#     return false
#
# So the container starts with its lower layers unshifted: the whole image shows
# up as nobody:nogroup inside, sudo refuses to run, apt cannot write. Restarting
# does not help, because the on-disk owner is what drives the decision.
#
# The repair is simply to finish the interrupted revert: subtract the subuid base
# from every entry in the upper layer, so the rootfs is owned by true root again
# and Sysbox shifts it normally on the next start. The container keeps its
# identity and all of its data.
set -uo pipefail

ok(){   printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
info(){ printf '\033[36m==\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[!]\033[0m %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }

# Wait for dockerd: at boot this runs right after docker.service is up.
for _i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || { echo "dockerd not responding" >&2; exit 1; }

repaired=0
checked=0

# ONLY stopped containers. A running Sysbox container is *supposed* to have a
# chowned upper layer; "repairing" that would break a healthy container.
for id in $(docker ps -aq --filter status=exited --filter status=created 2>/dev/null); do
  runtime=$(docker inspect -f '{{.HostConfig.Runtime}}' "$id" 2>/dev/null) || continue
  case "$runtime" in *sysbox*) ;; *) continue ;; esac

  upper=$(docker inspect -f '{{.GraphDriver.Data.UpperDir}}' "$id" 2>/dev/null)
  [ -n "$upper" ] && [ -d "$upper" ] || continue
  checked=$((checked + 1))

  base=$(stat -c %u "$upper" 2>/dev/null) || continue
  [ "$base" -eq 0 ] && continue   # already root-owned: nothing was interrupted

  name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||')
  info "repairing '$name': upper layer still chowned to $base after an unclean shutdown"

  n=0
  while IFS=' ' read -r u g p; do
    nu=$u; ng=$g
    [ "$u" -ge "$base" ] && nu=$((u - base))
    [ "$g" -ge "$base" ] && ng=$((g - base))
    if [ "$nu" != "$u" ] || [ "$ng" != "$g" ]; then
      # -h: never follow symlinks, or a link pointing out of the layer would
      # have its TARGET chowned.
      chown -h "$nu:$ng" "$p" 2>/dev/null && n=$((n + 1))
    fi
  done < <(find "$upper" -printf '%U %G %p\n' 2>/dev/null)

  if [ "$(stat -c %u "$upper" 2>/dev/null)" = "0" ]; then
    ok "'$name' repaired ($n entries); it will start with its data and a working sudo"
    repaired=$((repaired + 1))
  else
    warn "'$name' could not be fully reverted; it may need to be recreated"
  fi
done

if [ "$repaired" -gt 0 ]; then
  info "repaired $repaired of $checked stopped sysbox container(s)"
else
  ok "no interrupted uid-shifts found ($checked stopped sysbox container(s) checked)"
fi
