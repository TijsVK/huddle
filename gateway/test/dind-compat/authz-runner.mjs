// Standalone runner for the DinD authorization plugin, so the compat harness
// exercises the SAME guard the gateway ships (dockerd --authorization-plugin ->
// huddle-authz). Usage:
//   node authz-runner.mjs <name> <pluginSockPath> [safeRoot ...]
// safeRoots are the nosymfollow'd shared-mount targets bind sources are allowed
// under (the harness shares /work). Serves the plugin socket; dockerd (started
// separately with --authorization-plugin=huddle-authz) calls it before every
// request.
import { createDindAuthz } from '../../dist/dind-authz.js';

const [name, pluginSock, ...safeRoots] = process.argv.slice(2);
if (!name || !pluginSock) {
  console.error('usage: authz-runner.mjs <name> <pluginSock> [safeRoot ...]');
  process.exit(2);
}

createDindAuthz(name, pluginSock, safeRoots)
  .then(() => console.error(`[authz-runner] ${name}: ${pluginSock} (safeRoots: ${safeRoots.join(',') || 'none'})`))
  .catch((e) => { console.error(`[authz-runner] failed: ${e?.message ?? e}`); process.exit(1); });

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
