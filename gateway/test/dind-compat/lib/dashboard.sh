#!/usr/bin/env bash
# assert_dashboard — drive a REAL headless Chromium against a live Aspire dashboard
# and assert the resources a user came to see actually render in the grid (over the
# SignalR/gRPC circuit), not just that the Blazor shell was served.
#
# Runs mcr.microsoft.com/playwright joined to the target devcontainer's network
# namespace (`--network container:<dc>`), so http://localhost:<port> in the browser
# is the exact loopback the dashboard binds to inside the shared netns.
#
# Usage:
#   source lib/dashboard.sh
#   assert_dashboard <dc-container> <dashboard-login-url> <expect-csv> <running-csv> <shot-dir>
#
#   expect-csv   resources that MUST render in the grid          e.g. "sql,appdb,svc"
#   running-csv  resources that MUST show state Running           e.g. "sql,svc"
#   shot-dir     host dir to receive dashboard.png (+ -detail.png)
#
# Returns 0 iff every assertion holds. Prints the probe's JSON result.
# Built once from Dockerfile.probe (playwright base + the `playwright` npm package).
PW_IMAGE="${PW_IMAGE:-huddle-dashboard-probe:latest}"

assert_dashboard() {
  local dc="$1" dashurl="$2" expect="$3" running="$4" shotdir="$5"
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$shotdir"

  # --network container:<dc> shares the devcontainer's netns → localhost = the
  # dashboard's loopback. Mount the probe read-only and a writable dir for shots.
  local out
  out=$(docker run --rm \
    --network "container:$dc" \
    -e DASH_URL="$dashurl" \
    -e EXPECT="$expect" \
    -e RUNNING="$running" \
    -e SHOT="/probe/out/dashboard.png" \
    -e TIMEOUT_MS="${DASH_TIMEOUT_MS:-90000}" \
    -v "$here/dashboard-probe.mjs:/probe/dashboard-probe.mjs:ro" \
    -v "$shotdir:/probe/out" \
    -w /probe \
    "$PW_IMAGE" \
    /probe/dashboard-probe.mjs 2>&1)
  local rc=$?
  printf '%s\n' "$out"
  return $rc
}
