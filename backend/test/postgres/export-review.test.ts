import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { AccountClosedError } from '../../src/lifecycle/types.ts';
import { OWNER, OTHER, FORM_CONTEXT, create, answerInput, imageInput, publication } from './fixtures.ts';

let cluster: TestPostgres, admin: Pool, runtime: Pool, repo: PostgresCaseRepository;
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query('CREATE ROLE export_review_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  runtime = cluster.pool('export_review_runtime'); repo = new PostgresCaseRepository(runtime);
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.program_intake, safeathome_private.assessment_metadata, safeathome_private.evidence_annotations, safeathome_private.cases,safeathome_private.matches,safeathome_private.packets,
    safeathome_private.form_answers,safeathome_private.evidence,safeathome_private.exports,safeathome_private.request_history,
    safeathome_private.deleted_cases,safeathome_private.closed_accounts,safeathome_private.account_deletion_previews,safeathome_private.auth_deletion_jobs;
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await cluster?.close(); });

async function seeded() {
  let snapshot = await create(repo);
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot))).status, 'saved');
  snapshot = (await repo.loadForUser(OWNER, snapshot.caseId))!;
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot))).status, 'saved');
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot, 1, 'fictional-photo-b'))).status, 'saved');
  const input = { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, expectedCatalogRevision: 2,
    programId: FORM_CONTEXT.programId, selections: ['fictional-photo-b', 'fictional-photo-a'].map(evidenceId =>
      ({ evidenceId, expectedEvidenceRevision: 1, reviewedForExport: true as const })) };
  return { snapshot, input };
}
function observedPool(afterQuery?: (sql: string) => Promise<void>) {
  let binaryQueries = 0, descriptorQueries = 0;
  const pool = { connect: async () => {
    const client = await runtime.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      const projection = sql.match(/^SELECT\s+([\s\S]+?)\s+FROM safeathome_private\.(?:evidence|exports)\b/i)?.[1]
        .replace(/octet_length\(bytes\)/g, '0');
      if (projection && /\bbytes\b|\*/.test(projection)) {
        binaryQueries++; throw new Error('Metadata review fetched private binary bytes.');
      }
      if (sql.includes('FROM safeathome_private.evidence')) {
        if (sql.startsWith('SELECT evidence_id,')) descriptorQueries++;
      }
      const result = await client.query(sql, values); await afterQuery?.(sql); return result;
    } };
  } } as unknown as Pool;
  return { repo: new PostgresCaseRepository(pool), binaryQueries: () => binaryQueries, descriptorQueries: () => descriptorQueries };
}

test('PostgreSQL review returns the complete same ordered bindings without selecting binary photos', async () => {
  const { input } = await seeded(); const guarded = observedPool();
  const full = await repo.loadExportSnapshotForUser(input), review = await guarded.repo.loadExportReviewForUser(input);
  assert.equal(full.status, 'found'); assert.equal(review.status, 'found');
  if (full.status !== 'found' || review.status !== 'found') throw new Error('Missing fictional export context.');
  const { assets, ...bindings } = full.snapshot;
  assert.deepEqual(review.snapshot, { ...bindings, evidence: assets.map(asset => asset.descriptor) });
  assert.equal(guarded.binaryQueries(), 0); assert.equal(guarded.descriptorQueries(), 2);
  const expected = structuredClone(review.snapshot);
  review.snapshot.snapshot.profile.city = 'Caller mutation'; review.snapshot.evidence[0].sha256 = 'f'.repeat(64);
  review.snapshot.answers!.answers[0].value = 'Caller mutation';
  assert.deepEqual(await guarded.repo.loadExportReviewForUser(input), { status: 'found', snapshot: expected });
});

async function published() {
  const state = await seeded();
  const output = await publication(repo, state.snapshot, 2);
  assert.equal((await repo.publishExportIfCurrent(output)).status, 'saved');
  const request = { userId: OWNER, caseId: state.snapshot.caseId, artifactId: output.artifact.metadata.artifactId,
    contextFingerprint: output.contextFingerprint, checkedAt: new Date().toISOString() };
  return { ...state, output, request };
}

test('PostgreSQL final metadata review uses current locked bindings without selecting PDF or image bytes', async () => {
  const { output, request } = await published(); const guarded = observedPool();
  const expected = structuredClone(output.artifact.metadata);
  const pending = guarded.repo.reviewExportForUserIfCurrent(request), original = { ...request };
  request.userId = OTHER; request.caseId = 'caller-mutation'; request.artifactId = 'caller-mutation';
  request.contextFingerprint = '0'.repeat(64); request.checkedAt = 'not-a-time';
  const result = await pending;
  assert.deepEqual(result, { status: 'found', artifact: expected });
  if (result.status !== 'found') throw new Error('Missing fictional publication.');
  assert.equal('bytes' in result.artifact, false); assert.equal(guarded.binaryQueries(), 0);
  result.artifact.selectedEvidence[0].sha256 = '0'.repeat(64);
  assert.deepEqual(await guarded.repo.reviewExportForUserIfCurrent(original), { status: 'found', artifact: expected });
  const full = await repo.readExportForUserIfCurrent(original);
  assert.equal(full.status, 'found');
  if (full.status !== 'found') throw new Error('Missing fictional PDF.');
  assert.deepEqual(full.artifact.metadata, expected);
  assert.equal(createHash('sha256').update(full.artifact.bytes).digest('hex'), expected.sha256);
});

