'use strict';

// Sudo Grant — additive Huddle extension.
//
// Gives the devcontainer's work user (`vscode` by default) a time-boxed
// passwordless-sudo grant from the portal: 15/30/60 minutes, revoke on demand,
// automatic revoke on expiry, reconciled across gateway restarts.
//
// Additive on purpose: it adds its own page, its own API namespace and its own
// table. It does not patch core, the SPA bundle or the `noot` flow — whatever
// core does with credentials keeps working untouched.

const dockerIo = require('./docker-io');
const { createGrantManager } = require('./grants');

const BASE = '/api/ext/sudo-grant';

module.exports.register = async function register(ctx) {
  const grants = createGrantManager({
    db: ctx.db,
    log: ctx.log,
    emitChanged: () => ctx.events.emit('changed'),
    docker: dockerIo,
    getSetting: ctx.getSetting,
  });

  // Keep a handle so a future `unregister` hook (and the tests) can reach it.
  module.exports._grants = grants;

  const fail = (reply, err) => {
    const code = err && err.statusCode ? err.statusCode : 500;
    return reply.code(code).send({ error: err && err.message ? err.message : 'unknown error' });
  };

  // Devcontainers plus their grant state — one call is enough to paint the page.
  ctx.app.get(`${BASE}/containers`, async (_req, reply) => {
    try {
      const [containers, active] = [await dockerIo.listDevcontainers(), grants.listAll()];
      const byName = new Map(active.map((g) => [g.container, g]));
      return {
        sudoUser: grants.sudoUser(),
        maxMinutes: grants.maxMinutes(),
        containers: containers.map((c) => {
          const g = byName.get(c.name);
          return {
            name: c.name,
            presentableName: c.presentableName,
            ide: c.ide,
            running: c.running,
            status: c.status,
            until: g ? g.until : null,
            user: g ? g.user : null,
          };
        }),
      };
    } catch (err) {
      return fail(reply, err);
    }
  });

  ctx.app.get(`${BASE}/grants`, async () => {
    const map = {};
    for (const g of grants.listAll()) map[g.container] = { until: g.until, user: g.user };
    return map;
  });

  ctx.app.get(`${BASE}/grants/:container`, async (req, reply) => {
    try {
      return grants.status(req.params.container);
    } catch (err) {
      return fail(reply, err);
    }
  });

  // PUT is grant-or-extend: the same call moves the deadline on an active grant.
  ctx.app.put(`${BASE}/grants/:container`, async (req, reply) => {
    try {
      const minutes = req.body && req.body.minutes;
      return await grants.grant(req.params.container, minutes);
    } catch (err) {
      return fail(reply, err);
    }
  });

  ctx.app.delete(`${BASE}/grants/:container`, async (req, reply) => {
    try {
      await grants.revoke(req.params.container);
      return { ok: true };
    } catch (err) {
      return fail(reply, err);
    }
  });

  // Don't block gateway startup on Docker round-trips (core does the same for
  // its own init work).
  grants.reconcile().catch((err) => ctx.log(`reconcile failed: ${err.message}`));

  ctx.log('registered — POST/PUT via /api/ext/sudo-grant/grants/<container>');
};

// The loader has no teardown hook yet; exported so it can be wired up when it
// does (and so an operator can call it from a REPL before uninstalling).
module.exports.unregister = async function unregister() {
  if (module.exports._grants) await module.exports._grants.dispose();
};
