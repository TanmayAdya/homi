import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { AccountClosedError } from '../../src/lifecycle/types.ts';
import type { RequestHistoryAppendInput, RequestHistoryReadInput, RequestHistoryResult, RequestUpdate } from '../../src/requests/tracking.ts';
import { OWNER, OTHER, create, draft, answerInput, imageInput, iso, packetInput, publication } from './fixtures.ts';

let cluster: TestPostgres, admin: Pool, runtime: Pool, second: Pool;
let repo: PostgresCaseRepository, other: PostgresCaseRepository;
function openPools() {
  admin = cluster.pool(); runtime = cluster.pool('request_runtime', 'request-first');
  second = cluster.pool('request_runtime', 'request-second');
  repo = new PostgresCaseRepository(runtime); other = new PostgresCaseRepository(second);
}
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query('CREATE ROLE request_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  openPools();
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.cases, safeathome_private.matches, safeathome_private.packets,
    safeathome_private.form_answers, safeathome_private.evidence, safeathome_private.exports,
    safeathome_private.request_history, safeathome_private.deleted_cases, safeathome_private.closed_accounts,
    safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs;
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await cluster?.close(); });
const receipt = () => createHash('sha256').update(randomUUID()).digest('hex');
const update = (values: Partial<RequestUpdate> = {}): RequestUpdate => ({ updateId: randomUUID(), status: 'preparing',
  occurredOn: '2026-01-01', source: 'self_report', note: null, nextAction: null, responsibleParty: null, followUpOn: null, ...values });
const readInput = (snapshot: { caseId: string; revision: number }, programId = 'fictional-program'): RequestHistoryReadInput =>
  ({ userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, programId });
const appendInput = (snapshot: { caseId: string; revision: number }, expectedRequestRevision = 0,
  values: Partial<RequestHistoryAppendInput> = {}): RequestHistoryAppendInput =>
  ({ ...readInput(snapshot), expectedRequestRevision, update: update(), recordedAt: iso(), ...values });
function found(result: RequestHistoryResult) {
  assert.equal(result.status, 'found');
  if (result.status !== 'found') throw new Error('Expected a fictional request history.');
  return result.history;
}
async function privateState(caseId: string) {
  const result: Record<string, unknown> = {};
  for (const table of ['cases', 'matches', 'packets', 'form_answers', 'evidence', 'exports']) {
    result[table] = (await admin.query(`SELECT to_jsonb(row) AS value FROM safeathome_private.${table} row WHERE case_id=$1`, [caseId])).rows;
  }
  result.quota = (await admin.query('SELECT * FROM safeathome_private.repository_quota')).rows;
  return result;
}

test('empty histories and reads enforce owner, current case revision and FORCE RLS', async () => {
  const snapshot = await create(repo), input = readInput(snapshot);
  assert.deepEqual(found(await repo.readRequestHistoryForUser(input)), { schemaVersion: '1', caseId: snapshot.caseId,
    caseRevision: 1, programId: input.programId, requestRevision: 0, provenance: 'user_reported', events: [] });
  const saved = found(await repo.appendRequestUpdateForUser(appendInput(snapshot)));
  assert.equal(saved.events[0].source, 'self_report');
  assert.deepEqual(await repo.readRequestHistoryForUser({ ...input, userId: OTHER }), { status: 'not_found' });
  assert.deepEqual(await repo.appendRequestUpdateForUser({ ...appendInput(snapshot), userId: OTHER }), { status: 'not_found' });
  assert.deepEqual(await repo.readRequestHistoryForUser({ ...input, revision: 2 }), { status: 'conflict' });
  assert.equal((await runtime.query('SELECT * FROM safeathome_private.request_history')).rowCount, 0);
  const client = await runtime.connect();
  try {
    await client.query('BEGIN'); await client.query("SELECT set_config('safeathome.user_id',$1,true)", [OTHER]);
    assert.equal((await client.query('SELECT * FROM safeathome_private.request_history')).rowCount, 0);
    assert.equal((await client.query('UPDATE safeathome_private.request_history SET record=record WHERE case_id=$1', [snapshot.caseId])).rowCount, 0);
    await assert.rejects(client.query(`INSERT INTO safeathome_private.request_history(case_id,program_id,request_revision,record)
      VALUES($1,$2,1,$3::jsonb)`, [snapshot.caseId, 'hidden-program', JSON.stringify({ ...saved, programId: 'hidden-program' })]), { code: '42501' });
  } finally { await client.query('ROLLBACK'); client.release(); }
});

