// Records a video + per-step screenshots of an operator driving the Huddle web UI
// end to end: open UI → add a devcontainer → enable docker → (host runs
// `docker run hello-world`) → approve the firewall rules its image pull needs →
// verify. Runs in the huddle-dashboard-probe image with --network host so
// localhost:<port> reaches the gateway's published UI/API port.
//
// Coordinates with the host `docker run hello-world` retry loop through a shared
// mounted dir (OUT): the host writes hello.done when the run finally succeeds;
// this script keeps approving pending firewall requests until then.
//
// Env: BASE_URL, TOKEN, DC (container name), OUT (shared dir), VIDEO (video dir).

import { chromium } from 'playwright';
import fs from 'fs';

const BASE = process.env.BASE_URL;
const TOKEN = process.env.TOKEN;
const DC = process.env.DC;
const OUT = process.env.OUT || '/probe/out';
const VIDEO = process.env.VIDEO || '/probe/out/video';

let step = 0;
const log = (m, extra = {}) => console.log(JSON.stringify({ log: m, ...extra }));
const done = () => fs.existsSync(`${OUT}/hello.done`);

const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'] });
const ctx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  recordVideo: { dir: VIDEO, size: { width: 1440, height: 900 } },
  ignoreHTTPSErrors: true,
});
const page = await ctx.newPage();
const shot = async (name) => {
  step++;
  const p = `${OUT}/${String(step).padStart(2, '0')}-${name}.png`;
  await page.screenshot({ path: p }).catch(() => {});
  log(`screenshot ${name}`, { file: p });
};

const fail = async (msg, extra = {}) => {
  await shot('FAIL').catch(() => {});
  const vp = await page.video()?.path().catch(() => null);
  await ctx.close().catch(() => {});
  await browser.close().catch(() => {});
  console.log(JSON.stringify({ ok: false, error: msg, video: vp, ...extra }));
  process.exit(1);
};

try {
  // ── 1. open the web UI + log in (token in the real query string, pre-hash) ──
  log('opening web UI + logging in');
  await page.goto(`${BASE}/?token=${TOKEN}#/dashboard`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForSelector('a.nav__item', { timeout: 20000 }); // shell renders only when authenticated
  await page.waitForTimeout(1200);
  await shot('dashboard');

  // ── 2. add a devcontainer via the Start modal ───────────────────────────────
  log('adding a devcontainer');
  await page.click('button[title="Start devcontainer"]');
  await page.waitForSelector('.modal-box', { timeout: 10000 });
  await page.selectOption('#start-ide', 'vscode');       // default image → huddle-e2e-base
  await page.waitForTimeout(1500);                        // let image list load
  await page.check('label.empty-toggle input[type="checkbox"]'); // empty = no workspace needed
  await page.fill('#start-name', DC);
  await shot('start-modal');
  await page.click('.modal-box button.btn-primary');     // Start → POST /api/docker/start
  await page.waitForTimeout(3500);
  await shot('container-created');

  // ── 3. enable docker functionalities (grant on the Docker permissions page) ──
  log('enabling docker functionalities');
  await page.getByRole('link', { name: 'Docker permissions' }).click();
  await page.waitForSelector('#da-container-select', { timeout: 10000 });
  // the new container may take a moment to appear in the picker
  for (let i = 0; i < 20; i++) {
    const opts = await page.locator('#da-container-select option').allInnerTexts();
    if (opts.some(o => o.includes(DC))) break;
    await page.waitForTimeout(1000);
  }
  await page.selectOption('#da-container-select', { label: DC }).catch(async () => {
    // value may be the raw name rather than the label
    await page.selectOption('#da-container-select', DC).catch(() => {});
  });
  await page.waitForTimeout(1000);
  // grant a permanent docker window
  await page.locator('.da-extend__buttons button', { hasText: 'Permanent' }).first().click().catch(() => log('grant button not found (DinD may not gate)'));
  await page.waitForTimeout(800);
  // turn on Pull (best-effort; irrelevant in allow-all DinD but part of the UI)
  await page.locator('button.da-toggle[aria-label="Pull off"]').first().click({ timeout: 3000 }).catch(() => {});
  await page.waitForTimeout(600);
  await shot('docker-enabled');

  // ── 4. approve the firewall rules docker's pull needs, as they appear ────────
  // The host is now retrying `docker run hello-world`; each attempt surfaces the
  // next registry domain as a pending request. Approve every pending row globally
  // until the host reports the run finished.
  log('approving firewall rules for the docker pull');
  await page.getByRole('link', { name: 'Firewall' }).click();
  await page.waitForTimeout(1500);
  await shot('firewall-initial');

  const start = performance.now();
  let approvals = 0;
  const seen = new Set();
  while (performance.now() - start < 180000) {
    if (done()) break;
    const rows = page.locator('.req-row');
    const n = await rows.count();
    if (n === 0) { await page.waitForTimeout(2000); continue; }

    const row = rows.first();
    const domain = ((await row.locator('.req-row__domain').innerText().catch(() => '')) || '').trim();
    // open the radial action menu (click keeps it open)
    await row.locator('button.pie-trigger').click().catch(() => {});
    await page.waitForTimeout(500);
    // prefer "Allow globally" so the rule persists across the pull's retries
    let clicked = false;
    const allowAll = page.locator('path[data-action="approve-all"]');
    if (await allowAll.count()) {
      await allowAll.first().click({ force: true }).catch(() => {});
      const confirm = page.locator('.modal-box--narrow button.btn-primary');
      await confirm.first().click({ timeout: 4000 }).catch(() => {});
      clicked = true;
    }
    if (!clicked) {
      await page.locator('path[data-action="approve"]').first().click({ force: true }).catch(() => {});
    }
    approvals++;
    if (domain && !seen.has(domain)) { seen.add(domain); log(`approved ${domain}`); }
    await page.waitForTimeout(1000);
    await shot(`approve-${approvals}-${(domain || 'domain').replace(/[^a-z0-9.]/gi, '_')}`);
  }

  const helloDone = done();
  const helloOut = fs.existsSync(`${OUT}/hello.out`) ? fs.readFileSync(`${OUT}/hello.out`, 'utf8') : '';
  await shot('after-approvals');

  // ── 5. verify: container shows docker Active + hello-world succeeded ─────────
  log('verifying final state');
  await page.getByRole('link', { name: 'Containers' }).click();
  await page.waitForTimeout(2000);
  await shot('containers-final');

  const vp = await page.video()?.path().catch(() => null);
  await ctx.close().catch(() => {});   // flushes the video file
  await browser.close().catch(() => {});

  const helloOk = /Hello from Docker!/.test(helloOut);
  console.log(JSON.stringify({
    ok: helloDone && helloOk,
    approvals,
    approvedDomains: [...seen],
    helloDone, helloOk,
    helloOutTail: helloOut.split('\n').slice(0, 6).join(' | '),
    video: vp,
    screenshots: step,
  }));
  process.exit(helloDone && helloOk ? 0 : 1);
} catch (e) {
  await fail('flow threw: ' + String(e));
}
