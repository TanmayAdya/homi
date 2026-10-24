import { pathToFileURL } from 'node:url';
import {
  completePendingAccountDeletions, createSupabaseAccountDeleter,
  type AccountDeletionWorkerOptions, type AccountDeletionWorkerReport,
} from '../src/auth/supabase-account-deletion.ts';
import { PostgresLifecycleMaintenance } from '../src/storage/lifecycle-maintenance.ts';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';

const HELP = `Usage: node tool/complete-account-deletions.ts [--dry-run | --apply] [--limit 1..5]
Default: --dry-run (count pending requests only; no claims or provider requests).
--apply processes up to --limit queued requests serially (default limit: 1).
Load private operator database configuration separately from the runtime API.
Applying also requires SAFEATHOME_SUPABASE_URL and SAFEATHOME_SUPABASE_SECRET_KEY.
No user ID, email, password, or secret is accepted as a command-line argument.`;

export function parseAccountDeletionArguments(args: readonly string[]): AccountDeletionWorkerOptions | 'help' {
  if (args.length === 1 && args[0] === '--help') return 'help';
  let mode: 'dry-run' | 'apply' | undefined;
  let limit = 1;
  let limitSeen = false;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if ((arg === '--dry-run' || arg === '--apply') && mode === undefined) mode = arg === '--apply' ? 'apply' : 'dry-run';
    else if (arg === '--limit' && !limitSeen && /^[1-5]$/.test(args[index + 1] ?? '')) {
      limit = Number(args[++index]); limitSeen = true;
    } else throw new TypeError('Invalid account-deletion arguments. Use --help.');
  }
  return { apply: mode === 'apply', limit };
}

export async function completeAccountDeletionsFromEnvironment(
  env: NodeJS.ProcessEnv, options: AccountDeletionWorkerOptions,
): Promise<AccountDeletionWorkerReport> {
  const deleteUser = options.apply ? createSupabaseAccountDeleter({
    projectUrl: env.SAFEATHOME_SUPABASE_URL ?? '', secretKey: env.SAFEATHOME_SUPABASE_SECRET_KEY ?? '',
  }) : undefined;
  const pool = createPostgresPool(await databaseConfigurationFromEnvironment(env, 'migration'));
  try {
    return await completePendingAccountDeletions(new PostgresLifecycleMaintenance(pool), deleteUser, options);
  } finally { await pool.end(); }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  Promise.resolve().then(async () => {
    const options = parseAccountDeletionArguments(process.argv.slice(2));
    if (options === 'help') { console.log(HELP); return; }
    const report = await completeAccountDeletionsFromEnvironment(process.env, options);
    console.log(JSON.stringify(report));
    if (report.databaseFailure || report.failed > 0) process.exitCode = 1;
  }).catch(() => {
    console.error('Account-deletion worker failed. Check arguments, operator configuration and pending-job storage. No credentials or provider details were logged.');
    process.exitCode = 1;
  });
}
