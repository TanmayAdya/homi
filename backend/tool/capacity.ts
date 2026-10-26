import { pathToFileURL } from 'node:url';
import { readCapacityReport } from '../src/storage/capacity-report.ts';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';

const HELP = `Usage: node tool/capacity.ts [--help]
Default: read-only aggregate application capacity report using the private operator database configuration.
No case/user identifiers, credentials or private content are printed.
Counts use one snapshot; physical PostgreSQL sizes are approximate and are not provider billable usage.
Provider free-plan limits must be checked separately. This command never removes data or changes limits.`;

export function parseCapacityArguments(args: readonly string[]): 'report' | 'help' {
  if (args.length === 0) return 'report';
  if (args.length === 1 && args[0] === '--help') return 'help';
  throw new TypeError('Invalid capacity arguments. Use --help.');
}

async function main() {
  if (parseCapacityArguments(process.argv.slice(2)) === 'help') { console.log(HELP); return; }
  const pool = createPostgresPool(await databaseConfigurationFromEnvironment(process.env, 'migration'));
  try {
    const report = await readCapacityReport(pool);
    console.log(JSON.stringify(report));
    if (!report.quota.consistent) process.exitCode = 1;
  } finally { await pool.end(); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(() => {
    console.error('Capacity report failed. Check migration/operator configuration and full read visibility. No credentials or database details were logged.');
    process.exitCode = 1;
  });
}
