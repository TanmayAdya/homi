import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import type { Pool } from 'pg';
import { createPostgresPool, databaseConfigurationFromEnvironment } from './postgres-pool.ts';

const migrations = [
  { version: '001', file: new URL('../../migrations/001_private_repository.sql', import.meta.url) },
  { version: '002', file: new URL('../../migrations/002_retention_deletion.sql', import.meta.url) },
  { version: '003', file: new URL('../../migrations/003_request_tracking.sql', import.meta.url) },
];
export class MigrationError extends Error {
  constructor() { super('Database migrations are missing, changed, or could not be applied.'); this.name = 'MigrationError'; }
}

async function sources() {
  return Promise.all(migrations.map(async migration => {
    const sql = await readFile(migration.file, 'utf8');
    return { ...migration, sql, checksum: createHash('sha256').update(sql).digest('hex') };
  }));
}

export async function applyMigrations(pool: Pool): Promise<void> {
  try { await applyMigrationSteps(pool); } catch { throw new MigrationError(); }
}

async function applyMigrationSteps(pool: Pool): Promise<void> {
  const scripts = await sources();
  const client = await pool.connect();
  let discard = false;
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(1935763045, 1)');
    await client.query(`CREATE SCHEMA IF NOT EXISTS safeathome_migrations;
      REVOKE ALL ON SCHEMA safeathome_migrations FROM PUBLIC;
      CREATE TABLE IF NOT EXISTS safeathome_migrations.versions (
        version text PRIMARY KEY, checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
      );
      REVOKE ALL ON safeathome_migrations.versions FROM PUBLIC;`);
    const installed = await client.query<{ version: string; checksum: string }>(
      'SELECT version, checksum FROM safeathome_migrations.versions ORDER BY version');
    if (installed.rows.some((row, index) => scripts[index]?.version !== row.version || scripts[index]?.checksum !== row.checksum)) {
      throw new MigrationError();
    }
    for (const script of scripts.slice(installed.rows.length)) {
      await client.query(script.sql);
      await client.query('INSERT INTO safeathome_migrations.versions(version,checksum) VALUES ($1,$2)', [script.version, script.checksum]);
    }
    await client.query(`GRANT USAGE ON SCHEMA safeathome_migrations TO safeathome_app;
      GRANT SELECT ON safeathome_migrations.versions TO safeathome_app;`);
    await client.query('COMMIT');
  } catch {
    try { await client.query('ROLLBACK'); } catch { discard = true; }
    throw new MigrationError();
  } finally { client.release(discard); }
}

export async function assertMigrationsCurrent(pool: Pick<Pool, 'query'>): Promise<void> {
  try {
    const expected = await sources();
    const result = await pool.query<{ version: string; checksum: string }>(
      'SELECT version, checksum FROM safeathome_migrations.versions ORDER BY version');
    if (result.rows.length !== expected.length || result.rows.some((row, index) =>
      row.version !== expected[index].version || row.checksum !== expected[index].checksum)) throw new MigrationError();
  } catch { throw new MigrationError(); }
}

async function main() {
  if (process.argv.length !== 2) throw new MigrationError();
  const pool = createPostgresPool(await databaseConfigurationFromEnvironment(process.env, 'migration'));
  try {
    await applyMigrations(pool);
    console.log('PASS: private database migrations are current.');
  } finally { await pool.end(); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(() => {
    console.error('Migration failed. Check the dedicated migration connection, database privileges and migration files. No credentials or database details were logged.');
    process.exitCode = 1;
  });
}
