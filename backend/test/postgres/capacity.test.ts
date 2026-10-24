import assert from 'node:assert/strict';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { CAPACITY_LIMITS } from '../../src/storage/capacity-limits.ts';
import { MAX_EXPORT_EVIDENCE_BYTES } from '../../src/evidence/export-budget.ts';
import { caseCapacity, packetCapacity, evidenceCapacity, exportCapacity } from '../capacity-fixtures.ts';
import { OWNER, OTHER, create, draft, packetInput, imageInput } from './fixtures.ts';

let cluster: TestPostgres, admin: Pool, first: PostgresCaseRepository, second: PostgresCaseRepository;
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool();
  await applyMigrations(admin);
  await admin.query('CREATE ROLE capacity_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  first = new PostgresCaseRepository(cluster.pool('capacity_runtime'));
  second = new PostgresCaseRepository(cluster.pool('capacity_runtime'));
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.cases, safeathome_private.matches, safeathome_private.packets,
    safeathome_private.form_answers, safeathome_private.evidence, safeathome_private.exports, safeathome_private.request_history,
    safeathome_private.deleted_cases, safeathome_private.closed_accounts,
    safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs;
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await cluster?.close(); });

for (const [name, exercise] of Object.entries({ caseCapacity, packetCapacity, evidenceCapacity, exportCapacity })) {
  test(`PostgreSQL ${name} preserves retries, ownership and atomic final slots across pools`, async () => {
    await exercise(first, second);
  });
}

test('deleting a case releases owner slots and child retry records while its ID stays fenced', async () => {
  const snapshot = await caseCapacity(first, second);
  assert.equal((await first.createPacketIfCurrent(packetInput(snapshot))).status, 'conflict');
  const current = (await first.loadForUser(OWNER, snapshot.caseId))!;
  assert.equal((await first.createPacketIfCurrent(packetInput(current))).status, 'saved');
  assert.equal((await first.saveEvidenceIfCurrent(await imageInput(current))).status, 'saved');
  assert.equal((await first.deleteCaseIfCurrent({ userId: OWNER, caseId: current.caseId, revision: current.revision,
    expectedCatalogRevision: 1 })).status, 'deleted');
  assert.equal((await first.createForUser(OWNER, draft(current.caseId))).status, 'id_unavailable');
  assert.equal((await first.createForUser(OTHER, draft(current.caseId))).status, 'id_unavailable');
  await create(first);
  assert.equal((await first.createForUser(OWNER, draft())).status, 'quota_exceeded');
  const row = (await admin.query(`SELECT
    (SELECT count(*) FROM safeathome_private.cases WHERE owner_id=$1) AS cases,
    (SELECT count(*) FROM safeathome_private.packets WHERE case_id=$2) AS packets,
    (SELECT count(*) FROM safeathome_private.evidence WHERE case_id=$2) AS evidence`, [OWNER, current.caseId])).rows[0];
  assert.deepEqual(row, { cases: String(CAPACITY_LIMITS.casesPerOwner), packets: '0', evidence: '0' });
});

test('deleting a case at the evidence cap permits a new evidence identity in a remaining case', async () => {
  const { a, b } = await evidenceCapacity(first, second);
  const catalog = await first.readEvidenceCatalogForUser(OWNER, a.caseId);
  assert.equal(catalog.status, 'found');
  if (catalog.status !== 'found') throw new Error('Missing catalog.');
  assert.equal((await first.deleteCaseIfCurrent({ userId: OWNER, caseId: a.caseId, revision: a.revision,
    expectedCatalogRevision: catalog.catalog.catalogRevision })).status, 'deleted');
  const remaining = await first.readEvidenceCatalogForUser(OWNER, b.caseId);
  assert.equal(remaining.status, 'found');
  if (remaining.status !== 'found') throw new Error('Missing catalog.');
  assert.equal((await first.saveEvidenceIfCurrent(await imageInput(b, remaining.catalog.catalogRevision, 'capacity-photo-9'))).status, 'saved');
});

