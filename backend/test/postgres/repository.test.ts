import assert from 'node:assert/strict';
import { before, beforeEach, after, test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import type { Pool, PoolClient } from 'pg';
import { applyMigrations, assertMigrationsCurrent } from '../../src/storage/migrate.ts';
import { assertRestrictedRuntimeRole } from '../../src/storage/postgres-pool.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { TestPostgres } from './harness.ts';
import { OWNER, OTHER, FORM_CONTEXT, EXPORT_CONTEXT, create, draft, answerInput, imageInput,
  iso, packetInput, publication } from './fixtures.ts';

let cluster: TestPostgres;
let admin: Pool;
let first: Pool;
let second: Pool;
let repo: PostgresCaseRepository;
let otherRepo: PostgresCaseRepository;
function openPools() {
  admin = cluster.pool();
  first = cluster.pool('sah_test_runtime', 'safeathome-first');
  second = cluster.pool('sah_test_runtime', 'safeathome-second');
  repo = new PostgresCaseRepository(first);
  otherRepo = new PostgresCaseRepository(second);
}
before(async () => {
  cluster = await TestPostgres.start();
  admin = cluster.pool();
  await applyMigrations(admin);
  await admin.query(`CREATE ROLE sah_test_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app`);
  openPools();
});
after(async () => { await cluster?.close(); });
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.cases, safeathome_private.matches, safeathome_private.packets,
    safeathome_private.form_answers, safeathome_private.evidence, safeathome_private.exports, safeathome_private.request_history,
    safeathome_private.deleted_cases, safeathome_private.closed_accounts,
    safeathome_private.account_deletion_previews, safeathome_private.auth_deletion_jobs;
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});

async function context(client: PoolClient, userId: string) {
  await client.query('BEGIN');
  await client.query("SELECT set_config('safeathome.user_id', $1, true)", [userId]);
}
async function quota() {
  return (await admin.query('SELECT case_count, asset_count, artifact_count, stored_bytes FROM safeathome_private.repository_quota')).rows[0];
}
async function waitForBlockedWriter(applicationName: string) {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    const waiting = await admin.query("SELECT 1 FROM pg_stat_activity WHERE application_name=$1 AND wait_event_type='Lock'", [applicationName]);
    if (waiting.rowCount) return;
    await delay(10);
  }
  throw new Error('The independent PostgreSQL writer did not reach the held lock.');
}

test('native server uses private Unix socket with durability enabled', async () => {
  const row = (await admin.query(`SELECT current_setting('server_version') AS version,
    current_setting('listen_addresses') AS listening, current_setting('fsync') AS fsync,
    current_setting('full_page_writes') AS full_page_writes,
    current_setting('synchronous_commit') AS synchronous_commit`)).rows[0];
  assert.match(row.version, /^\d+\./);
  assert.equal(row.listening, '');
  assert.equal(row.fsync, 'on'); assert.equal(row.full_page_writes, 'on'); assert.equal(row.synchronous_commit, 'on');
  const pids = await Promise.all([first.query('SELECT pg_backend_pid() AS id'), second.query('SELECT pg_backend_pid() AS id')]);
  assert.notEqual(pids[0].rows[0].id, pids[1].rows[0].id);
});

test('migration reruns are idempotent and runtime cannot migrate or bypass role checks', async () => {
  await applyMigrations(admin);
  await assertMigrationsCurrent(first);
  await assertRestrictedRuntimeRole(first);
  await assert.rejects(assertRestrictedRuntimeRole(admin));
  await assert.rejects(applyMigrations(first));
  const checksum = (await admin.query('SELECT checksum FROM safeathome_migrations.versions WHERE version=$1', ['001'])).rows[0].checksum;
  try {
    await admin.query('UPDATE safeathome_migrations.versions SET checksum=$1 WHERE version=$2', ['bad-checksum', '001']);
    await assert.rejects(assertMigrationsCurrent(first));
    await assert.rejects(applyMigrations(admin));
  } finally {
    await admin.query('UPDATE safeathome_migrations.versions SET checksum=$1 WHERE version=$2', [checksum, '001']);
  }
  await assertMigrationsCurrent(first);
});

