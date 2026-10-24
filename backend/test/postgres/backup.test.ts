import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { after, before, beforeEach, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { captureDatabaseBackup, restoreDatabaseBackup, validateDatabaseBackup, DatabaseBackupError } from '../../src/storage/database-backup.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { PostgresLifecycleMaintenance } from '../../src/storage/lifecycle-maintenance.ts';
import { AccountClosedError } from '../../src/lifecycle/types.ts';
import { OWNER, OTHER, FORM_CONTEXT, create, draft, answerInput, imageInput, iso, packetInput, publication } from './fixtures.ts';

const ORIGIN = 'https://fictional-project.supabase.co';
const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const CLOSED_OWNER = 'fictional-closed-owner';
const PREVIEW_OWNER = 'fictional-preview-owner';
const PRIVATE_TABLES = ['cases', 'matches', 'packets', 'form_answers', 'evidence', 'exports', 'request_history',
  'deleted_cases', 'closed_accounts', 'account_deletion_previews', 'auth_deletion_jobs'];
let source: TestPostgres, target: TestPostgres, sourceAdmin: Pool, targetAdmin: Pool, sourceRuntime: Pool;
let targetRuntime: Pool, sourceOperator: Pool, repo: PostgresCaseRepository;

before(async () => {
  [source, target] = await Promise.all([TestPostgres.start(), TestPostgres.start()]);
  sourceAdmin = source.pool(); targetAdmin = target.pool();
  await Promise.all([applyMigrations(sourceAdmin), applyMigrations(targetAdmin)]);
  for (const pool of [sourceAdmin, targetAdmin]) await pool.query(`CREATE ROLE backup_runtime LOGIN
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app`);
  await sourceAdmin.query(`CREATE ROLE backup_operator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS IN ROLE sah_test_admin`);
  sourceRuntime = source.pool('backup_runtime'); targetRuntime = target.pool('backup_runtime');
  sourceOperator = source.pool('backup_operator'); repo = new PostgresCaseRepository(sourceRuntime);
});
beforeEach(async () => {
  await Promise.all([sourceAdmin, targetAdmin].map(pool => pool.query(`TRUNCATE ${PRIVATE_TABLES.map(name => `safeathome_private.${name}`).join(',')};
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`)));
});
after(async () => { await Promise.all([source?.close(), target?.close()]); });

async function filled() {
  let snapshot = await create(repo);
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot))).status, 'saved');
  snapshot = (await repo.loadForUser(OWNER, snapshot.caseId))!;
  const photo = await imageInput(snapshot);
  assert.equal((await repo.saveEvidenceIfCurrent(photo)).status, 'saved');
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot, 1, 'fictional-photo-b'))).status, 'saved');
  assert.equal((await repo.deleteEvidenceIfCurrent({ userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision,
    expectedCatalogRevision: 2, evidenceId: 'fictional-photo-b', expectedEvidenceRevision: 1 })).status, 'deleted');
  const packet = packetInput(snapshot), exported = await publication(repo, snapshot, 3);
  assert.equal((await repo.createPacketIfCurrent(packet)).status, 'saved');
  assert.equal((await repo.publishExportIfCurrent(exported)).status, 'saved');
  await repo.saveMatchIfCurrent(OWNER, snapshot.caseId, snapshot.revision, { schemaVersion: '1', caseId: snapshot.caseId,
    caseRevision: snapshot.revision, evaluatedAt: iso(), evaluationDate: iso().slice(0, 10), matches: [] });
  const update = { updateId: randomUUID(), status: 'preparing' as const, occurredOn: iso().slice(0, 10),
    source: 'self_report' as const, note: 'Fictional private request note.', nextAction: null, responsibleParty: null, followUpOn: null };
  assert.equal((await repo.appendRequestUpdateForUser({ userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision,
    programId: FORM_CONTEXT.programId, expectedRequestRevision: 0, update, recordedAt: iso() })).status, 'found');
  const deleted = await create(repo, OTHER);
  await repo.deleteCaseIfCurrent({ userId: OTHER, caseId: deleted.caseId, revision: deleted.revision, expectedCatalogRevision: 0 });
  await create(repo, CLOSED_OWNER); const receiptHash = digest(randomUUID());
  await repo.prepareAccountDeletion({ userId: CLOSED_OWNER, tokenHash: receiptHash });
  await repo.confirmAccountDeletion({ userId: CLOSED_OWNER, tokenHash: receiptHash });
  await new PostgresLifecycleMaintenance(sourceAdmin).claimAuthDeletionJobs(1);
  await create(repo, PREVIEW_OWNER);
  await repo.prepareAccountDeletion({ userId: PREVIEW_OWNER, tokenHash: digest(randomUUID()) });
  return { snapshot, photo, packet, exported, update, deleted, receiptHash };
}
function change(archive: Buffer, mutate: (value: any) => void): Buffer {
  const value = JSON.parse(archive.toString('utf8')); mutate(value); return Buffer.from(JSON.stringify(value));
}
async function assertEmpty() {
  for (const name of PRIVATE_TABLES) assert.equal((await targetAdmin.query(`SELECT count(*) AS count FROM safeathome_private.${name}`)).rows[0].count, '0');
  assert.deepEqual((await targetAdmin.query('SELECT * FROM safeathome_private.repository_quota')).rows[0],
    { singleton: true, case_count: '0', asset_count: '0', artifact_count: '0', stored_bytes: '0' });
}

