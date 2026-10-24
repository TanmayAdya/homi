import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { before, beforeEach, after, test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { PostgresLifecycleMaintenance } from '../../src/storage/lifecycle-maintenance.ts';
import { AccountClosedError } from '../../src/lifecycle/types.ts';
import { OWNER, OTHER, FORM_CONTEXT, EXPORT_CONTEXT, create, draft, answerInput, imageInput,
  iso, packetInput, publication } from './fixtures.ts';

let cluster: TestPostgres, admin: Pool, first: Pool, second: Pool;
let repo: PostgresCaseRepository, other: PostgresCaseRepository, maintenance: PostgresLifecycleMaintenance;
const hash = (value: string) => createHash('sha256').update(value).digest('hex');
const token = () => hash(randomUUID());
function pools() {
  admin = cluster.pool(); first = cluster.pool('lifecycle_runtime', 'lifecycle-first');
  second = cluster.pool('lifecycle_runtime', 'lifecycle-second');
  repo = new PostgresCaseRepository(first); other = new PostgresCaseRepository(second);
  maintenance = new PostgresLifecycleMaintenance(admin);
}
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool();
  await applyMigrations(admin);
  await admin.query('CREATE ROLE lifecycle_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  pools();
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.cases, safeathome_private.matches, safeathome_private.packets,
    safeathome_private.form_answers, safeathome_private.evidence, safeathome_private.exports, safeathome_private.request_history,
    safeathome_private.deleted_cases, safeathome_private.closed_accounts,
    safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs;
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await cluster?.close(); });
async function quota() {
  const row = (await admin.query('SELECT case_count,asset_count,artifact_count,stored_bytes FROM safeathome_private.repository_quota')).rows[0];
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [key, Number(value)]));
}
async function populated() {
  let snapshot = await create(repo);
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(snapshot))).status, 'saved');
  snapshot = (await repo.loadForUser(OWNER, snapshot.caseId))!;
  const image = await imageInput(snapshot);
  assert.equal((await repo.saveEvidenceIfCurrent(image)).status, 'saved');
  const packet = packetInput(snapshot);
  assert.equal((await repo.createPacketIfCurrent(packet)).status, 'saved');
  const exported = await publication(repo, snapshot);
  assert.equal((await repo.publishExportIfCurrent(exported)).status, 'saved');
  await repo.saveMatchIfCurrent(OWNER, snapshot.caseId, snapshot.revision,
    { schemaVersion: '1', caseId: snapshot.caseId, caseRevision: snapshot.revision, evaluatedAt: iso(), evaluationDate: iso().slice(0, 10), matches: [] });
  return { snapshot, image, packet, exported };
}
async function close(owner = OWNER) {
  const tokenHash = token();
  assert.equal((await repo.prepareAccountDeletion({ userId: owner, tokenHash })).status, 'ready');
  assert.equal((await repo.confirmAccountDeletion({ userId: owner, tokenHash })).status, 'confirmed');
  return tokenHash;
}

test('case deletion is owner/revision/catalog scoped, purges every child and blocks ID ABA', async () => {
  const { snapshot, image, packet, exported } = await populated();
  const bob = await create(repo, OTHER);
  const input = { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, expectedCatalogRevision: 1 };
  assert.deepEqual(await repo.deleteCaseIfCurrent({ ...input, userId: OTHER }), { status: 'not_found' });
  assert.deepEqual(await repo.deleteCaseIfCurrent({ ...input, revision: 1 }), { status: 'conflict' });
  assert.deepEqual(await repo.deleteCaseIfCurrent({ ...input, expectedCatalogRevision: 0 }), { status: 'evidence_conflict' });
  assert.deepEqual(await repo.deleteCaseIfCurrent(input), { status: 'deleted' });
  assert.deepEqual(await other.deleteCaseIfCurrent(input), { status: 'deleted' });
  assert.equal(await repo.loadForUser(OWNER, snapshot.caseId), null);
  assert.deepEqual(await repo.loadForUser(OTHER, bob.caseId), bob);
  for (const owner of [OWNER, OTHER]) assert.deepEqual(await repo.createForUser(owner, draft(snapshot.caseId)), { status: 'id_unavailable' });
  assert.equal((await repo.saveEvidenceIfCurrent(image)).status, 'not_found');
  assert.equal((await repo.createPacketIfCurrent(packet)).status, 'not_found');
  assert.equal((await repo.publishExportIfCurrent(exported)).status, 'not_found');
  for (const table of ['matches','packets','form_answers','evidence','exports']) {
    assert.equal((await admin.query(`SELECT count(*) AS count FROM safeathome_private.${table} WHERE case_id=$1`, [snapshot.caseId])).rows[0].count, '0');
  }
  assert.deepEqual(await quota(), { case_count: 1, asset_count: 0, artifact_count: 0, stored_bytes: 0 });
  const tombstone = (await admin.query('SELECT * FROM safeathome_private.deleted_cases')).rows[0];
  assert.equal(tombstone.case_hash, hash(snapshot.caseId)); assert.equal(tombstone.owner_hash, hash(OWNER));
  assert.equal(JSON.stringify(tombstone).includes(snapshot.caseId), false);
});

