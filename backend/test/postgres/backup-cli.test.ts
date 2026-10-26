import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, realpath, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { backupMain, runBackup } from '../../tool/backup.ts';
import { DisposablePostgres } from '../../tool/disposable-postgres.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { captureDatabaseBackup } from '../../src/storage/database-backup.ts';
import { createBackupKey, readBackupKey, sealBackup, writeBackupArchive } from '../../src/storage/backup-archive.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { create } from './fixtures.ts';

const project = 'https://abcdefghijklmnopqrst.supabase.co';
let directory: string, keyPath: string, archivePath: string;
const originalBin = process.env.SAFEATHOME_RESTORE_PG_BIN;
before(async () => {
  directory = await mkdtemp(join(await realpath('/tmp'), 'sah-backup-cli-'));
  await chmod(directory, 0o700);
  await mkdir(join(directory, 'keys'), { mode: 0o700 });
  await mkdir(join(directory, 'archives'), { mode: 0o700 });
  keyPath = join(directory, 'keys', 'fictional.key');
  archivePath = join(directory, 'archives', 'fictional.sah-backup');
  await createBackupKey(keyPath);
  const source = await DisposablePostgres.start();
  try {
    const pool = source.pool();
    await applyMigrations(pool);
    await create(new PostgresCaseRepository(pool));
    const key = await readBackupKey(keyPath);
    try { await writeBackupArchive(archivePath, sealBackup(await captureDatabaseBackup(pool, project), key)); }
    finally { key.fill(0); }
    process.env.SAFEATHOME_RESTORE_PG_BIN = source.bin;
  } finally { await source.close(); }
});
after(async () => {
  if (originalBin === undefined) delete process.env.SAFEATHOME_RESTORE_PG_BIN;
  else process.env.SAFEATHOME_RESTORE_PG_BIN = originalBin;
  if (directory) await rm(directory, { recursive: true, force: true });
});

test('encrypted CLI drill restores in a disposable database, reports aggregates and removes it', async t => {
  const start = DisposablePostgres.start.bind(DisposablePostgres);
  let clusterPath: string | undefined;
  t.mock.method(DisposablePostgres, 'start', async (bin: string) => {
    const cluster = await start(bin); clusterPath = cluster.directory; return cluster;
  });
  const output: string[] = [];
  t.mock.method(console, 'log', (line: string) => output.push(line));
  const previous = process.env.SAFEATHOME_MIGRATION_DATABASE_URL;
  process.env.SAFEATHOME_MIGRATION_DATABASE_URL = 'postgres://do-not-connect.invalid/production';
  try { await runBackup({ action: 'drill', key: keyPath, archive: archivePath, project }); }
  finally {
    if (previous === undefined) delete process.env.SAFEATHOME_MIGRATION_DATABASE_URL;
    else process.env.SAFEATHOME_MIGRATION_DATABASE_URL = previous;
  }
  assert.equal(output.length, 1);
  const report = JSON.parse(output[0]);
  assert.equal(report.sourceRows.cases, 1);
  assert.equal(report.restoredRows.cases, 1);
  assert.equal(report.quarantined, true);
  assert.equal(report.isolatedDatabaseRemoved, true);
  assert.equal(report.liveRestore, false);
  assert.equal(output[0].includes('fictional-alice'), false);
  assert.ok(clusterPath);
  await assert.rejects(stat(clusterPath), { code: 'ENOENT' });
});

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  test(`${signal} after startup cleans the owned cluster before returning failure`, async t => {
    const start = DisposablePostgres.start.bind(DisposablePostgres);
    let clusterPath: string | undefined;
    t.mock.method(DisposablePostgres, 'start', async (bin: string) => {
      const cluster = await start(bin); clusterPath = cluster.directory;
      process.emit(signal); return cluster;
    });
    const previousCode = process.exitCode;
    const beforeListeners = process.listenerCount(signal);
    try {
      await assert.rejects(backupMain(['drill', '--key', keyPath, '--archive', archivePath, '--project', project]));
      assert.equal(process.exitCode, signal === 'SIGINT' ? 130 : 143);
      assert.equal(process.listenerCount(signal), beforeListeners);
      assert.ok(clusterPath);
      await assert.rejects(stat(clusterPath), { code: 'ENOENT' });
    } finally { process.exitCode = previousCode; }
  });
}

test('wrong project is rejected before creating any database', async t => {
  let starts = 0;
  t.mock.method(DisposablePostgres, 'start', () => { starts++; throw new Error('must not start'); });
  await assert.rejects(runBackup({ action: 'drill', key: keyPath, archive: archivePath,
    project: 'https://aaaaaaaaaaaaaaaaaaaa.supabase.co' }));
  assert.equal(starts, 0);
});