test('quarantine roundtrip retains current case, PNG, answers, history and tombstones while clearing derived capabilities', async () => {
  const fixture = await filled();
  const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  const summary = await validateDatabaseBackup(archive, ORIGIN);
  assert.equal(summary.sourceRows.cases, 2); assert.equal(summary.sourceRows.evidence, 2);
  assert.equal(summary.sourceRows.deleted_cases, 2); assert.equal(summary.sourceRows.request_history, 1);
  const report = await restoreDatabaseBackup(targetAdmin, archive, ORIGIN);
  assert.equal(report.quarantined, true);
  assert.deepEqual(report.cleared, { matches: 1, packetPayloads: 1, exportPayloads: 1, previews: 1, receiptCapabilities: 1, workerLeases: 1 });
  assert.equal(report.storedBytes, fixture.photo.image.byteLength);
  assert.equal(JSON.stringify(report).includes(fixture.snapshot.caseId), false);
  const restored = new PostgresCaseRepository(targetRuntime);
  assert.deepEqual(await restored.loadForUser(OWNER, fixture.snapshot.caseId), fixture.snapshot);
  assert.equal(await restored.loadForUser(OTHER, fixture.snapshot.caseId), null);
  assert.deepEqual(await restored.loadFormAnswersForUser(OWNER, fixture.snapshot.caseId, FORM_CONTEXT.programId),
    await repo.loadFormAnswersForUser(OWNER, fixture.snapshot.caseId, FORM_CONTEXT.programId));
  const historyInput = { userId: OWNER, caseId: fixture.snapshot.caseId, revision: fixture.snapshot.revision, programId: FORM_CONTEXT.programId };
  assert.deepEqual(await restored.readRequestHistoryForUser(historyInput), await repo.readRequestHistoryForUser(historyInput));
  const rows = (await targetAdmin.query('SELECT evidence_id,revision,bytes,descriptor FROM safeathome_private.evidence ORDER BY evidence_id')).rows;
  assert.deepEqual(rows[0].bytes, Buffer.from(fixture.photo.image.bytes));
  assert.equal(rows[1].revision, '2'); assert.equal(rows[1].descriptor, null); assert.equal(rows[1].bytes, null);
  assert.equal((await targetAdmin.query('SELECT catalog_revision FROM safeathome_private.cases WHERE case_id=$1', [fixture.snapshot.caseId])).rows[0].catalog_revision, '3');
  assert.equal((await restored.createForUser(OTHER, draft(fixture.deleted.caseId))).status, 'id_unavailable');
  await assert.rejects(restored.loadForUser(CLOSED_OWNER, fixture.snapshot.caseId), AccountClosedError);
  assert.equal(await restored.readAccountDeletionReceipt(fixture.receiptHash), null);
  const job = (await targetAdmin.query('SELECT raw_user_id,completed_at,lease_token,lease_until FROM safeathome_private.auth_deletion_jobs')).rows[0];
  assert.deepEqual(job, { raw_user_id: CLOSED_OWNER, completed_at: null, lease_token: null, lease_until: null });
  assert.equal((await restored.createPacketIfCurrent(fixture.packet)).status, 'generation_conflict');
  assert.equal((await restored.publishExportIfCurrent(fixture.exported)).status, 'generation_conflict');
  assert.deepEqual((await targetAdmin.query('SELECT * FROM safeathome_private.repository_quota')).rows[0], {
    singleton: true, case_count: '2', asset_count: '2', artifact_count: '0', stored_bytes: String(fixture.photo.image.byteLength),
  });
  assert.equal((await sourceAdmin.query('SELECT count(bytes) AS count FROM safeathome_private.exports')).rows[0].count, '1');
  assert.equal((await sourceAdmin.query('SELECT count(lease_token) AS count FROM safeathome_private.auth_deletion_jobs')).rows[0].count, '1');
});