test('account preview rotates capabilities, rejects wrong owner, expiry and changed inventory', async () => {
  const snapshot = await create(repo), firstToken = token(), currentToken = token();
  assert.equal((await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: firstToken })).status, 'ready');
  assert.deepEqual(await repo.readAccountDeletionReceipt(firstToken), { status: 'awaiting_confirmation', applicationDataDeleted: false, providerIdentityDeleted: false });
  const ready = await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: currentToken });
  assert.equal(ready.status, 'ready');
  if (ready.status === 'ready') assert.deepEqual(ready.counts, { cases: 1, evidence: 0, exports: 0, storedBytes: 0 });
  assert.equal(await repo.readAccountDeletionReceipt(firstToken), null);
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OTHER, tokenHash: currentToken }), { status: 'not_found' });
  assert.equal((await repo.replaceIfCurrent(OWNER, snapshot.caseId, 1, draft(snapshot.caseId))).status, 'saved');
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: currentToken }), { status: 'changed' });
  const expired = token(); await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: expired });
  await admin.query("UPDATE safeathome_private.account_deletion_previews SET expires_at=clock_timestamp()-interval '1 second'");
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: expired }), { status: 'expired' });
  assert.equal(await repo.readAccountDeletionReceipt(expired), null);
  assert.equal(await repo.isAccountClosed(OWNER), false);
});

test('an existing match replacement changes the deletion fingerprint without changing counts or case revision', async () => {
  const snapshot = await create(repo);
  const response = { schemaVersion: '1' as const, caseId: snapshot.caseId, caseRevision: 1,
    evaluatedAt: iso(-1000), evaluationDate: iso().slice(0, 10), matches: [] };
  await repo.saveMatchIfCurrent(OWNER, snapshot.caseId, 1, response);
  const receipt = token(); await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: receipt });
  await repo.saveMatchIfCurrent(OWNER, snapshot.caseId, 1, { ...response, evaluatedAt: iso() });
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt }), { status: 'changed' });
  assert.equal((await repo.loadForUser(OWNER, snapshot.caseId))?.revision, 1);
});

test('receipt transition uses one snapshot even when confirmation commits between its reads', async () => {
  await create(repo); const receipt = token(); await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: receipt });
  const wrapped = { connect: async () => {
    const client = await first.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      const result = await client.query(sql, values);
      if (sql.includes('SELECT auth_deleted_at FROM') && sql.includes('receipt_hash=$1')) {
        assert.equal((await other.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt })).status, 'confirmed');
      }
      return result;
    } };
  } } as unknown as Pool;
  assert.deepEqual(await new PostgresCaseRepository(wrapped).readAccountDeletionReceipt(receipt),
    { status: 'awaiting_confirmation', applicationDataDeleted: false, providerIdentityDeleted: false });
  assert.equal((await repo.readAccountDeletionReceipt(receipt))?.status, 'auth_pending');
});

test('confirmation expiry during erasure rolls back rows, closure and job together', async () => {
  const snapshot = await create(repo), receipt = token(); await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: receipt });
  await admin.query(`CREATE FUNCTION safeathome_private.delay_lifecycle_test() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN PERFORM pg_sleep(0.6); RETURN OLD; END $$;
    CREATE TRIGGER delay_lifecycle_test AFTER DELETE ON safeathome_private.cases
    FOR EACH ROW EXECUTE FUNCTION safeathome_private.delay_lifecycle_test();
    UPDATE safeathome_private.account_deletion_previews SET expires_at=clock_timestamp()+interval '500 milliseconds'`);
  try { assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt }), { status: 'expired' }); }
  finally { await admin.query('DROP TRIGGER delay_lifecycle_test ON safeathome_private.cases; DROP FUNCTION safeathome_private.delay_lifecycle_test()'); }
  assert.deepEqual(await repo.loadForUser(OWNER, snapshot.caseId), snapshot);
  assert.equal(await repo.isAccountClosed(OWNER), false); assert.equal(await maintenance.pendingAuthDeletionCount(), 0);
  assert.deepEqual(await quota(), { case_count: 1, asset_count: 0, artifact_count: 0, stored_bytes: 0 });
});

