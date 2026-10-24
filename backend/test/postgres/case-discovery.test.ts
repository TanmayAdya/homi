import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { after, before, beforeEach, test } from 'node:test';
import type { Pool } from 'pg';
import type { CaseListQuery } from '../../src/cases/discovery.ts';
import { AccountClosedError } from '../../src/lifecycle/types.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { TestPostgres } from './harness.ts';
import { OWNER, OTHER, answerInput, draft } from './fixtures.ts';

let cluster: TestPostgres, admin: Pool, runtime: Pool;
let repo: PostgresCaseRepository;
const firstPage: CaseListQuery = { limit: 20, afterCaseId: null };
const id = (number: number) => `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`;
function openPools() {
  admin = cluster.pool(); runtime = cluster.pool('discovery_runtime');
  repo = new PostgresCaseRepository(runtime);
}
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool();
  await applyMigrations(admin);
  await admin.query('CREATE ROLE discovery_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  openPools();
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.cases, safeathome_private.matches,
    safeathome_private.packets, safeathome_private.form_answers, safeathome_private.evidence,
    safeathome_private.exports, safeathome_private.request_history, safeathome_private.deleted_cases, safeathome_private.closed_accounts,
    safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs;
    UPDATE safeathome_private.repository_quota
    SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await cluster?.close(); });

async function create(number: number, owner = OWNER) {
  const result = await repo.createForUser(owner, draft(id(number)));
  assert.equal(result.status, 'saved');
  if (result.status !== 'saved') throw new Error('Fictional case setup failed.');
  return result.snapshot;
}

test('lists only owned minimal summaries and treats an empty owner as an empty page', async () => {
  assert.deepEqual(await repo.listForUser(OWNER, firstPage), { cases: [], nextAfterCaseId: null });
  const alice = await create(1), bob = await create(2, OTHER);
  assert.deepEqual(await repo.listForUser(OWNER, firstPage), {
    cases: [{ caseId: alice.caseId, caseRevision: 1 }], nextAfterCaseId: null,
  });
  assert.deepEqual(await repo.listForUser(OTHER, firstPage), {
    cases: [{ caseId: bob.caseId, caseRevision: 1 }], nextAfterCaseId: null,
  });
  assert.deepEqual(await repo.listForUser('fictional-empty-owner', firstPage), { cases: [], nextAfterCaseId: null });
  assert.equal((await runtime.query('SELECT case_id FROM safeathome_private.cases')).rowCount, 0);
});

test('bounded keyset pages retain every legacy over-cap case and use no foreign boundary lookup', async () => {
  const legacy = async (number: number) => {
    const snapshot = { ...draft(id(number)), revision: 1 };
    await admin.query(`INSERT INTO safeathome_private.cases(case_id,owner_id,revision,snapshot)
      VALUES($1,$2,1,$3::jsonb)`, [snapshot.caseId, OWNER, JSON.stringify(snapshot)]);
    await admin.query('UPDATE safeathome_private.repository_quota SET case_count=case_count+1');
  };
  for (let number = 1; number <= 22; number++) await legacy(number);
  assert.equal((await repo.createForUser(OWNER, draft(id(26)))).status, 'quota_exceeded');
  const first = await repo.listForUser(OWNER, firstPage);
  assert.equal(first.cases.length, 20); assert.equal(first.nextAfterCaseId, id(20));
  const second = await repo.listForUser(OWNER, { limit: 20, afterCaseId: first.nextAfterCaseId });
  assert.deepEqual(second, { cases: [21, 22].map(number => ({ caseId: id(number), caseRevision: 1 })), nextAfterCaseId: null });
  assert.deepEqual(await repo.listForUser(OWNER, { limit: 1, afterCaseId: id(22) }), { cases: [], nextAfterCaseId: null });
  assert.deepEqual([...first.cases, ...second.cases].map(item => item.caseId),
    Array.from({ length: 22 }, (_, index) => id(index + 1)));
  await create(23, OTHER); await legacy(25);
  const expected = { cases: [{ caseId: id(25), caseRevision: 1 }], nextAfterCaseId: null };
  assert.deepEqual(await repo.listForUser(OWNER, { limit: 1, afterCaseId: id(23) }), expected);
  assert.deepEqual(await repo.listForUser(OWNER, { limit: 1, afterCaseId: id(24) }), expected);
});

test('legacy Unicode IDs use UTF-8 byte order, including across page boundaries', async () => {
  const expected = ['Z', 'a', 'é', '\uE000', '\u{10000}', '\u{1F642}'];
  for (const caseId of [...expected].reverse()) {
    const snapshot = { ...draft(caseId), revision: 1 };
    await admin.query(`INSERT INTO safeathome_private.cases(case_id,owner_id,revision,snapshot)
      VALUES($1,$2,1,$3::jsonb)`, [caseId, OWNER, JSON.stringify(snapshot)]);
  }
  await admin.query('UPDATE safeathome_private.repository_quota SET case_count=$1', [expected.length]);
  const ids: string[] = [];
  let afterCaseId: string | null = null;
  do {
    const page = await repo.listForUser(OWNER, { limit: 2, afterCaseId });
    ids.push(...page.cases.map(item => item.caseId));
    afterCaseId = page.nextAfterCaseId;
  } while (afterCaseId !== null);
  assert.deepEqual(ids, expected);
});

