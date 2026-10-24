import { dirname, isAbsolute, normalize } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createBackupKey, readBackupKey, writeBackupArchive, readBackupArchive,
  sealBackup, openBackup } from '../src/storage/backup-archive.ts';
import { captureDatabaseBackup, restoreDatabaseBackup, validateDatabaseBackup } from '../src/storage/database-backup.ts';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';
import { applyMigrations } from '../src/storage/migrate.ts';
import { DisposablePostgres } from './disposable-postgres.ts';

const HELP = `Usage:
  node tool/backup.ts key --key /private/key-directory/recovery.key
  node tool/backup.ts create --key /private/key-directory/recovery.key --archive /private/backup-directory/snapshot.sah-backup --project https://PROJECT.supabase.co
  node tool/backup.ts drill --key /private/key-directory/recovery.key --archive /private/backup-directory/snapshot.sah-backup --project https://PROJECT.supabase.co
Use existing owner-only (0700) directories, separate key/archive directories and absolute paths without symlinks.
create reads only the configured migration database, which must match the project.
drill never connects to that database: it creates, tests and removes a new private Unix-socket PostgreSQL cluster.
Set SAFEATHOME_RESTORE_PG_BIN to trusted local PostgreSQL executables for drill.
Archives exclude Auth identities/configuration. No live restore, promotion or provider deletion is performed.`;

export type BackupArguments = { action: 'help' } | { action: 'key'; key: string }
  | { action: 'create' | 'drill'; key: string; archive: string; project: string };

function privatePath(value: string, suffix: string): boolean {
  return isAbsolute(value) && normalize(value) === value && !/[\u0000-\u001f\u007f]/.test(value)
    && value.length <= 4096 && value.endsWith(suffix);
}

export function parseBackupArguments(args: readonly string[]): BackupArguments {
  if (args.length === 0 || (args.length === 1 && args[0] === '--help')) return { action: 'help' };
  const [action, ...rest] = args;
  if (!['key', 'create', 'drill'].includes(action) || rest.length % 2) throw new TypeError('Invalid backup arguments. Use --help.');
  const options = new Map<string, string>();
  for (let i = 0; i < rest.length; i += 2) {
    if (!['--key', '--archive', '--project'].includes(rest[i]) || options.has(rest[i])) throw new TypeError('Invalid backup arguments.');
    options.set(rest[i], rest[i + 1]);
  }
  const key = options.get('--key') ?? '';
  if (!privatePath(key, '.key')) throw new TypeError('An absolute private .key path is required.');
  if (action === 'key' && options.size === 1) return { action, key };
  if (action === 'key' || options.size !== 3) throw new TypeError('Invalid backup arguments.');
  const archive = options.get('--archive') ?? '';
  const project = options.get('--project') ?? '';
  if (!privatePath(archive, '.sah-backup') || dirname(key) === dirname(archive)
    || !/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(project)) throw new TypeError('Invalid backup paths or project origin.');
  return { action: action as 'create' | 'drill', key, archive, project };
}

export function assertBackupSource(connectionString: string, configuredProject: string | undefined, expectedProject: string): void {
  const url = new URL(connectionString);
  const ref = new URL(expectedProject).hostname.split('.')[0];
  const direct = url.hostname === `db.${ref}.supabase.co` && decodeURIComponent(url.username) === 'postgres';
  const pooler = /^aws-[0-9]+-[a-z0-9-]+\.pooler\.supabase\.com$/.test(url.hostname)
    && decodeURIComponent(url.username) === `postgres.${ref}`;
  if (configuredProject !== expectedProject || (!direct && !pooler) || url.pathname !== '/postgres') {
    throw new TypeError('Backup source does not match the configured project.');
  }
}

export async function runBackup(args: BackupArguments, signal?: AbortSignal): Promise<void> {
  signal?.throwIfAborted();
  if (args.action === 'help') { console.log(HELP); return; }
  if (args.action === 'key') {
    await createBackupKey(args.key);
    console.log(JSON.stringify({ mode: 'key', created: true, keyPrinted: false }));
    return;
  }
  const key = await readBackupKey(args.key);
  let plaintext: Buffer | undefined;
  try {
    if (args.action === 'create') {
      const config = await databaseConfigurationFromEnvironment(process.env, 'migration');
      assertBackupSource(config.connectionString, process.env.SAFEATHOME_SUPABASE_URL, args.project);
      const pool = createPostgresPool(config);
      try { plaintext = await captureDatabaseBackup(pool, args.project, signal); }
      finally { await pool.end(); }
      signal?.throwIfAborted();
      const summary = await validateDatabaseBackup(plaintext!, args.project);
      const archive = sealBackup(plaintext!, key);
      signal?.throwIfAborted();
      await writeBackupArchive(args.archive, archive);
      console.log(JSON.stringify({ mode: 'create', encrypted: true, archiveBytes: archive.length, ...summary }));
    } else {
      plaintext = openBackup(await readBackupArchive(args.archive), key);
      await validateDatabaseBackup(plaintext, args.project);
      signal?.throwIfAborted();
      const cluster = await DisposablePostgres.start(process.env.SAFEATHOME_RESTORE_PG_BIN ?? '');
      let report;
      try {
        signal?.throwIfAborted();
        const pool = cluster.pool(undefined, 'safeathome-restore-drill');
        await applyMigrations(pool);
        report = await restoreDatabaseBackup(pool, plaintext, args.project, signal);
      } finally { await cluster.close(); }
      signal?.throwIfAborted();
      console.log(JSON.stringify({ mode: 'drill', ...report, isolatedDatabaseRemoved: true, liveRestore: false }));
    }
  } finally { key.fill(0); plaintext?.fill(0); }
}

export async function backupMain(args: readonly string[]): Promise<void> {
  const controller = new AbortController();
  let exitCode: number | undefined;
  const interrupt = () => { exitCode ??= 130; controller.abort(); };
  const terminate = () => { exitCode ??= 143; controller.abort(); };
  process.on('SIGINT', interrupt);
  process.on('SIGTERM', terminate);
  try { await runBackup(parseBackupArguments(args), controller.signal); }
  finally {
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', terminate);
    if (exitCode !== undefined) process.exitCode = exitCode;
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  backupMain(process.argv.slice(2)).catch(() => {
    console.error('Backup operation failed. Check arguments, private file permissions, project/operator configuration and local PostgreSQL tools. No private contents or database details were logged.');
    process.exitCode ||= 1;
  });
}