test('manual reports preserve saved case, answers, matches, evidence, packets, PDF bytes and quotas', async () => {
  let snapshot = await create(repo);
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot))).status, 'saved');
  snapshot = (await repo.loadForUser(OWNER, snapshot.caseId))!;
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot))).status, 'saved');
  assert.equal((await repo.createPacketIfCurrent(packetInput(snapshot))).status, 'saved');
  assert.equal((await repo.publishExportIfCurrent(await publication(repo, snapshot))).status, 'saved');
  const at = iso();
  await repo.saveMatchIfCurrent(OWNER, snapshot.caseId, snapshot.revision, { schemaVersion: '1', caseId: snapshot.caseId,
    caseRevision: snapshot.revision, evaluatedAt: at, evaluationDate: at.slice(0, 10), matches: [] });
  const before = await privateState(snapshot.caseId);
  const history = found(await repo.appendRequestUpdateForUser(appendInput(snapshot, 0,
    { update: update({ status: 'approved', source: 'program_contact', note: 'Fictional user report only.' }) })));
  assert.equal(history.provenance, 'user_reported'); assert.equal(history.events[0].caseRevision, snapshot.revision);
  assert.deepEqual(await privateState(snapshot.caseId), before);
});

test('exact retries return the current history while altered IDs or revisions conflict', async () => {
  const snapshot = await create(repo), first = appendInput(snapshot);
  const saved = found(await repo.appendRequestUpdateForUser(first));
  found(await other.appendRequestUpdateForUser(appendInput(snapshot, 1)));
  const retry = found(await repo.appendRequestUpdateForUser({ ...first, recordedAt: iso(1000) }));
  assert.equal(retry.requestRevision, 2); assert.deepEqual(retry.events[0], saved.events[0]);
  assert.deepEqual(await repo.appendRequestUpdateForUser({ ...first, update: { ...first.update, note: 'Changed report' } }), { status: 'update_conflict' });
  assert.deepEqual(await repo.appendRequestUpdateForUser({ ...first, expectedRequestRevision: 1 }), { status: 'update_conflict' });
  assert.deepEqual(await repo.appendRequestUpdateForUser(appendInput(snapshot)), { status: 'request_conflict' });
  assert.equal(found(await repo.appendRequestUpdateForUser({ ...first, programId: 'separate-program' })).requestRevision, 1);
});

test('case edits preserve historical event context and require current case binding', async () => {
  const snapshot = await create(repo), first = appendInput(snapshot);
  const original = found(await repo.appendRequestUpdateForUser(first));
  assert.equal((await repo.replaceIfCurrent(OWNER, snapshot.caseId, 1, draft(snapshot.caseId))).status, 'saved');
  assert.deepEqual(await repo.readRequestHistoryForUser(readInput(snapshot)), { status: 'conflict' });
  assert.deepEqual(await repo.appendRequestUpdateForUser(first), { status: 'conflict' });
  const current = { ...snapshot, revision: 2 };
  const history = found(await repo.readRequestHistoryForUser(readInput(current)));
  assert.equal(history.caseRevision, 2); assert.deepEqual(history.events, original.events);
  assert.deepEqual(await repo.appendRequestUpdateForUser({ ...first, revision: 2 }), { status: 'update_conflict' });
  const appended = found(await repo.appendRequestUpdateForUser(appendInput(current, 1)));
  assert.deepEqual(appended.events.map(event => event.caseRevision), [1, 2]);
  assert.equal((await repo.loadForUser(OWNER, snapshot.caseId))?.revision, 2);
});

