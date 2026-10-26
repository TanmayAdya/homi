import { pathToFileURL } from 'node:url';
import type { Pool } from 'pg';
import { readCapacityReport } from '../src/storage/capacity-report.ts';
import { readOperationsReport } from '../src/storage/operations-report.ts';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';

const HELP = `Usage: node tool/operations.ts [--help]
Default: one read-only check of application capacity, retention execution and the Auth-deletion queue.
Use the existing private operator database configuration, never the API runtime login.
Output contains aggregate counts/ages only. Each component has its own snapshot timestamp.
Exit 0: no monitored warning; exit 2: operator attention; exit 1: check unavailable/invalid.
This command never runs cleanup or Auth deletion, installs a schedule, calls Railway or sends alerts.
Provider billing, backup freshness, hosted memory and mobile readiness are not checked.`;

export function parseOperationsArguments(args: readonly string[]): 'report' | 'help' {
  if (args.length === 0) return 'report';
  if (args.length === 1 && args[0] === '--help') return 'help';
  throw new TypeError('Invalid operations arguments. Use --help.');
}

export function summarizeOperationsWarnings(capacity: readonly string[], lifecycle: readonly string[]) {
  const warnings = [...new Set([
    ...capacity.map(warning => `capacity.${warning}`),
    ...lifecycle.map(warning => `lifecycle.${warning}`),
  ])];
  return {
    status: warnings.length === 0 ? 'no_monitored_warning' as const : 'attention_required' as const,
    exitCode: warnings.length === 0 ? 0 as const : 2 as const,
    warnings,
  };
}

export async function readOperationsHealth(pool: Pool) {
  const capacity = await readCapacityReport(pool);
  const lifecycle = await readOperationsReport(pool);
  return {
    schemaVersion: '1' as const,
    mode: 'read_only' as const,
    scope: 'database_operations' as const,
    componentsShareSnapshot: false,
    ...summarizeOperationsWarnings(capacity.warnings, lifecycle.warnings),
    capacity,
    lifecycle,
    notChecked: ['provider_billable_usage', 'provider_identity_absence', 'backup_freshness_and_off_device_copies',
      'hosted_worst_case_memory', 'mobile_acceptance', 'automatic_auth_worker_execution'],
  };
}

async function main() {
  if (parseOperationsArguments(process.argv.slice(2)) === 'help') { console.log(HELP); return; }
  const pool = createPostgresPool(await databaseConfigurationFromEnvironment(process.env, 'migration'));
  try {
    const report = await readOperationsHealth(pool);
    console.log(JSON.stringify(report));
    process.exitCode = report.exitCode;
  } finally { await pool.end(); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(() => {
    console.error('Operations check failed. Check operator configuration, migrations and complete metadata visibility. No credentials or database details were logged.');
    process.exitCode = 1;
  });
}