test('runtime startup rejects inherited schema ownership even without table ownership', async () => {
  await admin.query('CREATE ROLE sah_test_schema_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS');
  await admin.query('GRANT sah_test_schema_owner TO sah_test_runtime');
  try {
    await admin.query('ALTER SCHEMA safeathome_private OWNER TO sah_test_schema_owner');
    await assert.rejects(assertRestrictedRuntimeRole(first));
  } finally {
    await admin.query('ALTER SCHEMA safeathome_private OWNER TO sah_test_admin');
    await admin.query('REVOKE sah_test_schema_owner FROM sah_test_runtime');
    await admin.query('DROP ROLE sah_test_schema_owner');
  }
  await assertRestrictedRuntimeRole(first);
});

test('runtime startup rejects inherited predefined filesystem privileges', async () => {
  await admin.query('GRANT pg_read_server_files TO sah_test_runtime');
  try { await assert.rejects(assertRestrictedRuntimeRole(first)); }
  finally { await admin.query('REVOKE pg_read_server_files FROM sah_test_runtime'); }
  await assertRestrictedRuntimeRole(first);
});

test('owner-scoped creation, read, collision and replacement stay isolated across two pools', async () => {
  const saved = await create(repo);
  assert.deepEqual(await otherRepo.loadForUser(OWNER, saved.caseId), saved);
  assert.equal(await otherRepo.loadForUser(OTHER, saved.caseId), null);
  const replacement = draft(saved.caseId); replacement.profile.city = 'Changed fictional city';
  assert.deepEqual(await otherRepo.replaceIfCurrent(OTHER, saved.caseId, 1, replacement), { status: 'not_found' });
  assert.deepEqual(await otherRepo.createForUser(OTHER, replacement), { status: 'id_unavailable' });
  assert.deepEqual(await otherRepo.createForUser(OWNER, replacement), { status: 'id_unavailable' });
  assert.equal((await repo.replaceIfCurrent(OWNER, saved.caseId, 1, replacement)).status, 'saved');
  assert.equal((await otherRepo.loadForUser(OWNER, saved.caseId))!.revision, 2);
  assert.equal((await otherRepo.loadForUser(OWNER, saved.caseId))!.profile.city, replacement.profile.city);
});

test('simultaneous compare-and-save transactions cannot both win one case revision', async () => {
  const saved = await create(repo);
  const left = draft(saved.caseId), right = draft(saved.caseId);
  left.profile.city = 'Left fictional edit'; right.profile.city = 'Right fictional edit';
  const results = await Promise.all([repo.replaceIfCurrent(OWNER, saved.caseId, 1, left),
    otherRepo.replaceIfCurrent(OWNER, saved.caseId, 1, right)]);
  assert.deepEqual(results.map(result => result.status).sort(), ['conflict', 'saved']);
  const current = await repo.loadForUser(OWNER, saved.caseId);
  assert.equal(current!.revision, 2);
  const winner = results.find(result => result.status === 'saved');
  assert.ok(winner && winner.status === 'saved'); assert.deepEqual(current, winner.snapshot);
});

test('RLS hides every private table with no identity and rejects another owner write', async () => {
  let alice = await create(repo);
  const bob = await create(repo, OTHER);
  assert.equal((await repo.saveFormAnswersIfCurrent(answerInput(alice))).status, 'saved');
  alice = (await repo.loadForUser(OWNER, alice.caseId))!;
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(alice))).status, 'saved');
  assert.equal((await repo.publishExportIfCurrent(await publication(repo, alice))).status, 'saved');
  assert.equal((await repo.createPacketIfCurrent(packetInput(alice))).status, 'saved');
  assert.equal(await repo.saveMatchIfCurrent(OWNER, alice.caseId, alice.revision, {
    schemaVersion: '1', caseId: alice.caseId, caseRevision: alice.revision,
    evaluatedAt: iso(), evaluationDate: iso().slice(0, 10), matches: [],
  }), 'saved');
  const tables = ['cases', 'matches', 'packets', 'form_answers', 'evidence', 'exports'];
  for (const table of tables) {
    assert.ok(Number((await admin.query(`SELECT count(*) AS count FROM safeathome_private.${table}`)).rows[0].count) > 0);
    assert.equal((await first.query(`SELECT count(*)::integer AS count FROM safeathome_private.${table}`)).rows[0].count, 0);
  }
  const client = await first.connect();
  try {
    await context(client, OWNER);
    const visible = await client.query('SELECT case_id FROM safeathome_private.cases WHERE case_id=ANY($1::text[])', [[alice.caseId, bob.caseId]]);
    assert.deepEqual(visible.rows, [{ case_id: alice.caseId }]);
    await client.query('ROLLBACK');
    await context(client, OTHER);
    assert.equal((await client.query('UPDATE safeathome_private.cases SET revision=revision WHERE case_id=$1', [alice.caseId])).rowCount, 0);
    await client.query('ROLLBACK');
    await context(client, OWNER);
    await assert.rejects(client.query('UPDATE safeathome_private.cases SET owner_id=$1 WHERE case_id=$2', [OTHER, alice.caseId]), { code: '42501' });
    await client.query('ROLLBACK');
    await context(client, OWNER);
    await client.query('SET LOCAL row_security=off');
    await assert.rejects(client.query('SELECT * FROM safeathome_private.cases'), { code: '42501' });
    await client.query('ROLLBACK');
  } finally { await client.query('ROLLBACK'); client.release(); }
  assert.equal(await repo.loadForUser(OTHER, alice.caseId), null);
  const protectedTables = await admin.query(`SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='safeathome_private' AND c.relkind='r'`);
  assert.equal(protectedTables.rows.length, 12);
  assert.ok(protectedTables.rows.every(row => row.relrowsecurity && row.relforcerowsecurity));
});