test('independent concurrent writers serialize one request revision without lost updates', async () => {
  const snapshot = await create(repo);
  const results = await Promise.all([repo.appendRequestUpdateForUser(appendInput(snapshot)), other.appendRequestUpdateForUser(appendInput(snapshot))]);
  assert.deepEqual(results.map(result => result.status).sort(), ['found', 'request_conflict']);
  assert.equal(found(await repo.readRequestHistoryForUser(readInput(snapshot))).events.length, 1);
});

test('four program streams are enforced under concurrent final-slot writes', async () => {
  const snapshot = await create(repo);
  for (let index = 0; index < 3; index++) found(await repo.appendRequestUpdateForUser(appendInput(snapshot, 0, { programId: `program-${index}` })));
  const results = await Promise.all([repo.appendRequestUpdateForUser(appendInput(snapshot, 0, { programId: 'program-3' })),
    other.appendRequestUpdateForUser(appendInput(snapshot, 0, { programId: 'program-4' }))]);
  assert.deepEqual(results.map(result => result.status).sort(), ['found', 'quota_exceeded']);
  assert.equal((await admin.query('SELECT count(*) FROM safeathome_private.request_history')).rows[0].count, '4');
  assert.equal(found(await repo.readRequestHistoryForUser(readInput(snapshot, 'unused-program'))).requestRevision, 0);
});

test('fifty events remain readable and retryable but never grow beyond the bound', async () => {
  const snapshot = await create(repo), first = appendInput(snapshot);
  found(await repo.appendRequestUpdateForUser(first));
  for (let index = 1; index < 50; index++) found(await repo.appendRequestUpdateForUser(appendInput(snapshot, index)));
  assert.deepEqual(await repo.appendRequestUpdateForUser(appendInput(snapshot, 50)), { status: 'quota_exceeded' });
  const history = found(await repo.appendRequestUpdateForUser(first));
  assert.equal(history.requestRevision, 50); assert.equal(history.events.length, 50);
  assert.equal((await admin.query('SELECT request_revision FROM safeathome_private.request_history')).rows[0].request_revision, '50');
});

test('history survives an actual database restart without changed revisions or timestamps', async () => {
  const snapshot = await create(repo), input = appendInput(snapshot);
  const saved = found(await repo.appendRequestUpdateForUser(input));
  await cluster.restart(); openPools();
  assert.deepEqual(found(await repo.readRequestHistoryForUser(readInput(snapshot))), saved);
  assert.deepEqual(found(await repo.appendRequestUpdateForUser(input)), saved);
});

test('case deletion purges request history and leaves the other owner intact', async () => {
  const alice = await create(repo), bob = await create(repo, OTHER);
  found(await repo.appendRequestUpdateForUser(appendInput(alice)));
  found(await repo.appendRequestUpdateForUser(appendInput(bob, 0, { userId: OTHER })));
  assert.deepEqual(await repo.deleteCaseIfCurrent({ userId: OWNER, caseId: alice.caseId, revision: 1, expectedCatalogRevision: 0 }), { status: 'deleted' });
  assert.deepEqual(await repo.readRequestHistoryForUser(readInput(alice)), { status: 'not_found' });
  assert.equal((await admin.query('SELECT count(*) FROM safeathome_private.request_history WHERE case_id=$1', [alice.caseId])).rows[0].count, '0');
  assert.equal(found(await repo.readRequestHistoryForUser({ ...readInput(bob), userId: OTHER })).requestRevision, 1);
});