test('closure atomically purges application data, enqueues one job, and gates every repository family', async () => {
  const { snapshot, image, packet, exported } = await populated();
  const bob = await create(repo, OTHER), receipt = await close();
  const pending = { status: 'auth_pending', applicationDataDeleted: true, providerIdentityDeleted: false };
  assert.deepEqual(await repo.readAccountDeletionReceipt(receipt), pending);
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt }), { status: 'confirmed', deletion: pending });
  assert.deepEqual(await repo.confirmAccountDeletion({ userId: OWNER, tokenHash: token() }), { status: 'not_found' });
  assert.equal(await repo.isAccountClosed(OWNER), true); assert.equal(await repo.isAccountClosed(OTHER), false);
  await assert.rejects(repo.loadForUser(OWNER, snapshot.caseId), AccountClosedError);
  await assert.rejects(repo.createForUser(OWNER, draft()), AccountClosedError);
  await assert.rejects(repo.replaceIfCurrent(OWNER, snapshot.caseId, snapshot.revision, draft(snapshot.caseId)), AccountClosedError);
  await assert.rejects(repo.saveMatchIfCurrent(OWNER, snapshot.caseId, snapshot.revision, {} as never), AccountClosedError);
  await assert.rejects(repo.saveFormAnswersIfCurrent(answerInput(snapshot, 1)), AccountClosedError);
  await assert.rejects(repo.loadFormAnswersForUser(OWNER, snapshot.caseId, FORM_CONTEXT.programId), AccountClosedError);
  await assert.rejects(repo.createPacketIfCurrent(packet), AccountClosedError);
  await assert.rejects(repo.saveEvidenceIfCurrent(image), AccountClosedError);
  await assert.rejects(repo.readEvidenceCatalogForUser(OWNER, snapshot.caseId), AccountClosedError);
  await assert.rejects(repo.publishExportIfCurrent(exported), AccountClosedError);
  await assert.rejects(repo.readExportForUser({ userId: OWNER, caseId: snapshot.caseId, artifactId: exported.artifact.metadata.artifactId }), AccountClosedError);
  assert.deepEqual(await repo.loadForUser(OTHER, bob.caseId), bob);
  assert.deepEqual(await quota(), { case_count: 1, asset_count: 0, artifact_count: 0, stored_bytes: 0 });
  assert.equal(await maintenance.pendingAuthDeletionCount(), 1);
  const client = await first.connect();
  try {
    await client.query('BEGIN'); await client.query("SELECT set_config('safeathome.user_id',$1,true)", [OWNER]);
    const replacement = { ...draft(), revision: 1 };
    await assert.rejects(client.query('INSERT INTO safeathome_private.cases(case_id,owner_id,revision,snapshot) VALUES($1,$2,1,$3::jsonb)',
      [replacement.caseId, OWNER, JSON.stringify(replacement)]), { code: '42501' });
  } finally { await client.query('ROLLBACK'); client.release(); }
});

test('Auth job lease ownership, retry backoff, completion and receipt survive a database restart', async () => {
  await create(repo); const receipt = await close();
  await cluster.restart(); pools();
  assert.equal(await repo.isAccountClosed(OWNER), true);
  const jobs = await maintenance.claimAuthDeletionJobs(1); assert.equal(jobs.length, 1);
  assert.equal(jobs[0].userId, OWNER);
  assert.deepEqual(await maintenance.claimAuthDeletionJobs(1), []);
  assert.equal(await maintenance.finishAuthDeletionJob({ ...jobs[0], leaseToken: randomUUID(), outcome: 'deleted' }), false);
  assert.equal(await maintenance.finishAuthDeletionJob({ ...jobs[0], outcome: 'retry' }), true);
  assert.deepEqual(await maintenance.claimAuthDeletionJobs(1), []);
  await admin.query("UPDATE safeathome_private.auth_deletion_jobs SET next_attempt_at=clock_timestamp()-interval '1 second'");
  const retry = (await maintenance.claimAuthDeletionJobs(1))[0]; assert.notEqual(retry.leaseToken, jobs[0].leaseToken);
  assert.equal(await maintenance.finishAuthDeletionJob({ ...jobs[0], outcome: 'deleted' }), false);
  assert.equal(await maintenance.finishAuthDeletionJob({ ...retry, outcome: 'deleted' }), true);
  assert.equal(await maintenance.pendingAuthDeletionCount(), 0);
  assert.deepEqual(await repo.readAccountDeletionReceipt(receipt), { status: 'complete', applicationDataDeleted: true, providerIdentityDeleted: true });
  assert.equal((await admin.query('SELECT raw_user_id FROM safeathome_private.auth_deletion_jobs')).rows[0].raw_user_id, null);
});