test('case, image bytes, reviewed answers, match, checklist and export survive server restart', async () => {
  let saved = await create(repo);
  const answer = answerInput(saved);
  assert.equal((await repo.saveFormAnswersIfCurrent(answer)).status, 'saved');
  saved = (await repo.loadForUser(OWNER, saved.caseId))!;
  const image = await imageInput(saved);
  const stored = await repo.saveEvidenceIfCurrent(image); assert.equal(stored.status, 'saved');
  const match = { schemaVersion: '1' as const, caseId: saved.caseId, caseRevision: saved.revision,
    evaluatedAt: iso(), evaluationDate: iso().slice(0, 10), matches: [] };
  assert.equal(await repo.saveMatchIfCurrent(OWNER, saved.caseId, saved.revision, match), 'saved');
  const packet = packetInput(saved);
  assert.equal((await repo.createPacketIfCurrent(packet)).status, 'saved');
  const exported = await publication(repo, saved);
  assert.equal((await repo.publishExportIfCurrent(exported)).status, 'saved');
  await cluster.restart(); openPools();
  await assertMigrationsCurrent(first); await assertRestrictedRuntimeRole(first);
  assert.deepEqual(await repo.loadForUser(OWNER, saved.caseId), saved);
  assert.deepEqual(await repo.loadFormAnswersForUser(OWNER, saved.caseId, FORM_CONTEXT.programId), answer.answers);
  const loadedImage = await repo.readEvidenceForUser({ ...image, expectedCatalogRevision: 1, expectedEvidenceRevision: 1 });
  assert.equal(loadedImage.status, 'found');
  if (loadedImage.status === 'found') assert.deepEqual(Buffer.from(loadedImage.asset.bytes), Buffer.from(image.image.bytes));
  const retry = await repo.createPacketIfCurrent({ ...packet, checkedAt: iso() });
  assert.equal(retry.status, 'reused'); if ('packet' in retry) assert.deepEqual(retry.packet, packet.packet);
  const client = await first.connect();
  try {
    await context(client, OWNER);
    assert.deepEqual((await client.query('SELECT response FROM safeathome_private.matches WHERE case_id=$1', [saved.caseId])).rows[0].response, match);
    await client.query('COMMIT');
  } finally { client.release(); }
  const download = { userId: OWNER, caseId: saved.caseId, artifactId: exported.artifact.metadata.artifactId,
    contextFingerprint: EXPORT_CONTEXT, checkedAt: iso() };
  const artifact = await repo.readExportForUserIfCurrent(download);
  assert.equal(artifact.status, 'found');
  if (artifact.status === 'found') {
    assert.deepEqual(artifact.artifact.metadata, exported.artifact.metadata);
    assert.deepEqual(Buffer.from(artifact.artifact.bytes), Buffer.from(exported.artifact.bytes));
  }
  assert.deepEqual(await otherRepo.readExportForUserIfCurrent({ ...download, userId: OTHER }), { status: 'not_found' });
  assert.equal((await otherRepo.readEvidenceForUser({ ...image, userId: OTHER, expectedCatalogRevision: 1, expectedEvidenceRevision: 1 })).status, 'not_found');
  assert.equal(await otherRepo.loadFormAnswersForUser(OTHER, saved.caseId, FORM_CONTEXT.programId), null);
});