test('PostgreSQL final metadata review retains ownership/context/stale evidence and closed-account denial', async () => {
  const { input, request } = await published(); const guarded = observedPool();
  for (const changed of [{ ...request, userId: OTHER }, { ...request, caseId: 'unowned-case' },
    { ...request, artifactId: 'missing-artifact' }, { ...request, contextFingerprint: 'a'.repeat(64) }]) {
    assert.deepEqual(await guarded.repo.reviewExportForUserIfCurrent(changed), await repo.readExportForUserIfCurrent(changed));
    assert.notEqual((await guarded.repo.reviewExportForUserIfCurrent(changed)).status, 'found');
  }
  assert.equal((await repo.deleteEvidenceIfCurrent({ ...input, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 })).status, 'deleted');
  assert.deepEqual(await guarded.repo.reviewExportForUserIfCurrent(request), { status: 'evidence_conflict' });
  const tokenHash = createHash('sha256').update(randomUUID()).digest('hex');
  await repo.prepareAccountDeletion({ userId: OWNER, tokenHash }); await repo.confirmAccountDeletion({ userId: OWNER, tokenHash });
  await assert.rejects(guarded.repo.reviewExportForUserIfCurrent(request), AccountClosedError);
  assert.equal(guarded.binaryQueries(), 0);
});

test('PostgreSQL final metadata expiry releases payload quota once and cannot be rolled back into a live artifact', async () => {
  const { output, request } = await published(); const guarded = observedPool();
  const before = (await admin.query('SELECT artifact_count,stored_bytes FROM safeathome_private.repository_quota')).rows[0];
  const later = new Date(Date.now() + 30_000).toISOString();
  assert.equal((await guarded.repo.reviewExportForUserIfCurrent({ ...request, checkedAt: later })).status, 'found');
  assert.deepEqual(await guarded.repo.reviewExportForUserIfCurrent(request), { status: 'expired' });
  assert.deepEqual(await guarded.repo.reviewExportForUserIfCurrent({ ...request, checkedAt: output.artifact.metadata.expiresAt }), { status: 'expired' });
  const after = (await admin.query('SELECT artifact_count,stored_bytes FROM safeathome_private.repository_quota')).rows[0];
  assert.equal(Number(after.artifact_count), Number(before.artifact_count) - 1);
  assert.equal(Number(after.stored_bytes), Number(before.stored_bytes) - output.artifact.bytes.byteLength);
  assert.deepEqual(await guarded.repo.reviewExportForUserIfCurrent({ ...request, checkedAt: later }), { status: 'expired' });
  assert.deepEqual(await repo.readExportForUserIfCurrent({ ...request, checkedAt: later }), { status: 'expired' });
  assert.deepEqual((await admin.query('SELECT artifact_count,stored_bytes FROM safeathome_private.repository_quota')).rows[0], after);
  assert.equal(guarded.binaryQueries(), 0);
});

test('PostgreSQL final metadata review rejects an answer save that advances the bound case revision', async () => {
  const { snapshot, request } = await published(); const guarded = observedPool();
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot, 1))).status, 'saved');
  assert.deepEqual(await guarded.repo.reviewExportForUserIfCurrent(request), { status: 'conflict' });
  assert.deepEqual(await guarded.repo.reviewExportForUserIfCurrent(request), await repo.readExportForUserIfCurrent(request));
  assert.equal(guarded.binaryQueries(), 0);
});

test('PostgreSQL metadata review preserves ownership, case/catalog/asset checks and closed-account denial', async () => {
  const { input } = await seeded(); const guarded = observedPool();
  for (const changed of [{ ...input, userId: OTHER }, { ...input, revision: input.revision + 1 },
    { ...input, expectedCatalogRevision: 1 }, { ...input, selections: [{ ...input.selections[0], expectedEvidenceRevision: 2 }] }]) {
    assert.deepEqual(await guarded.repo.loadExportReviewForUser(changed), await repo.loadExportSnapshotForUser(changed));
    assert.notEqual((await guarded.repo.loadExportReviewForUser(changed)).status, 'found');
  }
  const tokenHash = createHash('sha256').update(randomUUID()).digest('hex');
  await repo.prepareAccountDeletion({ userId: OWNER, tokenHash });
  await repo.confirmAccountDeletion({ userId: OWNER, tokenHash });
  await assert.rejects(guarded.repo.loadExportReviewForUser(input), AccountClosedError);
  assert.equal(guarded.binaryQueries(), 0);
});

test('metadata review captures caller selections and identities before its first database await', async () => {
  const { input } = await seeded(); const expected = await repo.loadExportReviewForUser(input);
  const pending = repo.loadExportReviewForUser(input);
  input.userId = OTHER; input.caseId = 'changed-by-caller'; input.programId = 'changed-program';
  input.selections[0].evidenceId = 'changed-evidence';
  assert.deepEqual(await pending, expected);
});

test('concurrent deletion cannot mix metadata revisions or let an old review publish a stale artifact', async () => {
  const { input, snapshot } = await seeded();
  const output = await publication(repo, snapshot, 2);
  let deleted = false;
  const guarded = observedPool(async sql => {
    if (!deleted && sql.startsWith('SELECT evidence_id,') && sql.includes('FROM safeathome_private.evidence')) {
      deleted = true;
      assert.equal((await repo.deleteEvidenceIfCurrent({ ...input, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 })).status, 'deleted');
    }
  });
  const before = await repo.loadExportReviewForUser(input);
  const observed = await guarded.repo.loadExportReviewForUser(input);
  assert.equal(deleted, true); assert.deepEqual(observed, before); assert.equal(guarded.binaryQueries(), 0);
  assert.deepEqual(await repo.loadExportReviewForUser(input), { status: 'evidence_conflict' });
  assert.deepEqual(await repo.publishExportIfCurrent(output), { status: 'evidence_conflict' });
  assert.equal((await admin.query('SELECT count(*) AS count FROM safeathome_private.exports')).rows[0].count, '0');
});