test('invalid direct pagination is rejected before acquiring a database connection', async () => {
  let connections = 0;
  const unexpected = new PostgresCaseRepository({ connect: async () => {
    connections++; throw new Error('Unexpected database connection.');
  } } as unknown as Pool);
  const invalid: unknown[] = [null, {}, { limit: 20 }, { ...firstPage, extra: true },
    ...[0, 21, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1].map(limit => ({ ...firstPage, limit })),
    ...['', ' padded ', '\u0000', '\uD800', 'x'.repeat(201), 1].map(afterCaseId => ({ limit: 1, afterCaseId }))];
  for (const query of invalid) await assert.rejects(unexpected.listForUser(OWNER, query as CaseListQuery));
  assert.equal(connections, 0);
});

test('pagination is captured before the connection await and results are detached', async () => {
  await create(1); await create(2); await create(3);
  const query: CaseListQuery = { limit: 1, afterCaseId: null };
  const wrapped = new PostgresCaseRepository({ connect: async () => {
    query.limit = 20; query.afterCaseId = id(2);
    return runtime.connect();
  } } as unknown as Pool);
  const result = await wrapped.listForUser(OWNER, query);
  assert.deepEqual(result, { cases: [{ caseId: id(1), caseRevision: 1 }], nextAfterCaseId: id(1) });
  result.cases[0]!.caseRevision = 999; result.cases[0]!.caseId = 'changed-local-only';
  assert.deepEqual(await repo.listForUser(OWNER, { limit: 1, afterCaseId: null }),
    { cases: [{ caseId: id(1), caseRevision: 1 }], nextAfterCaseId: id(1) });
});

test('deleted boundary and pending rows do not skip survivors; new earlier IDs need refresh', async () => {
  for (const number of [1, 3, 5, 7]) await create(number);
  const first = await repo.listForUser(OWNER, { limit: 2, afterCaseId: null });
  assert.equal(first.nextAfterCaseId, id(3));
  for (const number of [3, 5]) assert.deepEqual(await repo.deleteCaseIfCurrent({
    userId: OWNER, caseId: id(number), revision: 1, expectedCatalogRevision: 0,
  }), { status: 'deleted' });
  await create(2); await create(6);
  const next = await repo.listForUser(OWNER, { limit: 2, afterCaseId: first.nextAfterCaseId });
  assert.deepEqual(next, { cases: [6, 7].map(number => ({ caseId: id(number), caseRevision: 1 })), nextAfterCaseId: null });
  assert.deepEqual((await repo.listForUser(OWNER, firstPage)).cases.map(item => item.caseId), [1, 2, 6, 7].map(id));
});

test('case and answer saves update the summary revision without changing order', async () => {
  const saved = await create(1); await create(2);
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(saved))).status, 'saved');
  assert.deepEqual(await repo.listForUser(OWNER, { limit: 1, afterCaseId: null }),
    { cases: [{ caseId: id(1), caseRevision: 2 }], nextAfterCaseId: id(1) });
  assert.equal((await repo.replaceIfCurrent(OWNER, id(1), 2, draft(id(1)))).status, 'saved');
  const page = await repo.listForUser(OWNER, firstPage);
  assert.deepEqual(page.cases, [{ caseId: id(1), caseRevision: 3 }, { caseId: id(2), caseRevision: 1 }]);
  assert.equal((await repo.loadForUser(OWNER, page.cases[0]!.caseId))?.revision, 3);
});

test('listing and continuation survive a real PostgreSQL restart', async () => {
  await create(1); await create(2); await create(3, OTHER);
  const beforeRestart = await repo.listForUser(OWNER, { limit: 1, afterCaseId: null });
  await cluster.restart(); openPools();
  assert.deepEqual(await repo.listForUser(OWNER, { limit: 1, afterCaseId: null }), beforeRestart);
  assert.deepEqual(await repo.listForUser(OWNER, { limit: 1, afterCaseId: beforeRestart.nextAfterCaseId }),
    { cases: [{ caseId: id(2), caseRevision: 1 }], nextAfterCaseId: null });
  assert.equal((await repo.loadForUser(OWNER, id(1)))?.caseId, id(1));
});

test('account closure blocks discovery and leaves another owner discoverable', async () => {
  await create(1); await create(2, OTHER);
  const tokenHash = createHash('sha256').update(randomUUID()).digest('hex');
  assert.equal((await repo.prepareAccountDeletion({ userId: OWNER, tokenHash })).status, 'ready');
  assert.equal((await repo.confirmAccountDeletion({ userId: OWNER, tokenHash })).status, 'confirmed');
  await assert.rejects(repo.listForUser(OWNER, firstPage), AccountClosedError);
  await assert.rejects(repo.listForUser(OWNER, { limit: 1, afterCaseId: id(1) }), AccountClosedError);
  assert.deepEqual(await repo.listForUser(OTHER, firstPage),
    { cases: [{ caseId: id(2), caseRevision: 1 }], nextAfterCaseId: null });
});
