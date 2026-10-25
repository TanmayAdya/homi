import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { after, before, beforeEach, test } from 'node:test';
import type { Pool } from 'pg';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { emptyPlanName, type SavePlanNameRequest } from '../../src/cases/plan-name.ts';
import { AccountClosedError } from '../../src/lifecycle/types.ts';
import { TestPostgres } from './harness.ts';
import { OWNER, OTHER, create, draft, packetInput, publication, imageInput, answerInput } from './fixtures.ts';

let cluster: TestPostgres, admin: Pool, runtime: Pool, repo: PostgresCaseRepository;
function pools() { admin = cluster.pool(); runtime = cluster.pool('plan_name_runtime'); repo = new PostgresCaseRepository(runtime); }
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query('CREATE ROLE plan_name_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  pools();
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.case_scan_models, safeathome_private.share_sensitive, safeathome_private.case_shares, safeathome_private.program_intake, safeathome_private.assessment_metadata,
    safeathome_private.evidence_annotations, safeathome_private.cases, safeathome_private.matches,
    safeathome_private.packets, safeathome_private.form_answers, safeathome_private.evidence, safeathome_private.exports,
    safeathome_private.request_history, safeathome_private.deleted_cases, safeathome_private.closed_accounts,
    safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs CASCADE;
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await cluster?.close(); });
const save = (caseId: string, overrides: Partial<SavePlanNameRequest> = {}): SavePlanNameRequest => ({ schemaVersion: '2',
  caseId, expectedNameRevision: 0, mutationId: 'fictional-name-first', name: 'Fictional home 🏡', ...overrides });
const token = () => createHash('sha256').update(randomUUID()).digest('hex');

