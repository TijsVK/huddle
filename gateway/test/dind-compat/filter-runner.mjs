// Standalone runner for the DinD host-escape filter, so the compat harness
// exercises the SAME code path the gateway ships (devcontainer → filter →
// inner.sock) instead of talking to raw dockerd. Usage:
//   node filter-runner.mjs <name> <filterSockPath> <innerSockPath>
// Keeps running until killed; recreates the filter socket on start.
import { createDindFilter } from '../../dist/dind-filter.js';

const [name, filterSock, innerSock] = process.argv.slice(2);
if (!name || !filterSock || !innerSock) {
  console.error('usage: filter-runner.mjs <name> <filterSock> <innerSock>');
  process.exit(2);
}

// Wait for the sidecar's inner.sock to appear, then front it with the filter.
import fs from 'fs';
let tries = 0;
const timer = setInterval(async () => {
  if (fs.existsSync(innerSock)) {
    clearInterval(timer);
    try {
      await createDindFilter(name, filterSock, innerSock);
      console.error(`[filter-runner] ${name}: ${filterSock} -> ${innerSock}`);
    } catch (e) {
      console.error(`[filter-runner] failed: ${e?.message ?? e}`);
      process.exit(1);
    }
  } else if (++tries > 480) { // ~240s
    console.error('[filter-runner] inner.sock never appeared');
    process.exit(1);
  }
}, 500);

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