test('database error rolls back answer write, case revision and derived invalidation together', async () => {
  const saved = await create(repo), input = answerInput(saved);
  const match = { schemaVersion: '1' as const, caseId: saved.caseId, caseRevision: 1, evaluatedAt: iso(), evaluationDate: iso().slice(0, 10), matches: [] };
  assert.equal(await repo.saveMatchIfCurrent(OWNER, saved.caseId, 1, match), 'saved');
  const before = await quota();
  await admin.query(`CREATE FUNCTION safeathome_private.fail_answer_fixture() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Fictional forced rollback'; END $$;
    CREATE TRIGGER fail_answer_fixture AFTER INSERT ON safeathome_private.form_answers
    FOR EACH ROW EXECUTE FUNCTION safeathome_private.fail_answer_fixture()`);
  try { await assert.rejects(repo.saveFormAnswersIfCurrent(input)); }
  finally { await admin.query('DROP TRIGGER fail_answer_fixture ON safeathome_private.form_answers; DROP FUNCTION safeathome_private.fail_answer_fixture()'); }
  assert.deepEqual(await repo.loadForUser(OWNER, saved.caseId), saved);
  assert.equal(await repo.loadFormAnswersForUser(OWNER, saved.caseId, FORM_CONTEXT.programId), null);
  assert.deepEqual(await quota(), before);
  assert.deepEqual((await admin.query('SELECT response FROM safeathome_private.matches WHERE case_id=$1', [saved.caseId])).rows[0].response, match);
  assert.equal((await repo.saveFormAnswersIfCurrent(input)).status, 'saved');
});

test('same catalog revision permits only one independent image writer and tombstones persist', async () => {
  const saved = await create(repo);
  const left = await imageInput(saved), right = await imageInput(saved, 0, 'fictional-photo-b');
  const results = await Promise.all([repo.saveEvidenceIfCurrent(left), otherRepo.saveEvidenceIfCurrent(right)]);
  assert.deepEqual(results.map(result => result.status).sort(), ['evidence_conflict', 'saved']);
  const winner = results.find(result => result.status === 'saved'); assert.ok(winner && winner.status === 'saved');
  const id = winner.asset.descriptor.evidenceId;
  const removed = await otherRepo.deleteEvidenceIfCurrent({ userId: OWNER, caseId: saved.caseId, revision: 1,
    expectedCatalogRevision: 1, evidenceId: id, expectedEvidenceRevision: 1 });
  assert.deepEqual(removed, { status: 'deleted', evidenceRevision: 2, catalogRevision: 2 });
  await cluster.restart(); openPools();
  const catalog = await repo.readEvidenceCatalogForUser(OWNER, saved.caseId);
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') { assert.equal(catalog.catalog.catalogRevision, 2); assert.deepEqual(catalog.catalog.evidence, []); }
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(saved, 2, id, 0))).status, 'evidence_conflict');
  assert.equal((await repo.readEvidenceForUser({ userId: OWNER, caseId: saved.caseId, revision: 1,
    expectedCatalogRevision: 2, evidenceId: id, expectedEvidenceRevision: 2 })).status, 'not_found');
});

test('same generation key is atomic across pools and changed context cannot reuse it', async () => {
  const saved = await create(repo);
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(saved))).status, 'saved');
  const input = await publication(repo, saved);
  const results = await Promise.all([repo.publishExportIfCurrent(input), otherRepo.publishExportIfCurrent(structuredClone(input))]);
  assert.deepEqual(results.map(result => result.status).sort(), ['reused', 'saved']);
  for (const result of results) { assert.ok('artifact' in result); assert.deepEqual(result.artifact, input.artifact.metadata); }
  const changed = structuredClone(input); changed.contextFingerprint = 'e'.repeat(64);
  changed.artifact.metadata.exportContextId = changed.contextFingerprint; changed.checkedAt = iso();
  assert.equal((await repo.publishExportIfCurrent(changed)).status, 'generation_conflict');
  const before = await quota();
  const bad = structuredClone(input); bad.generationKey = 'new-key-bad-digest'; bad.artifact.bytes[0] = 0;
  await assert.rejects(repo.publishExportIfCurrent(bad));
  assert.deepEqual(await quota(), before);
});