test('PostgreSQL preflights aggregate descriptors before retrieving any evidence bytes', async () => {
  const snapshot = await create(first);
  for (const [index, evidenceId] of snapshot.findings[0].evidenceIds.entries()) {
    assert.equal((await first.saveEvidenceIfCurrent(await imageInput(snapshot, index, evidenceId))).status, 'saved');
  }
  const runtime = cluster.pool('capacity_runtime');
  for (const kind of ['pixels', 'bytes'] as const) {
    let binaryReads = 0, descriptorReads = 0;
    const wrapped = { connect: async () => {
      const client = await runtime.connect();
      return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
        if (sql.includes('FROM safeathome_private.evidence') && /^SELECT (?:\*|[^\n]*\bbytes\b)/.test(sql)) {
          binaryReads++; throw new Error('The oversized selection fetched private bytes.');
        }
        const result = await client.query(sql, values);
        if (sql.includes('FROM safeathome_private.evidence') && sql.startsWith('SELECT evidence_id,')) {
          descriptorReads++;
          for (const row of result.rows) {
            if (kind === 'pixels') Object.assign(row.descriptor, { width: 4000, height: 3000 });
            else row.descriptor.byteLength = MAX_EXPORT_EVIDENCE_BYTES / 2 + 1;
          }
        }
        return result;
      } };
    } } as unknown as Pool;
    const bounded = new PostgresCaseRepository(wrapped);
    const input = { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision,
      expectedCatalogRevision: 2, programId: 'program-a', selections: snapshot.findings[0].evidenceIds
        .map(evidenceId => ({ evidenceId, expectedEvidenceRevision: 1, reviewedForExport: true as const })) };
    assert.deepEqual(await bounded.loadExportSnapshotForUser(input), { status: 'selection_too_large' });
    assert.equal(binaryReads, 0); assert.equal(descriptorReads, 2);
    assert.deepEqual(await bounded.loadExportSnapshotForUser({ ...input, userId: OTHER }), { status: 'not_found' });
    assert.deepEqual(await bounded.loadExportSnapshotForUser({ ...input, expectedCatalogRevision: 1 }), { status: 'evidence_conflict' });
    assert.equal(binaryReads, 0);
  }
  const reduced = await first.loadExportSnapshotForUser({ userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision,
    expectedCatalogRevision: 2, programId: 'program-a', selections: [{ evidenceId: snapshot.findings[0].evidenceIds[0],
      expectedEvidenceRevision: 1, reviewedForExport: true }] });
  assert.equal(reduced.status, 'found');
  if (reduced.status === 'found') assert.equal(reduced.snapshot.assets.length, 1);
});

test('descriptor preflight and binary fetch share a snapshot across concurrent evidence deletion', async () => {
  const snapshot = await create(first), saved = await imageInput(snapshot);
  assert.equal((await first.saveEvidenceIfCurrent(saved)).status, 'saved');
  const runtime = cluster.pool('capacity_runtime');
  let deleted = false;
  const wrapped = { connect: async () => {
    const client = await runtime.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      const result = await client.query(sql, values);
      if (!deleted && sql.startsWith('SELECT evidence_id,') && sql.includes('FROM safeathome_private.evidence')) {
        deleted = true;
        assert.equal((await second.deleteEvidenceIfCurrent({ ...saved, expectedCatalogRevision: 1,
          expectedEvidenceRevision: 1 })).status, 'deleted');
      }
      return result;
    } };
  } } as unknown as Pool;
  const input = { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision,
    expectedCatalogRevision: 1, programId: 'program-a', selections: [{ evidenceId: saved.evidenceId,
      expectedEvidenceRevision: 1, reviewedForExport: true as const }] };
  const loaded = await new PostgresCaseRepository(wrapped).loadExportSnapshotForUser(input);
  assert.equal(loaded.status, 'found'); assert.equal(deleted, true);
  if (loaded.status === 'found') {
    assert.equal(loaded.snapshot.catalogRevision, 1);
    assert.deepEqual(loaded.snapshot.assets[0].bytes, saved.image.bytes);
  }
  assert.equal((await first.loadExportSnapshotForUser(input)).status, 'evidence_conflict');
});
