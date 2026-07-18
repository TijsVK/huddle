// Standalone runner for the DinD authorization plugin, so the compat harness
// exercises the SAME guard the gateway ships (dockerd --authorization-plugin ->
// huddle-authz). Usage:
//   node authz-runner.mjs <name> <pluginSockPath>
// Serves the plugin socket; dockerd (started separately with
// --authorization-plugin=huddle-authz) calls it before every request.
import { createDindAuthz } from '../../dist/dind-authz.js';

const [name, pluginSock] = process.argv.slice(2);
if (!name || !pluginSock) {
  console.error('usage: authz-runner.mjs <name> <pluginSock>');
  process.exit(2);
}

createDindAuthz(name, pluginSock)
  .then(() => console.error(`[authz-runner] ${name}: ${pluginSock}`))
  .catch((e) => { console.error(`[authz-runner] failed: ${e?.message ?? e}`); process.exit(1); });

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
