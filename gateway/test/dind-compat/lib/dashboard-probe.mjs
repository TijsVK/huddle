// Headless-browser parity probe for the Aspire dashboard.
//
// WHY THIS EXISTS: the dashboard is a Blazor Server app. The login URL serves a
// static shell (blazor.web.js + _framework boot); the resource grid + live state
// only arrive over a SignalR circuit backed by the resource-service gRPC channel
// AFTER the shell loads. A `curl | grep blazor.web.js` therefore passes even when
// that circuit is dead and the grid never populates — which is exactly the
// user-visible "the dashboard doesn't work" failure. This drives a real Chromium,
// logs in, waits for the circuit to render actual rows, and asserts the resources
// a user came to see are there and Running.
//
// Runs inside mcr.microsoft.com/playwright joined to the devcontainer's network
// namespace (`--network container:<dc>`), so http://localhost:<port> is the same
// loopback the Aspire dashboard binds to.
//
// Env:
//   DASH_URL   full login URL incl. ?t=<token> (from the AppHost run.log)
//   EXPECT     comma-separated resource names that MUST render (e.g. "sql,appdb,svc")
//   RUNNING    comma-separated resource names that MUST show state "Running"
//              (subset of EXPECT; databases don't have their own Running state)
//   SHOT       path to write a full-page PNG screenshot (evidence artifact)
//   TIMEOUT_MS overall budget for the grid to populate (default 90000)
//
// Exit 0 = every assertion held; prints a JSON result line either way.

import { chromium } from 'playwright';

const DASH_URL = process.env.DASH_URL;
const EXPECT = (process.env.EXPECT || '').split(',').map(s => s.trim()).filter(Boolean);
const RUNNING = (process.env.RUNNING || '').split(',').map(s => s.trim()).filter(Boolean);
const SHOT = process.env.SHOT || '/probe/dashboard.png';
const TIMEOUT_MS = parseInt(process.env.TIMEOUT_MS || '90000', 10);

const fail = (msg, extra = {}) => {
  console.log(JSON.stringify({ ok: false, error: msg, ...extra }));
  process.exit(1);
};

if (!DASH_URL) fail('DASH_URL not set');

const browser = await chromium.launch({
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
});
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();

// Surface unhandled circuit errors the way a user would notice them: Blazor
// prints "An unhandled error has occurred" to the console when the circuit dies.
const consoleErrors = [];
page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
page.on('pageerror', e => consoleErrors.push(String(e)));

try {
  // The ?t= login sets the auth cookie then 302s to the resources page.
  await page.goto(DASH_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });

  // Wait for the SignalR circuit to actually render the grid. We poll the LIVE
  // innerText (not the served HTML) for every expected resource name. If the
  // resource-service gRPC circuit is broken the grid stays empty and this times
  // out — the real failure signal.
  let text = '';
  const start = performance.now();
  let present = [];
  while (performance.now() - start < TIMEOUT_MS) {
    text = await page.evaluate(() => document.body ? document.body.innerText : '');
    present = EXPECT.filter(name => new RegExp(`(^|\\b|\\s)${name}(\\b|\\s|$)`, 'm').test(text));
    if (present.length === EXPECT.length) break;
    await page.waitForTimeout(1500);
  }

  await page.screenshot({ path: SHOT, fullPage: true }).catch(() => {});

  const missing = EXPECT.filter(n => !present.includes(n));
  if (missing.length) {
    fail('resources never rendered in the grid (circuit populated?)', {
      missing, present,
      consoleErrors: consoleErrors.slice(0, 5),
      textHead: text.slice(0, 600),
    });
  }

  // State assertion: for each resource that must be Running, find its grid row and
  // confirm the row shows "Running". Aspire renders each resource as a role=row
  // whose accessible text includes the name and the state label.
  const rowStates = await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('[role="row"]'));
    return rows.map(r => (r.innerText || '').replace(/\s+/g, ' ').trim()).filter(Boolean);
  });
  const notRunning = [];
  for (const name of RUNNING) {
    const row = rowStates.find(t => new RegExp(`(^|\\s)${name}(\\s|$)`).test(t));
    if (!row || !/Running/i.test(row)) notRunning.push({ name, row: row || '(no row found)' });
  }
  if (notRunning.length) {
    fail('expected resources are not in Running state', {
      notRunning, rowStatesSample: rowStates.slice(0, 12),
      consoleErrors: consoleErrors.slice(0, 5),
    });
  }

  // Open the SqlServer resource detail and read what a user inspecting "the stats"
  // would see: its state + endpoint. Best-effort — the row-level Running assertion
  // above is the hard gate; this enriches the evidence.
  let sqlDetail = null;
  try {
    const sqlName = RUNNING.find(n => /sql/i.test(n)) || EXPECT.find(n => /sql/i.test(n));
    if (sqlName) {
      const link = page.locator(`text="${sqlName}"`).first();
      await link.click({ timeout: 5000 });
      await page.waitForTimeout(2500);
      await page.screenshot({ path: SHOT.replace(/\.png$/, '-detail.png'), fullPage: true }).catch(() => {});
      sqlDetail = (await page.evaluate(() => document.body.innerText))
        .replace(/\s+/g, ' ').slice(0, 500);
    }
  } catch { /* detail view is a bonus, not a gate */ }

  console.log(JSON.stringify({
    ok: true,
    rendered: present,
    running: RUNNING,
    consoleErrors: consoleErrors.slice(0, 5),
    sqlDetailHead: sqlDetail,
  }));
  process.exit(0);
} catch (e) {
  await page.screenshot({ path: SHOT, fullPage: true }).catch(() => {});
  fail('probe threw: ' + String(e), { consoleErrors: consoleErrors.slice(0, 5) });
} finally {
  await browser.close().catch(() => {});
}