test('runtime RLS cannot enumerate other lifecycle rows, purge globally or claim Auth jobs', async () => {
  await create(repo); const receipt = await close();
  for (const table of ['deleted_cases','closed_accounts','account_deletion_previews']) {
    assert.equal((await first.query(`SELECT count(*) AS count FROM safeathome_private.${table}`)).rows[0].count, '0');
  }
  await assert.rejects(first.query('SELECT * FROM safeathome_private.auth_deletion_jobs'), { code: '42501' });
  await assert.rejects(new PostgresLifecycleMaintenance(first).sweepRetention(), { code: '42501' });
  await assert.rejects(new PostgresLifecycleMaintenance(first).claimAuthDeletionJobs(1), { code: '42501' });
  await assert.rejects(new PostgresLifecycleMaintenance(first).pendingAuthDeletionCount(), { code: '42501' });
  assert.equal(await repo.readAccountDeletionReceipt(token()), null);
  assert.equal((await repo.readAccountDeletionReceipt(receipt))?.status, 'auth_pending');
  assert.equal((await first.query('SELECT count(*) AS count FROM safeathome_private.closed_accounts')).rows[0].count, '0');
});

test('runtime cannot retarget the privileged Auth job or forge provider completion/leases', async () => {
  await close();
  await admin.query('DELETE FROM safeathome_private.auth_deletion_jobs');
  const client = await first.connect();
  try {
    for (const [query, values, code] of [
      ['INSERT INTO safeathome_private.auth_deletion_jobs(owner_hash,raw_user_id) VALUES($1,$2)', [hash(OWNER), OTHER], '23514'],
      ['INSERT INTO safeathome_private.auth_deletion_jobs(owner_hash,raw_user_id,lease_token,lease_until) VALUES($1,$2,$3,clock_timestamp())', [hash(OWNER), OWNER, randomUUID()], '42501'],
      ['INSERT INTO safeathome_private.closed_accounts(owner_hash,closed_at,receipt_expires_at,auth_deleted_at) VALUES($1,clock_timestamp(),clock_timestamp(),clock_timestamp())', [hash(OWNER)], '42501'],
    ] as const) {
      await client.query('BEGIN'); await client.query("SELECT set_config('safeathome.user_id',$1,true)", [OWNER]);
      await assert.rejects(client.query(query, [...values]), { code });
      await client.query('ROLLBACK');
    }
  } finally { await client.query('ROLLBACK'); client.release(); }
  assert.equal(await maintenance.pendingAuthDeletionCount(), 0);
});

test('closure rollback restores private rows, quotas, identity availability and pending status', async () => {
  const { snapshot } = await populated(); const beforeQuota = await quota(), receipt = token();
  await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: receipt });
  await admin.query(`CREATE FUNCTION safeathome_private.fail_lifecycle_test() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Fictional rollback'; END $$;
    CREATE TRIGGER fail_lifecycle_test AFTER INSERT ON safeathome_private.auth_deletion_jobs
    FOR EACH ROW EXECUTE FUNCTION safeathome_private.fail_lifecycle_test()`);
  try { await assert.rejects(repo.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt })); }
  finally { await admin.query('DROP TRIGGER fail_lifecycle_test ON safeathome_private.auth_deletion_jobs; DROP FUNCTION safeathome_private.fail_lifecycle_test()'); }
  assert.deepEqual(await quota(), beforeQuota);
  assert.deepEqual(await repo.loadForUser(OWNER, snapshot.caseId), snapshot);
  assert.equal(await repo.isAccountClosed(OWNER), false);
  assert.equal(await maintenance.pendingAuthDeletionCount(), 0);
  assert.equal((await admin.query('SELECT count(*) AS count FROM safeathome_private.deleted_cases')).rows[0].count, '0');
  assert.equal((await repo.readAccountDeletionReceipt(receipt))?.status, 'awaiting_confirmation');
});

