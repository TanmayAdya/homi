import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import sharp from 'sharp';
import { sanitizeEvidenceImage } from '../../src/evidence/image-sanitizer.ts';
import type { SanitizedEvidenceImage } from '../../src/evidence/types.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { PRIVATE_BYTEA_CHUNK_BYTES as CHUNK } from '../../src/storage/private-bytea.ts';
import { TestPostgres } from './harness.ts';
import { OWNER, OTHER, FORM_CONTEXT, create, imageInput, publication } from './fixtures.ts';

let cluster: TestPostgres, admin: Pool, runtime: Pool, repo: PostgresCaseRepository;
let largeImage: SanitizedEvidenceImage;
before(async () => {
  cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query('CREATE ROLE bytea_test_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  runtime = cluster.pool('bytea_test_runtime'); repo = new PostgresCaseRepository(runtime);
  const pixels = Buffer.alloc(800 * 600 * 3); let state = 0x7142a31b;
  for (let index = 0; index < pixels.length; index++) {
    state ^= state << 13; state ^= state >>> 17; state ^= state << 5; pixels[index] = state & 255;
  }
  largeImage = await sanitizeEvidenceImage(await sharp(pixels, { raw: { width: 800, height: 600, channels: 3 } }).png().toBuffer());
  assert.ok(largeImage.bytes.length > CHUNK);
});
beforeEach(async () => {
  await admin.query(`TRUNCATE safeathome_private.cases,safeathome_private.matches,safeathome_private.packets,
    safeathome_private.form_answers,safeathome_private.evidence,safeathome_private.exports,safeathome_private.request_history,
    safeathome_private.deleted_cases,safeathome_private.closed_accounts,safeathome_private.account_deletion_previews,safeathome_private.auth_deletion_jobs;
    UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async () => { await cluster?.close(); });

async function seeded() {
  const snapshot = await create(repo);
  assert.equal((await repo.saveEvidenceIfCurrent({ ...await imageInput(snapshot), image: largeImage })).status, 'saved');
  const input = { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, expectedCatalogRevision: 1,
    evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 };
  const selection = { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, expectedCatalogRevision: 1,
    programId: FORM_CONTEXT.programId, selections: [{ evidenceId: input.evidenceId, expectedEvidenceRevision: 1, reviewedForExport: true as const }] };
  return { snapshot, input, selection };
}
async function published() {
  const state = await seeded(), output = await publication(repo, state.snapshot);
  const bytes = Buffer.alloc(2 * CHUNK + 37);
  for (let index = 0; index < bytes.length; index++) bytes[index] = (index * 73 + 19) & 255;
  bytes.write('%PDF-1.7\n'); output.artifact.bytes = bytes;
  output.artifact.metadata.byteLength = bytes.length;
  output.artifact.metadata.sha256 = createHash('sha256').update(bytes).digest('hex');
  assert.equal((await repo.publishExportIfCurrent(output)).status, 'saved');
  return { ...state, output, request: { userId: OWNER, caseId: state.snapshot.caseId,
    artifactId: output.artifact.metadata.artifactId, contextFingerprint: output.contextFingerprint, checkedAt: new Date().toISOString() } };
}
function observed(afterQuery?: (sql: string) => Promise<void>) {
  const chunkQueries: number[][] = [];
  const pool = { connect: async () => {
    const client = await runtime.connect();
    return { release: (broken?: boolean) => client.release(broken), query: async (sql: string, values?: unknown[]) => {
      assert.equal(/^SELECT (?:\*|bytes) FROM safeathome_private\.(?:evidence|exports)\b/.test(sql), false);
      const result = await client.query(sql, values);
      if (sql.includes('substring(payload.bytes')) {
        const sizes = result.rows.map(row => row.chunk.length);
        assert.ok(sizes.length <= 32); assert.ok(sizes.every(size => size > 0 && size <= CHUNK));
        assert.deepEqual(result.rows.map(row => row.chunk_index), sizes.map((_, index) => index));
        chunkQueries.push(sizes);
      }
      await afterQuery?.(sql); return result;
    } };
  } } as unknown as Pool;
  return { repo: new PostgresCaseRepository(pool), chunkQueries };
}

test('PostgreSQL private image reads and export selections return exact detached multi-chunk PNG bytes', async () => {
  const { input, selection } = await seeded(), tracked = observed();
  const read = await tracked.repo.readEvidenceForUser(input);
  assert.equal(read.status, 'found'); if (read.status !== 'found') throw new Error('Missing fictional image.');
  assert.deepEqual(read.asset.bytes, largeImage.bytes);
  assert.equal(tracked.chunkQueries.length, 1); assert.ok(tracked.chunkQueries[0].length > 1);
  read.asset.bytes[100] ^= 255;
  const selected = await tracked.repo.loadExportSnapshotForUser(selection);
  assert.equal(selected.status, 'found'); if (selected.status !== 'found') throw new Error('Missing fictional selection.');
  assert.deepEqual(selected.snapshot.assets[0].bytes, largeImage.bytes); assert.equal(tracked.chunkQueries.length, 2);
  selected.snapshot.assets[0].bytes[100] ^= 255;
  const again = await tracked.repo.readEvidenceForUser(input);
  assert.equal(again.status, 'found'); if (again.status === 'found') assert.deepEqual(again.asset.bytes, largeImage.bytes);
});

test('PostgreSQL current PDF downloads preserve arbitrary bytes across chunks and remain detached', async () => {
  const { output, request } = await published(), tracked = observed();
  const read = await tracked.repo.readExportForUserIfCurrent(request);
  assert.equal(read.status, 'found'); if (read.status !== 'found') throw new Error('Missing fictional PDF.');
  assert.deepEqual(read.artifact.bytes, Uint8Array.from(output.artifact.bytes));
  assert.deepEqual(tracked.chunkQueries, [[CHUNK, CHUNK, 37]]);
  read.artifact.bytes[CHUNK + 1] ^= 255;
  const again = await tracked.repo.readExportForUserIfCurrent(request);
  assert.equal(again.status, 'found'); if (again.status === 'found') assert.deepEqual(again.artifact.bytes, Uint8Array.from(output.artifact.bytes));
});

test('owner, stale revision/context and expiry denials happen before private binary retrieval', async () => {
  const { input, selection, request, output } = await published(), tracked = observed();
  assert.deepEqual(await tracked.repo.readEvidenceForUser({ ...input, userId: OTHER }), { status: 'not_found' });
  assert.deepEqual(await tracked.repo.readEvidenceForUser({ ...input, expectedEvidenceRevision: 2 }), { status: 'evidence_conflict' });
  assert.deepEqual(await tracked.repo.loadExportSnapshotForUser({ ...selection, userId: OTHER }), { status: 'not_found' });
  assert.deepEqual(await tracked.repo.loadExportSnapshotForUser({ ...selection, expectedCatalogRevision: 2 }), { status: 'evidence_conflict' });
  assert.deepEqual(await tracked.repo.readExportForUserIfCurrent({ ...request, userId: OTHER }), { status: 'not_found' });
  assert.deepEqual(await tracked.repo.readExportForUserIfCurrent({ ...request, contextFingerprint: 'a'.repeat(64) }), { status: 'generation_conflict' });
  assert.deepEqual(await tracked.repo.readExportForUserIfCurrent({ ...request, checkedAt: output.artifact.metadata.expiresAt }), { status: 'expired' });
  assert.equal(tracked.chunkQueries.length, 0);
});

test('a concurrent replacement cannot mix chunk bytes with another evidence revision', async () => {
  const { input, snapshot } = await seeded(); let changed = false;
  const tracked = observed(async sql => {
    if (!changed && sql.startsWith('SELECT evidence_id,') && sql.includes('FROM safeathome_private.evidence')) {
      changed = true;
      assert.equal((await repo.saveEvidenceIfCurrent(await imageInput(snapshot, 1, input.evidenceId, 1))).status, 'saved');
    }
  });
  const result = await tracked.repo.readEvidenceForUser(input);
  assert.equal(changed, true); assert.equal(result.status, 'found');
  if (result.status === 'found') assert.deepEqual(result.asset.bytes, largeImage.bytes);
  assert.deepEqual(await repo.readEvidenceForUser(input), { status: 'evidence_conflict' });
});

test('chunked PostgreSQL image and PDF reads still reject corrupted stored digests', async () => {
  const { input, request } = await published();
  await admin.query('UPDATE safeathome_private.evidence SET bytes=set_byte(bytes,100,get_byte(bytes,100)#1) WHERE case_id=$1', [input.caseId]);
  await assert.rejects(repo.readEvidenceForUser(input));
  await admin.query('UPDATE safeathome_private.exports SET bytes=set_byte(bytes,100,get_byte(bytes,100)#1) WHERE case_id=$1', [input.caseId]);
  await assert.rejects(repo.readExportForUserIfCurrent(request));
});
