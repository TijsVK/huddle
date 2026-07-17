#!/usr/bin/env bash
# Playwright: browser-based E2E testing workflow. Downloads a headless Chromium,
# launches it, and drives it against a page served by a nested nginx container on
# localhost (shared netns). Exercises a heavy binary download + headless browser.
source "$(dirname "$0")/../lib.sh"
NAME=pw
NET="${1:-bridge}"
rc=0
up "$NAME" "$NET" || exit 1

# Page under test: nested nginx serving a known title on localhost:8091.
dcsh "$NAME" 'printf "<title>HUDDLE_PW</title><h1>ok</h1>" > /tmp/index.html 2>/dev/null; docker run -d --name web -p 8091:80 nginx:alpine >/dev/null 2>&1; docker cp /tmp/index.html web:/usr/share/nginx/html/index.html >/dev/null 2>&1' >/dev/null 2>&1
sleep 2

dcsh "$NAME" 'mkdir -p /home/dev/pw && cat > /home/dev/pw/t.mjs' <<'JS'
import { chromium } from "playwright";
const b = await chromium.launch();
const p = await b.newPage();
await p.goto("http://localhost:8091", { waitUntil: "domcontentloaded", timeout: 20000 });
const title = await p.title();
console.log(title === "HUDDLE_PW" ? "PW_OK" : "PW_FAIL:" + title);
await b.close();
JS
log "$NAME: installing playwright + chromium (large download)"
if ! dcsh "$NAME" 'cd /home/dev/pw && npm init -y >/dev/null 2>&1 && npm i playwright >/tmp/pwnpm.log 2>&1 && npx playwright install --with-deps chromium >/tmp/pwinstall.log 2>&1'; then
  # --with-deps needs apt (root); fall back to browser-only install
  dcsh "$NAME" 'cd /home/dev/pw && npx playwright install chromium >/tmp/pwinstall2.log 2>&1' || { fail "$NAME: playwright/chromium install"; tail -5 /tmp/pwinstall.log >&2 2>/dev/null; down "$NAME"; exit 1; }
fi
pass "$NAME: playwright + chromium installed"

out=$(dcsh "$NAME" 'cd /home/dev/pw && node t.mjs' 2>/tmp/pw.err)
assert_contains "$out" "PW_OK" "$NAME: headless Chromium drove a page on localhost" || { rc=1; tail -5 /tmp/pw.err >&2 2>/dev/null; }

dcsh "$NAME" 'docker rm -f web >/dev/null 2>&1' >/dev/null 2>&1
down "$NAME"
exit $rc