test('empty database is a legitimate complete archive and restore target cannot be reused', async () => {
  const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  assert.equal((await restoreDatabaseBackup(targetAdmin, archive, ORIGIN)).storedBytes, 0);
  await create(new PostgresCaseRepository(targetRuntime));
  await assert.rejects(restoreDatabaseBackup(targetAdmin, archive, ORIGIN), DatabaseBackupError);
  assert.equal((await targetAdmin.query('SELECT count(*) AS count FROM safeathome_private.cases')).rows[0].count, '1');
});

test('runtime role cannot produce a misleading RLS-filtered empty backup', async () => {
  await create(repo);
  await assert.rejects(captureDatabaseBackup(sourceRuntime, ORIGIN), DatabaseBackupError);
});

test('non-bypass operator with exact inherited owner policies captures all owners', async () => {
  await create(repo); await create(repo, OTHER);
  const privileges = (await sourceOperator.query('SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user')).rows[0];
  assert.deepEqual(privileges, { rolsuper: false, rolbypassrls: false });
  const archive = await captureDatabaseBackup(sourceOperator, ORIGIN);
  assert.equal((await validateDatabaseBackup(archive, ORIGIN)).sourceRows.cases, 2);
});

test('applicable SELECT, UPDATE or DELETE restriction fails closed instead of filtering capture or cleanup', async () => {
  await create(repo);
  const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  await targetAdmin.query(`CREATE ROLE backup_operator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS IN ROLE sah_test_admin`);
  const targetOperator = target.pool('backup_operator');
  for (const command of ['SELECT', 'UPDATE', 'DELETE']) {
    await sourceAdmin.query(`CREATE POLICY backup_restrictive ON safeathome_private.cases
      AS RESTRICTIVE FOR ${command} TO backup_operator USING (false)`);
    await targetAdmin.query(`CREATE POLICY backup_restrictive ON safeathome_private.cases
      AS RESTRICTIVE FOR ${command} TO backup_operator USING (false)`);
    try {
      await assert.rejects(captureDatabaseBackup(sourceOperator, ORIGIN), DatabaseBackupError);
      await assert.rejects(restoreDatabaseBackup(targetOperator, archive, ORIGIN), DatabaseBackupError);
      await assertEmpty();
    } finally {
      await sourceAdmin.query('DROP POLICY backup_restrictive ON safeathome_private.cases');
      await targetAdmin.query('DROP POLICY backup_restrictive ON safeathome_private.cases');
    }
  }
});

