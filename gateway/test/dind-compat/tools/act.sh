#!/usr/bin/env bash
# act — runs GitHub Actions workflows locally in containers. Pulls a runner
# image, creates a container, bind-mounts the workspace, execs the steps: a good
# stress of run+bind+exec+logs against the private daemon.
source "$(dirname "$0")/../lib.sh"
NAME=act
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

if ! dcsh "$NAME" 'curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b /usr/local/bin' >/tmp/act-install.log 2>&1; then
  fail "$NAME: act install"; tail -3 /tmp/act-install.log >&2; down "$NAME"; exit 1
fi
pass "$NAME: act installed ($(dcsh "$NAME" 'act --version' 2>/dev/null | tr -d '\r'))"

dcsh "$NAME" 'mkdir -p ~/proj/.github/workflows && git -C ~/proj init -q 2>/dev/null; cat > ~/proj/.github/workflows/ci.yml' <<'YML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo "ACT_STEP_OK"
YML

out=$(dcsh "$NAME" 'cd ~/proj && act push -P ubuntu-latest=node:22-bookworm-slim --pull=true 2>&1' )
assert_contains "$out" "ACT_STEP_OK" "$NAME: workflow step executed" || rc=1
if printf '%s' "$out" | grep -qiE 'Job succeeded|🏁 *Job succeeded'; then
  pass "$NAME: job succeeded"
else fail "$NAME: job did not succeed"; rc=1; fi
[ $rc -ne 0 ] && printf '%s\n' "$out" | tail -20 >&2

down "$NAME"
exit $rc