test('a queued stale write cannot recreate data after closure wins the shared write lock', async () => {
  await create(repo); const receipt = token(); await repo.prepareAccountDeletion({ userId: OWNER, tokenHash: receipt });
  const blocker = await admin.connect();
  await blocker.query('BEGIN'); await blocker.query('SELECT 1 FROM safeathome_private.repository_quota FOR UPDATE');
  const closing = repo.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt });
  try {
    const deadline = Date.now() + 3000;
    while (!(await admin.query("SELECT 1 FROM pg_stat_activity WHERE application_name='lifecycle-first' AND wait_event_type='Lock'")).rowCount) {
      if (Date.now() > deadline) throw new Error('Expected lock wait.'); await delay(10);
    }
    const writing = other.createForUser(OWNER, draft());
    const rejected = assert.rejects(writing, AccountClosedError);
    await blocker.query('COMMIT');
    assert.equal((await closing).status, 'confirmed'); await rejected;
  } finally { await blocker.query('ROLLBACK'); blocker.release(); }
  assert.equal((await admin.query('SELECT count(*) AS count FROM safeathome_private.cases')).rows[0].count, '0');
});

test('retention reclaims all sixteen active export slots without reusing generation keys or deleting photos', async () => {
  const snapshot = await create(repo); await repo.saveEvidenceIfCurrent(await imageInput(snapshot));
  const publications = [];
  for (let index = 0; index < 16; index++) {
    const input = await publication(repo, snapshot); publications.push(input);
    assert.equal((await repo.publishExportIfCurrent(input)).status, 'saved');
  }
  assert.equal((await repo.publishExportIfCurrent(await publication(repo, snapshot))).status, 'quota_exceeded');
  const beforeQuota = await quota();
  for (const input of publications) {
    const expired = new Date(Date.parse(input.artifact.metadata.generatedAt) + 100).toISOString();
    await admin.query(`UPDATE safeathome_private.exports SET expires_at=$2::timestamptz,
      metadata=jsonb_set(metadata,'{expiresAt}',to_jsonb($2::text)) WHERE artifact_id=$1`, [input.artifact.metadata.artifactId, expired]);
  }
  const report = await maintenance.sweepRetention();
  assert.equal(report.expiredExports, 16); assert.equal(report.releasedBytes, beforeQuota.stored_bytes - (await imageInput(snapshot)).image.byteLength);
  assert.equal((await quota()).artifact_count, 0); assert.equal((await quota()).asset_count, 1);
  assert.equal((await repo.readEvidenceCatalogForUser(OWNER, snapshot.caseId)).status, 'found');
  const compact = (await admin.query('SELECT metadata,bindings,bytes FROM safeathome_private.exports LIMIT 1')).rows[0];
  assert.deepEqual(compact, { metadata: null, bindings: null, bytes: null });
  const fresh = await publication(repo, snapshot);
  fresh.generationKey = publications[0].generationKey;
  assert.equal((await repo.publishExportIfCurrent(fresh)).status, 'generation_conflict');
  assert.equal((await repo.readExportForUser({ userId: OWNER, caseId: snapshot.caseId,
    artifactId: publications[0].artifact.metadata.artifactId })).status, 'expired');
  fresh.generationKey = randomUUID(); assert.equal((await repo.publishExportIfCurrent(fresh)).status, 'saved');
  assert.equal((await maintenance.sweepRetention()).releasedBytes, 0);
});

test('invalidation releases active quota exactly once and retention expires only capabilities', async () => {
  const { snapshot } = await populated();
  const before = await quota(); assert.equal(before.artifact_count, 1);
  assert.equal((await repo.replaceIfCurrent(OWNER, snapshot.caseId, snapshot.revision, draft(snapshot.caseId))).status, 'saved');
  const invalidated = await quota(); assert.equal(invalidated.artifact_count, 0);
  const report = await maintenance.sweepRetention(); assert.equal(report.expiredExports, 1); assert.equal(report.releasedBytes, 0);
  assert.deepEqual(await quota(), invalidated);
  await repo.prepareAccountDeletion({ userId: OTHER, tokenHash: token() });
  const receipt = await close();
  await admin.query("UPDATE safeathome_private.closed_accounts SET receipt_expires_at=clock_timestamp()-interval '1 second'; UPDATE safeathome_private.account_deletion_previews SET expires_at=clock_timestamp()-interval '1 second'");
  const expired = await maintenance.sweepRetention(); assert.equal(expired.expiredReceipts, 1); assert.equal(expired.expiredPreviews, 1);
  assert.equal(await repo.readAccountDeletionReceipt(receipt), null); assert.equal(await repo.isAccountClosed(OWNER), true);
  assert.equal(await maintenance.pendingAuthDeletionCount(), 1);
});

