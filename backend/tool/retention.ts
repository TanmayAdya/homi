import { pathToFileURL } from 'node:url';
import { PostgresLifecycleMaintenance } from '../src/storage/lifecycle-maintenance.ts';
import { assertMigrationsCurrent } from '../src/storage/migrate.ts';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';
import { configureRetentionSchedule } from '../src/storage/retention-scheduler.ts';

const HELP = `Usage: node tool/retention.ts [--dry-run | --apply | --schedule | --unschedule]
Default --dry-run reports scheduler state and pending account-deletion count only.
--apply removes expired draft payloads/previews/receipts once; no Auth calls.
--schedule installs pg_cron if needed and schedules database cleanup every 15 minutes.
--unschedule removes only the exact Safe at Home job; leaves pg_cron installed.
Load the private operator database configuration, never the API runtime login.
No case, user, credential, SQL, or custom job argument is accepted.`;

export function parseRetentionArguments(args: readonly string[]) {
  if (args.length === 0) return '--dry-run' as const;
  if (args.length !== 1 || !['--help', '--dry-run', '--apply', '--schedule', '--unschedule'].includes(args[0]!)) {
    throw new TypeError('Invalid retention arguments. Use --help.');
  }
  return args[0] as '--help' | '--dry-run' | '--apply' | '--schedule' | '--unschedule';
}

async function main() {
  const action = parseRetentionArguments(process.argv.slice(2));
  if (action === '--help') { console.log(HELP); return; }
  const pool = createPostgresPool(await databaseConfigurationFromEnvironment(process.env, 'migration'));
  try {
    await assertMigrationsCurrent(pool);
    const maintenance = new PostgresLifecycleMaintenance(pool);
    if (action === '--apply') console.log(JSON.stringify({ mode: 'apply', ...await maintenance.sweepRetention() }));
    else {
      const scheduler = await configureRetentionSchedule(pool,
        action === '--schedule' ? 'schedule' : action === '--unschedule' ? 'unschedule' : 'status');
      console.log(JSON.stringify({ mode: action.slice(2), scheduler,
        pendingAccountDeletions: await maintenance.pendingAuthDeletionCount() }));
      if (scheduler.conflict) process.exitCode = 1;
    }
  } finally { await pool.end(); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(() => {
    console.error('Retention operation failed. Check migration/operator configuration and the named cron job. No credentials or database details were logged.');
    process.exitCode = 1;
  });
}
