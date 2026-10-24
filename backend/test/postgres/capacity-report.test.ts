import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { after, before, beforeEach, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { readCapacityReport, CapacityReportError } from '../../src/storage/capacity-report.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { CAPACITY_LIMITS } from '../../src/storage/capacity-limits.ts';
import { OWNER, OTHER, FORM_CONTEXT, create, draft, answerInput, imageInput, iso, packetInput, publication } from './fixtures.ts';

const PRIVATE_TABLES = ['cases', 'matches', 'packets', 'form_answers', 'evidence', 'exports', 'request_history',
  'deleted_cases', 'closed_accounts', 'account_deletion_previews', 'auth_deletion_jobs'];
let cluster: TestPostgres, admin: Pool, operator: Pool, runtime: Pool, repo: PostgresCaseRepository;
const digest = (value: string) => createHash('sha256').update(value).digest('hex');

before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query(`CREATE ROLE capacity_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app;
    CREATE ROLE capacity_operator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE sah_test_admin`);
  operator = cluster.pool('capacity_operator'); runtime = cluster.pool('capacity_runtime'); repo = new PostgresCaseRepository(runtime);
});
beforeEach(async () => {
  await admin.query(`TRUNCATE ${PRIVATE_TABLES.map(name => `safeathome_private.${name}`).join(',')};
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await cluster?.close(); });

async function populated() {
  let snapshot = await create(repo); await create(repo, OTHER);
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot))).status, 'saved');
  snapshot = (await repo.loadForUser(OWNER, snapshot.caseId))!;
  const photo = await imageInput(snapshot);
  assert.equal((await repo.saveEvidenceIfCurrent(photo)).status, 'saved');
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot, 1, 'fictional-photo-b'))).status, 'saved');
  assert.equal((await repo.deleteEvidenceIfCurrent({ userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision,
    expectedCatalogRevision: 2, evidenceId: 'fictional-photo-b', expectedEvidenceRevision: 1 })).status, 'deleted');
  assert.equal((await repo.createPacketIfCurrent(packetInput(snapshot))).status, 'saved');
  assert.equal((await repo.publishExportIfCurrent(await publication(repo, snapshot, 3))).status, 'saved');
  const { revision, ...unchanged } = snapshot;
  const saved = await repo.replaceIfCurrent(OWNER, snapshot.caseId, revision, unchanged);
  assert.equal(saved.status, 'saved'); if (saved.status !== 'saved') throw new Error('Fictional case update failed.');
  snapshot = saved.snapshot;
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot, 1))).status, 'saved');
  snapshot = (await repo.loadForUser(OWNER, snapshot.caseId))!;
  assert.equal((await repo.createPacketIfCurrent(packetInput(snapshot))).status, 'saved');
  const pdf = await publication(repo, snapshot, 3);
  assert.equal((await repo.publishExportIfCurrent(pdf)).status, 'saved');
  assert.equal((await repo.appendRequestUpdateForUser({ userId: OWNER, caseId: snapshot.caseId,
    revision: snapshot.revision, programId: FORM_CONTEXT.programId, expectedRequestRevision: 0, recordedAt: iso(),
    update: { updateId: randomUUID(), status: 'preparing', occurredOn: iso().slice(0, 10), source: 'self_report',
      note: 'Private fictional request content.', nextAction: null, responsibleParty: null, followUpOn: null } })).status, 'found');
  const deleted = await create(repo, 'fictional-deleted-owner');
  assert.equal((await repo.deleteCaseIfCurrent({ userId: 'fictional-deleted-owner', caseId: deleted.caseId,
    revision: deleted.revision, expectedCatalogRevision: 0 })).status, 'deleted');
  await create(repo, 'fictional-closed-owner'); const tokenHash = digest(randomUUID());
  await repo.prepareAccountDeletion({ userId: 'fictional-closed-owner', tokenHash });
  await repo.confirmAccountDeletion({ userId: 'fictional-closed-owner', tokenHash });
  await repo.prepareAccountDeletion({ userId: OTHER, tokenHash: digest(randomUUID()) });
  return { snapshot, photo, pdf };
}

test('operator sees aggregate data across owners, retained identities, private bytes and operational work without exposing content', async () => {
  const fixture = await populated();
  const report = await readCapacityReport(operator);
  assert.equal(report.mode, 'read_only'); assert.equal(report.quota.consistent, true);
  assert.deepEqual(report.rows, { repository_quota: 1, cases: 2, matches: 0, packets: 2, form_answers: 1,
    evidence: 2, exports: 2, deleted_cases: 2, closed_accounts: 1, account_deletion_previews: 1,
    auth_deletion_jobs: 1, request_history: 1 });
  assert.deepEqual(report.payloads, { liveEvidence: 1, evidenceTombstones: 1, packetPayloads: 1, packetTombstones: 1,
    storedPdfPayloads: 1, expiredPdfPayloads: 0, exportTombstones: 1, pendingAuthDeletions: 1 });
  assert.deepEqual(report.maxima, { casesPerOwner: 1, evidencePerOwner: 2, packetsPerCase: 2, exportsPerCase: 2,
    answerSetsPerCase: 1, requestStreamsPerCase: 1, requestEventsPerStream: 1 });
  assert.deepEqual(report.quota.observed, { cases: 2, evidence: 2, activeExports: 1,
    binaryBytes: fixture.photo.image.byteLength + fixture.pdf.artifact.bytes.length });
  assert.deepEqual(report.warnings, ['auth_deletions_pending']);
  assert.deepEqual(report.limits, CAPACITY_LIMITS);
  assert.ok(report.physicalStorage.databaseBytes >= report.physicalStorage.privateRelationsBytes);
  assert.equal(report.physicalStorage.privateRelationsBytes,
    Object.values(report.physicalStorage.relationBytes).reduce((sum, bytes) => sum + bytes, 0));
  assert.equal(report.physicalStorage.providerBillableUsage, null);
  assert.equal(report.physicalStorage.providerLimitBytes, null);
  const encoded = JSON.stringify(report);
  for (const secret of [OWNER, OTHER, fixture.snapshot.caseId, fixture.pdf.artifact.metadata.artifactId,
    'Private fictional request content.', 'fictional-closed-owner']) assert.equal(encoded.includes(secret), false);
});

test('expired PDF is counted as stored bytes without triggering retention or changing any capability', async () => {
  const fixture = await populated();
  await admin.query(`UPDATE safeathome_private.exports SET expires_at=$2::timestamptz,
    metadata=jsonb_set(jsonb_set(metadata,'{expiresAt}',to_jsonb($2::text)),'{generatedAt}',to_jsonb($3::text))
    WHERE artifact_id=$1`, [fixture.pdf.artifact.metadata.artifactId, iso(-1000), iso(-2000)]);
  const before = (await admin.query('SELECT artifact_id,metadata,bindings,bytes,invalidated,expires_at FROM safeathome_private.exports ORDER BY artifact_id')).rows;
  const report = await readCapacityReport(operator);
  assert.equal(report.payloads.expiredPdfPayloads, 1); assert.equal(report.payloads.storedPdfPayloads, 1);
  assert.ok(report.warnings.includes('expired_pdf_payloads_pending_retention'));
  assert.deepEqual((await admin.query('SELECT artifact_id,metadata,bindings,bytes,invalidated,expires_at FROM safeathome_private.exports ORDER BY artifact_id')).rows, before);
  assert.equal(report.quota.consistent, true);
});

test('quota mismatch is a visible aggregate warning and is never silently repaired', async () => {
  await create(repo);
  await admin.query('UPDATE safeathome_private.repository_quota SET case_count=2,stored_bytes=17');
  const report = await readCapacityReport(operator);
  assert.equal(report.quota.consistent, false); assert.ok(report.warnings.includes('quota_mismatch'));
  assert.equal(report.quota.recorded.cases, 2); assert.equal(report.quota.observed.cases, 1);
  assert.equal(report.quota.recorded.binaryBytes, 17); assert.equal(report.quota.observed.binaryBytes, 0);
  assert.equal((await admin.query('SELECT stored_bytes FROM safeathome_private.repository_quota')).rows[0].stored_bytes, '17');
});

test('existing owner data at or above new admission limits stays visible, with per-owner maxima but no owner IDs', async () => {
  for (let index = 0; index < CAPACITY_LIMITS.casesPerOwner; index++) await create(repo);
  let report = await readCapacityReport(operator);
  assert.equal(report.maxima.casesPerOwner, CAPACITY_LIMITS.casesPerOwner);
  assert.ok(report.warnings.includes('casesPerOwner_at_or_above_limit'));
  const extra = draft();
  await admin.query(`INSERT INTO safeathome_private.cases(case_id,owner_id,revision,catalog_revision,snapshot)
    VALUES($1,$2,1,0,$3);`, [extra.caseId, OWNER, { ...extra, revision: 1 }]);
  await admin.query('UPDATE safeathome_private.repository_quota SET case_count=case_count+1');
  report = await readCapacityReport(operator);
  assert.equal(report.maxima.casesPerOwner, CAPACITY_LIMITS.casesPerOwner + 1);
  assert.equal(report.rows.cases, CAPACITY_LIMITS.casesPerOwner + 1); assert.equal(report.quota.consistent, true);
});

test('runtime role and applicable restrictive SELECT policy cannot produce misleading partial reports', async () => {
  await create(repo); await create(repo, OTHER);
  await assert.rejects(readCapacityReport(runtime), CapacityReportError);
  await admin.query(`CREATE POLICY capacity_hidden ON safeathome_private.cases AS RESTRICTIVE
    FOR SELECT TO capacity_operator USING (false)`);
  try { await assert.rejects(readCapacityReport(operator), CapacityReportError); }
  finally { await admin.query('DROP POLICY capacity_hidden ON safeathome_private.cases'); }
  assert.equal((await readCapacityReport(operator)).rows.cases, 2);
});

test('schema or security drift fails closed instead of presenting a complete capacity report', async () => {
  await admin.query('CREATE TABLE safeathome_private.capacity_unknown(value text)');
  try { await assert.rejects(readCapacityReport(admin), CapacityReportError); }
  finally { await admin.query('DROP TABLE safeathome_private.capacity_unknown'); }
  await admin.query('ALTER TABLE safeathome_private.cases NO FORCE ROW LEVEL SECURITY');
  try { await assert.rejects(readCapacityReport(admin), CapacityReportError); }
  finally { await admin.query('ALTER TABLE safeathome_private.cases FORCE ROW LEVEL SECURITY'); }
  await admin.query("UPDATE safeathome_migrations.versions SET checksum='changed' WHERE version='003'");
  try { await assert.rejects(readCapacityReport(admin), CapacityReportError); }
  finally { await admin.query("DELETE FROM safeathome_migrations.versions WHERE version='003'");
    const { readFile } = await import('node:fs/promises');
    const checksum = createHash('sha256').update(await readFile(new URL('../../migrations/003_request_tracking.sql', import.meta.url))).digest('hex');
    await admin.query("INSERT INTO safeathome_migrations.versions(version,checksum) VALUES('003',$1)", [checksum]); }
});

test('row counts and quota share a read-only repeatable snapshot while another owner writes', async () => {
  await create(repo); let inserted = false; let readOnly = false;
  const wrapped = { connect: async () => {
    const client = await operator.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      const result = await client.query(sql, values);
      if (!inserted && sql.includes("pg_total_relation_size('safeathome_private.repository_quota')")) {
        inserted = true; readOnly = (await client.query('SHOW transaction_read_only')).rows[0].transaction_read_only === 'on';
        await create(repo, OTHER);
      }
      return result;
    } };
  } } as unknown as Pool;
  const report = await readCapacityReport(wrapped);
  assert.equal(inserted, true); assert.equal(readOnly, true);
  assert.equal(report.rows.cases, 1); assert.equal(report.quota.recorded.cases, 1); assert.equal(report.quota.consistent, true);
  assert.equal((await readCapacityReport(operator)).rows.cases, 2);
});