test('new manual content invalidates account deletion preview and confirmed closure erases all history', async () => {
  const snapshot = await create(repo), tokenHash = receipt(), input = appendInput(snapshot);
  found(await repo.appendRequestUpdateForUser(input));
  assert.equal((await repo.prepareAccountDeletion({ userId: OWNER, tokenHash })).status, 'ready');
  found(await repo.appendRequestUpdateForUser(appendInput(snapshot, 1, { update: update({ note: 'New fictional follow-up' }) })));
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash }), { status: 'changed' });
  const currentToken = receipt();
  assert.equal((await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: currentToken })).status, 'ready');
  found(await repo.appendRequestUpdateForUser(input));
  assert.equal((await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: currentToken })).status, 'confirmed');
  assert.equal((await admin.query('SELECT count(*) FROM safeathome_private.request_history')).rows[0].count, '0');
  await assert.rejects(repo.readRequestHistoryForUser(readInput(snapshot)), AccountClosedError);
  await assert.rejects(repo.appendRequestUpdateForUser(input), AccountClosedError);
});

test('a write authenticated before closure rechecks the barrier after acquiring the write lock', async () => {
  const snapshot = await create(repo), tokenHash = receipt();
  await repo.prepareAccountDeletion({ userId: OWNER, tokenHash });
  let intercepted = false;
  const wrapped = { connect: async () => {
    const client = await runtime.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      if (!intercepted && sql.includes('repository_quota WHERE singleton FOR UPDATE')) {
        intercepted = true;
        assert.equal((await other.confirmAccountDeletion({ userId: OWNER, tokenHash })).status, 'confirmed');
      }
      return client.query(sql, values);
    } };
  } } as unknown as Pool;
  await assert.rejects(new PostgresCaseRepository(wrapped).appendRequestUpdateForUser(appendInput(snapshot)), AccountClosedError);
  assert.equal(intercepted, true);
  assert.equal((await admin.query('SELECT count(*) FROM safeathome_private.request_history')).rows[0].count, '0');
});

test('read transaction keeps a consistent history snapshot through a concurrent append', async () => {
  const snapshot = await create(repo); let intercepted = false;
  const wrapped = { connect: async () => {
    const client = await runtime.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      const result = await client.query(sql, values);
      if (!intercepted && sql.includes('SELECT snapshot, revision, catalog_revision')) {
        intercepted = true; found(await other.appendRequestUpdateForUser(appendInput(snapshot)));
      }
      return result;
    } };
  } } as unknown as Pool;
  assert.equal(found(await new PostgresCaseRepository(wrapped).readRequestHistoryForUser(readInput(snapshot))).requestRevision, 0);
  assert.equal(found(await repo.readRequestHistoryForUser(readInput(snapshot))).requestRevision, 1);
});

test('stored history is validated before refreshing its case context', async () => {
  const snapshot = await create(repo);
  found(await repo.appendRequestUpdateForUser(appendInput(snapshot)));
  await admin.query(`UPDATE safeathome_private.request_history SET record=jsonb_set(record,'{events,0,status}','"invented"'::jsonb)`);
  await assert.rejects(repo.readRequestHistoryForUser(readInput(snapshot)), /Invalid request history data/);
  await assert.rejects(repo.appendRequestUpdateForUser(appendInput(snapshot, 1)), /Invalid request history data/);
  await assert.rejects(admin.query(`UPDATE safeathome_private.request_history SET record=record-'provenance'`), { code: '23514' });
});

test('append input is detached before connection acquisition and returned histories are detached', async () => {
  const snapshot = await create(repo), input = appendInput(snapshot);
  const pending = repo.appendRequestUpdateForUser(input);
  input.userId = OTHER; input.programId = 'changed-program'; input.update.note = 'Changed after the call';
  const saved = found(await pending);
  assert.equal(saved.programId, 'fictional-program'); assert.equal(saved.events[0].note, null);
  saved.events[0].note = 'Changed response';
  assert.equal(found(await repo.readRequestHistoryForUser(readInput(snapshot))).events[0].note, null);
});