test('unexpected table and disabled FORCE RLS make capture fail', async () => {
  await sourceAdmin.query('CREATE TABLE safeathome_private.unexpected_backup_test(value text)');
  try { await assert.rejects(captureDatabaseBackup(sourceAdmin, ORIGIN), DatabaseBackupError); }
  finally { await sourceAdmin.query('DROP TABLE safeathome_private.unexpected_backup_test'); }
  await sourceAdmin.query('ALTER TABLE safeathome_private.cases NO FORCE ROW LEVEL SECURITY');
  try { await assert.rejects(captureDatabaseBackup(sourceAdmin, ORIGIN), DatabaseBackupError); }
  finally { await sourceAdmin.query('ALTER TABLE safeathome_private.cases FORCE ROW LEVEL SECURITY'); }
});

test('provenance, version, checksum and table manifest are validated before any restore connection', async () => {
  const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  let connects = 0;
  const neverConnect = { connect: async () => { connects++; throw new Error('No connection expected.'); } } as unknown as Pool;
  const variants = [
    change(archive, value => { value.projectOrigin = 'https://different-project.supabase.co'; }),
    change(archive, value => { value.format = 'unknown'; }),
    change(archive, value => { value.migrations[0].checksum = '0'.repeat(64); }),
    change(archive, value => { delete value.tables.closed_accounts; }),
    change(archive, value => { value.tables.auth_users = []; }),
    change(archive, value => { value.tables.cases = Array.from({ length: 10001 }, () => ({})); }),
  ];
  for (const invalid of variants) await assert.rejects(restoreDatabaseBackup(neverConnect, invalid, ORIGIN), DatabaseBackupError);
  assert.equal(connects, 0);
});

test('binary, quota and supposedly discardable derived records are validated', async () => {
  await filled(); const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  const variants = [
    change(archive, value => { value.tables.evidence[0].bytes = Buffer.from('not-a-private-image').toString('base64'); }),
    change(archive, value => { value.tables.repository_quota[0].stored_bytes = '0'; }),
    change(archive, value => { value.tables.matches[0].response = null; }),
    change(archive, value => { value.tables.packets[0].packet = []; }),
    change(archive, value => { value.tables.exports[0].metadata.byteLength++; }),
    change(archive, value => { value.tables.exports[0].bindings.userId = OTHER; }),
    change(archive, value => { value.tables.auth_deletion_jobs[0].raw_user_id = OTHER; }),
    change(archive, value => { value.tables.request_history[0].record.events[0].updateId = 'not a valid update ID'; }),
  ];
  for (const invalid of variants) await assert.rejects(restoreDatabaseBackup(targetAdmin, invalid, ORIGIN), DatabaseBackupError);
  await assertEmpty();
});

test('archive cannot contain active case data conflicting with its own deletion or closure markers', async () => {
  const fixture = await filled(); const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  for (const invalid of [
    change(archive, value => { value.tables.deleted_cases[0].case_hash = digest(fixture.snapshot.caseId); }),
    change(archive, value => { value.tables.closed_accounts[0].owner_hash = digest(OWNER); }),
  ]) await assert.rejects(restoreDatabaseBackup(targetAdmin, invalid, ORIGIN), DatabaseBackupError);
  await assertEmpty();
});

test('late SQL failure rolls back every restored table and quota without private error details', async () => {
  await filled(); const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  await targetAdmin.query(`CREATE FUNCTION safeathome_private.fail_backup_test() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'PRIVATE FICTIONAL RECORD'; END $$;
    CREATE TRIGGER fail_backup_test BEFORE INSERT ON safeathome_private.request_history
    FOR EACH ROW EXECUTE FUNCTION safeathome_private.fail_backup_test()`);
  try { await assert.rejects(restoreDatabaseBackup(targetAdmin, archive, ORIGIN), error => {
    assert.ok(error instanceof DatabaseBackupError); assert.equal(error.message.includes('PRIVATE'), false); return true;
  }); }
  finally { await targetAdmin.query('DROP TRIGGER fail_backup_test ON safeathome_private.request_history; DROP FUNCTION safeathome_private.fail_backup_test()'); }
  await assertEmpty();
});