test('RLS and repository ownership conceal private names from another account and unscoped runtime reads', async () => {
  const snapshot = await create(repo); await create(repo, OTHER);
  assert.deepEqual(await repo.readPlanNameForUser(OWNER, snapshot.caseId), emptyPlanName(snapshot.caseId));
  assert.equal((await repo.savePlanNameForUser(OWNER, save(snapshot.caseId))).status, 'saved');
  assert.equal(await repo.readPlanNameForUser(OTHER, snapshot.caseId), null);
  assert.equal((await repo.savePlanNameForUser(OTHER, save(snapshot.caseId))).status, 'not_found');
  assert.equal((await runtime.query('SELECT plan_name FROM safeathome_private.cases')).rowCount, 0);
  assert.equal((await repo.listNamedForUser(OTHER, { limit: 20, afterCaseId: null })).cases[0].name, null);
});
test('independent concurrent connections serialize CAS, preserve exact retries and protect revisioned reset', async () => {
  const { caseId } = await create(repo); const second = new PostgresCaseRepository(cluster.pool('plan_name_runtime'));
  const requests = [save(caseId), save(caseId, { name: 'Other fictional choice', mutationId: 'other' })];
  const results = await Promise.all([repo.savePlanNameForUser(OWNER, requests[0]), second.savePlanNameForUser(OWNER, requests[1])]);
  assert.deepEqual(results.map(result => result.status).sort(), ['conflict', 'saved']);
  const winner = results.findIndex(result => result.status === 'saved');
  assert.deepEqual(await second.savePlanNameForUser(OWNER, requests[winner]), results[winner]);
  assert.equal((await second.savePlanNameForUser(OWNER, { ...requests[winner], name: 'Changed retry' })).status, 'conflict');
  const reset = save(caseId, { expectedNameRevision: 1, mutationId: 'reset', name: null });
  const resetResult = await repo.savePlanNameForUser(OWNER, reset); assert.equal(resetResult.status, 'saved');
  assert.deepEqual(await second.savePlanNameForUser(OWNER, reset), resetResult);
  assert.equal((await repo.savePlanNameForUser(OWNER, requests[winner])).status, 'conflict');
  assert.equal((await repo.readPlanNameForUser(OWNER, caseId))!.nameRevision, 2);
});
test('rename keeps the existing case revision, matches, answers, private photo and export current', async () => {
  let snapshot = await create(repo);
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot))).status, 'saved');
  snapshot = (await repo.loadForUser(OWNER, snapshot.caseId))!;
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot))).status, 'saved');
  const packet = packetInput(snapshot); assert.equal((await repo.createPacketIfCurrent(packet)).status, 'saved');
  const exported = await publication(repo, snapshot); assert.equal((await repo.publishExportIfCurrent(exported)).status, 'saved');
  const response = { schemaVersion: '1' as const, caseId: snapshot.caseId, caseRevision: snapshot.revision,
    evaluatedAt: new Date().toISOString(), evaluationDate: new Date().toISOString().slice(0, 10), matches: [] };
  await repo.saveMatchIfCurrent(OWNER, snapshot.caseId, snapshot.revision, response);
  const before = (await admin.query(`SELECT
    (SELECT jsonb_agg(row_to_json(t)) FROM safeathome_private.form_answers t) AS answers,
    (SELECT jsonb_agg(row_to_json(t)) FROM safeathome_private.packets t) AS packets,
    (SELECT jsonb_agg(row_to_json(t)) FROM safeathome_private.evidence t) AS evidence,
    (SELECT jsonb_agg(row_to_json(t)) FROM safeathome_private.exports t) AS exports`)).rows[0];
  assert.equal((await repo.savePlanNameForUser(OWNER, save(snapshot.caseId))).status, 'saved');
  assert.deepEqual(await repo.loadForUser(OWNER, snapshot.caseId), snapshot);
  assert.deepEqual(await repo.readSavedMatchForUser(OWNER, snapshot.caseId), response);
  const after = (await admin.query(`SELECT
    (SELECT jsonb_agg(row_to_json(t)) FROM safeathome_private.form_answers t) AS answers,
    (SELECT jsonb_agg(row_to_json(t)) FROM safeathome_private.packets t) AS packets,
    (SELECT jsonb_agg(row_to_json(t)) FROM safeathome_private.evidence t) AS evidence,
    (SELECT jsonb_agg(row_to_json(t)) FROM safeathome_private.exports t) AS exports`)).rows[0];
  assert.deepEqual(after, before);
  const { revision: _, ...updatedDraft } = snapshot;
  assert.equal((await repo.replaceIfCurrent(OWNER, snapshot.caseId, snapshot.revision, updatedDraft)).status, 'saved');
  assert.equal((await repo.readPlanNameForUser(OWNER, snapshot.caseId))!.nameRevision, 1);
});
test('named discovery paginates deterministic owned summaries and survives PostgreSQL restart', async () => {
  const ids = ['a', 'b', 'c'].map(letter => `${letter}0000000-0000-4000-8000-000000000000`);
  for (const caseId of ids) assert.equal((await repo.createForUser(OWNER, draft(caseId))).status, 'saved');
  await repo.savePlanNameForUser(OWNER, save(ids[0]));
  const first = await repo.listNamedForUser(OWNER, { limit: 1, afterCaseId: null });
  assert.equal(first.cases[0].name, save(ids[0]).name); assert.equal(first.nextAfterCaseId, ids[0]);
  assert.deepEqual(await repo.listForUser(OWNER, { limit: 1, afterCaseId: null }),
    { cases: [{ caseId: ids[0], caseRevision: 1 }], nextAfterCaseId: ids[0] });
  await cluster.restart(); pools();
  assert.deepEqual(await repo.listNamedForUser(OWNER, { limit: 1, afterCaseId: null }), first);
  const next = await repo.listNamedForUser(OWNER, { limit: 2, afterCaseId: first.nextAfterCaseId });
  assert.deepEqual(next.cases.map(item => item.caseId), ids.slice(1)); assert.equal(next.nextAfterCaseId, null);
});
test('name-only mutations invalidate account deletion preview and case erasure removes metadata', async () => {
  const { caseId } = await create(repo), receipt = token();
  assert.equal((await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: receipt })).status, 'ready');
  await repo.savePlanNameForUser(OWNER, save(caseId));
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt }), { status: 'changed' });
  assert.deepEqual(await repo.deleteCaseIfCurrent({ userId: OWNER, caseId, revision: 1, expectedCatalogRevision: 0 }), { status: 'deleted' });
  assert.equal(await repo.readPlanNameForUser(OWNER, caseId), null);
  assert.equal((await repo.savePlanNameForUser(OWNER, save(caseId))).status, 'not_found');
  assert.equal((await admin.query('SELECT plan_name FROM safeathome_private.cases')).rowCount, 0);
  assert.equal((await repo.createForUser(OWNER, draft(caseId))).status, 'id_unavailable');
});
test('account closure purges names and rejects every name operation under fresh owner checks', async () => {
  const { caseId } = await create(repo), receipt = token(); await create(repo, OTHER);
  await repo.savePlanNameForUser(OWNER, save(caseId));
  await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: receipt });
  assert.equal((await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt })).status, 'confirmed');
  await assert.rejects(repo.readPlanNameForUser(OWNER, caseId), AccountClosedError);
  await assert.rejects(repo.savePlanNameForUser(OWNER, save(caseId)), AccountClosedError);
  await assert.rejects(repo.listNamedForUser(OWNER, { limit: 20, afterCaseId: null }), AccountClosedError);
  assert.equal((await admin.query('SELECT plan_name FROM safeathome_private.cases WHERE case_id=$1', [caseId])).rowCount, 0);
  assert.equal((await repo.listNamedForUser(OTHER, { limit: 20, afterCaseId: null })).cases.length, 1);
});
test('migration rejects malformed persisted defaults and parser captures caller input before connection awaits', async () => {
  const { caseId } = await create(repo);
  await assert.rejects(admin.query('UPDATE safeathome_private.cases SET plan_name=$1::jsonb WHERE case_id=$2', [JSON.stringify(emptyPlanName(caseId)), caseId]));
  const request = save(caseId);
  const wrapped = new PostgresCaseRepository({ connect: async () => { request.name = 'Changed while awaiting'; return runtime.connect(); } } as unknown as Pool);
  const result = await wrapped.savePlanNameForUser(OWNER, request);
  assert.equal(result.status, 'saved'); if (result.status !== 'saved') throw Error('Unexpected test result.');
  assert.equal(result.state.name, 'Fictional home 🏡');
});