test('case replacement and image write share one atomic link-validation boundary', async () => {
  const saved = await create(repo), replacement = draft(saved.caseId); replacement.findings = [];
  const [caseResult, imageResult] = await Promise.all([
    repo.replaceIfCurrent(OWNER, saved.caseId, 1, replacement),
    otherRepo.saveEvidenceIfCurrent(await imageInput(saved)),
  ]);
  if (caseResult.status === 'saved') {
    assert.equal(imageResult.status, 'conflict');
    assert.deepEqual(caseResult.snapshot.findings, []);
  } else {
    assert.equal(caseResult.status, 'evidence_conflict'); assert.equal(imageResult.status, 'saved');
    assert.equal((await repo.loadForUser(OWNER, saved.caseId))!.revision, 1);
  }
});

test('export expiry is rechecked after a real database lock wait before publication', async () => {
  const saved = await create(repo);
  await repo.saveEvidenceIfCurrent(await imageInput(saved));
  const input = await publication(repo, saved, 1, 350);
  const blocker = await admin.connect();
  const waiting = new PostgresCaseRepository(cluster.pool('sah_test_runtime', 'safeathome-expiry-writer'));
  await blocker.query('BEGIN');
  await blocker.query('SELECT singleton FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE');
  const result = waiting.publishExportIfCurrent(input);
  try {
    await waitForBlockedWriter('safeathome-expiry-writer');
    await delay(Math.max(0, Date.parse(input.artifact.metadata.expiresAt) - Date.now() + 30));
  } finally { await blocker.query('ROLLBACK'); blocker.release(); }
  assert.equal((await result).status, 'expired');
  assert.equal((await admin.query('SELECT count(*)::integer AS count FROM safeathome_private.exports WHERE artifact_id=$1', [input.artifact.metadata.artifactId])).rows[0].count, 0);
});

test('checklist expiry is rechecked after a real database lock wait', async () => {
  const saved = await create(repo), input = packetInput(saved, 350);
  const blocker = await admin.connect();
  const waiting = new PostgresCaseRepository(cluster.pool('sah_test_runtime', 'safeathome-packet-writer'));
  await blocker.query('BEGIN');
  await blocker.query('SELECT singleton FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE');
  const result = waiting.createPacketIfCurrent(input);
  try {
    await waitForBlockedWriter('safeathome-packet-writer');
    await delay(Math.max(0, Date.parse(input.packet.recheckAfter!) - Date.now() + 30));
  } finally { await blocker.query('ROLLBACK'); blocker.release(); }
  assert.equal((await result).status, 'generation_conflict');
});

test('case saves invalidate stored export bytes and retain generation-key conflict', async () => {
  const saved = await create(repo);
  await repo.saveEvidenceIfCurrent(await imageInput(saved));
  const input = await publication(repo, saved);
  assert.equal((await repo.publishExportIfCurrent(input)).status, 'saved');
  const replacement = draft(saved.caseId); replacement.profile.city = 'Reviewed changed city';
  assert.equal((await otherRepo.replaceIfCurrent(OWNER, saved.caseId, 1, replacement)).status, 'saved');
  const raw = (await admin.query('SELECT bytes, invalidated FROM safeathome_private.exports WHERE artifact_id=$1', [input.artifact.metadata.artifactId])).rows[0];
  assert.equal(raw.bytes, null); assert.equal(raw.invalidated, true);
  assert.equal((await repo.readExportForUserIfCurrent({ userId: OWNER, caseId: saved.caseId,
    artifactId: input.artifact.metadata.artifactId, contextFingerprint: EXPORT_CONTEXT, checkedAt: iso() })).status, 'conflict');
});

test('quota counters match durable rows and concurrent create respects final slot', async () => {
  const populated = await create(repo);
  assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(populated))).status, 'saved');
  assert.equal((await repo.publishExportIfCurrent(await publication(repo, populated))).status, 'saved');
  const before = await quota();
  const bytes = (await admin.query(`SELECT
    (SELECT coalesce(sum(octet_length(bytes)),0) FROM safeathome_private.evidence) +
    (SELECT coalesce(sum(octet_length(bytes)),0) FROM safeathome_private.exports) AS count`)).rows[0].count;
  assert.equal(String(before.stored_bytes), String(bytes));
  for (let count = Number(before.case_count); count < 63; count++) await create(repo, `quota-owner-${count}`);
  const results = await Promise.all([repo.createForUser(OWNER, draft()), otherRepo.createForUser(OTHER, draft())]);
  assert.deepEqual(results.map(result => result.status).sort(), ['quota_exceeded', 'saved']);
  assert.equal(Number((await quota()).case_count), 64);
  assert.equal((await admin.query('SELECT count(*)::integer AS count FROM safeathome_private.cases')).rows[0].count, 64);
});