test('migration upgrades existing live/invalidated exports and preserves only minimal retry receipts', async () => {
  const database = await TestPostgres.start();
  try {
    const owner = database.pool(), snapshot = { ...draft(), revision: 1 };
    await owner.query(await readFile(new URL('../../migrations/001_private_repository.sql', import.meta.url), 'utf8'));
    await owner.query('INSERT INTO safeathome_private.cases(case_id,owner_id,revision,snapshot) VALUES($1,$2,1,$3::jsonb)',
      [snapshot.caseId, OWNER, JSON.stringify(snapshot)]);
    const bytes = Buffer.from('%PDF-fictional migration bytes');
    for (const invalidated of [false, true]) {
      const id = randomUUID(), metadata = { artifactId: id, caseId: snapshot.caseId, byteLength: bytes.length,
        expiresAt: iso(-1000), privateTestText: 'Fictional private metadata removed by retention' };
      await owner.query(`INSERT INTO safeathome_private.exports(artifact_id,case_id,generation_key,bindings,metadata,bytes,invalidated,last_checked_at)
        VALUES($1,$2,$3,'{}'::jsonb,$4::jsonb,$5,$6,$7)`, [id, snapshot.caseId, randomUUID(), JSON.stringify(metadata), invalidated ? null : bytes, invalidated, iso(-2000)]);
    }
    await owner.query('UPDATE safeathome_private.repository_quota SET case_count=1,artifact_count=2,stored_bytes=$1', [bytes.length]);
    await owner.query(await readFile(new URL('../../migrations/002_retention_deletion.sql', import.meta.url), 'utf8'));
    assert.equal((await owner.query('SELECT artifact_count FROM safeathome_private.repository_quota')).rows[0].artifact_count, '1');
    const report = await new PostgresLifecycleMaintenance(owner).sweepRetention();
    assert.equal(report.expiredExports, 2); assert.equal(report.releasedBytes, bytes.length);
    assert.deepEqual((await owner.query('SELECT artifact_count,stored_bytes FROM safeathome_private.repository_quota')).rows[0], { artifact_count: '0', stored_bytes: '0' });
    const rows = (await owner.query('SELECT metadata,bindings,bytes,invalidated FROM safeathome_private.exports')).rows;
    assert.equal(rows.length, 2); assert.ok(rows.every(row => row.metadata === null && row.bindings === null && row.bytes === null && row.invalidated));
  } finally { await database.close(); }
});

test('operator maintenance functions work for a non-superuser owner despite FORCE RLS', async () => {
  const database = await TestPostgres.start();
  try {
    const superuser = database.pool();
    await superuser.query('CREATE ROLE lifecycle_migrator LOGIN CREATEROLE NOSUPERUSER NOBYPASSRLS');
    await superuser.query('GRANT CREATE,CONNECT ON DATABASE postgres TO lifecycle_migrator WITH GRANT OPTION');
    const operator = database.pool('lifecycle_migrator'); await applyMigrations(operator);
    await superuser.query('CREATE ROLE lifecycle_client LOGIN NOSUPERUSER NOBYPASSRLS IN ROLE safeathome_app');
    const repository = new PostgresCaseRepository(database.pool('lifecycle_client'));
    assert.equal((await repository.createForUser(OWNER, draft())).status, 'saved');
    const receipt = token(); await repository.prepareAccountDeletion({ userId: OWNER, tokenHash: receipt });
    assert.equal((await repository.confirmAccountDeletion({ userId: OWNER, tokenHash: receipt })).status, 'confirmed');
    const operatorTasks = new PostgresLifecycleMaintenance(operator);
    assert.equal(await operatorTasks.pendingAuthDeletionCount(), 1);
    const job = (await operatorTasks.claimAuthDeletionJobs(1))[0];
    assert.equal(await operatorTasks.finishAuthDeletionJob({ ...job, outcome: 'deleted' }), true);
    assert.equal((await repository.readAccountDeletionReceipt(receipt))?.status, 'complete');
    assert.equal((await operatorTasks.sweepRetention()).releasedBytes, 0);
  } finally { await database.close(); }
});