test('capture uses one repeatable snapshot even when a case commits after its first table read', async () => {
  const first = await create(repo); let inserted = false;
  const wrapped = { connect: async () => {
    const client = await sourceAdmin.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      const result = await client.query(sql, values);
      if (!inserted && sql.startsWith('SELECT singleton,case_count')) { inserted = true; await create(repo, OTHER); }
      return result;
    } };
  } } as unknown as Pool;
  const archive = await captureDatabaseBackup(wrapped, ORIGIN);
  assert.equal(inserted, true); assert.equal((await validateDatabaseBackup(archive, ORIGIN)).sourceRows.cases, 1);
  await restoreDatabaseBackup(targetAdmin, archive, ORIGIN);
  assert.deepEqual(await new PostgresCaseRepository(targetRuntime).loadForUser(OWNER, first.caseId), first);
  assert.equal((await sourceAdmin.query('SELECT count(*) AS count FROM safeathome_private.cases')).rows[0].count, '2');
});

test('cancellation during restore rolls back already inserted private rows', async () => {
  await filled(); const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  const controller = new AbortController();
  const wrapped = { connect: async () => {
    const client = await targetAdmin.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      const result = await client.query(sql, values);
      if (sql.startsWith('INSERT INTO safeathome_private.cases')) controller.abort();
      return result;
    } };
  } } as unknown as Pool;
  await assert.rejects(restoreDatabaseBackup(wrapped, archive, ORIGIN, controller.signal), DatabaseBackupError);
  await assertEmpty();
});

test('completed identity jobs remain completed with no raw target or usable receipts', async () => {
  await create(repo, CLOSED_OWNER); const tokenHash = digest(randomUUID());
  await repo.prepareAccountDeletion({ userId: CLOSED_OWNER, tokenHash });
  await repo.confirmAccountDeletion({ userId: CLOSED_OWNER, tokenHash });
  const maintenance = new PostgresLifecycleMaintenance(sourceAdmin);
  const [job] = await maintenance.claimAuthDeletionJobs(1);
  assert.equal(await maintenance.finishAuthDeletionJob({ ...job, outcome: 'deleted' }), true);
  await restoreDatabaseBackup(targetAdmin, await captureDatabaseBackup(sourceAdmin, ORIGIN), ORIGIN);
  assert.equal(await new PostgresLifecycleMaintenance(targetAdmin).pendingAuthDeletionCount(), 0);
  const restored = (await targetAdmin.query('SELECT raw_user_id,completed_at,lease_token FROM safeathome_private.auth_deletion_jobs')).rows[0];
  assert.equal(restored.raw_user_id, null); assert.notEqual(restored.completed_at, null); assert.equal(restored.lease_token, null);
});

test('maximum 32 MiB PDF payload backs up without regex stack overflow and is cleared on restore', async () => {
  const snapshot = await create(repo);
  await repo.saveEvidenceIfCurrent(await imageInput(snapshot));
  const input = await publication(repo, snapshot);
  const body = Buffer.alloc(32 * 1024 * 1024, 32); body.write('%PDF-1.7\n');
  input.artifact.bytes = body;
  input.artifact.metadata.byteLength = body.length;
  input.artifact.metadata.sha256 = createHash('sha256').update(body).digest('hex');
  assert.equal((await repo.publishExportIfCurrent(input)).status, 'saved');
  const archive = await captureDatabaseBackup(sourceAdmin, ORIGIN);
  assert.ok(archive.length > 40 * 1024 * 1024);
  const report = await restoreDatabaseBackup(targetAdmin, archive, ORIGIN);
  assert.equal(report.cleared.exportPayloads, 1);
  assert.deepEqual((await targetAdmin.query('SELECT bytes,metadata,bindings,invalidated FROM safeathome_private.exports')).rows[0],
    { bytes: null, metadata: null, bindings: null, invalidated: true });
  const malformed = change(archive, value => { value.tables.exports[0].bytes = `=${value.tables.exports[0].bytes.slice(1)}`; });
  await assert.rejects(validateDatabaseBackup(malformed, ORIGIN), DatabaseBackupError);
});
