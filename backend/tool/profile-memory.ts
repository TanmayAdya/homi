import { pathToFileURL } from 'node:url';
import { PROFILE_NODE_VERSION, runMemoryProfile } from './memory/profile-harness.ts';

const HELP = `Usage: node tool/profile-memory.ts run
       node tool/profile-memory.ts --help
Explicit run generates fictional local photo/PDF fixtures, measures fresh sequential workers,
and removes its temporary directory. No cloud connection or private input is accepted.
Use Node ${PROFILE_NODE_VERSION}. Workers use the durable server's 64 MiB old-space and 1 MiB
semi-space budgets, normal garbage collection, and no inherited preloads or forced GC.
The aggregate JSON compares local process peak RSS with a 400 MB headroom target and 500 MB reference.
It does not certify Linux container memory or hosted availability. Any failure exits nonzero.`;

export function parseMemoryProfileArguments(args: readonly string[]): 'run' | 'help' {
  if (args.length === 0 || (args.length === 1 && args[0] === '--help')) return 'help';
  if (args.length === 1 && args[0] === 'run') return 'run';
  throw new TypeError('Invalid memory profile arguments. Use --help.');
}
async function main() {
  if (parseMemoryProfileArguments(process.argv.slice(2)) === 'help') { console.log(HELP); return; }
  if (process.versions.node !== PROFILE_NODE_VERSION || !['darwin', 'linux'].includes(process.platform)) {
    throw new Error('Use the pinned Node version on a supported local platform.');
  }
  const controller = new AbortController();
  const stop = () => controller.abort();
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
  try {
    const report = await runMemoryProfile(undefined, controller.signal);
    console.log(JSON.stringify(report));
    if (report.status !== 'passed') process.exitCode = 1;
  } finally { process.off('SIGINT', stop); process.off('SIGTERM', stop); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(() => {
    console.error('Memory profiling failed. Check the pinned Node version and local tools. No private configuration or child error output was logged.');
    process.exitCode = 1;
  });
}
