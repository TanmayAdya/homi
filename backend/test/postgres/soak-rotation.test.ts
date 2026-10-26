import assert from 'node:assert/strict';
import { test } from 'node:test';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { SOAK_PDF_GENERATION_ITERATIONS, SOAK_SESSION_ITERATIONS } from '../../tool/linux-memory/protocol.ts';
import { TestPostgres } from './harness.ts';
import { create, draft, imageInput, iso, OWNER, OTHER, publication } from './fixtures.ts';

test('soak generation rotation releases prior PDF bytes and active quota across all 61 publications', async () => {
  const cluster = await TestPostgres.start();
  try {
    const admin = cluster.pool(); await applyMigrations(admin);
    await admin.query('CREATE ROLE sah_soak_rotation_test LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
    const repo = new PostgresCaseRepository(cluster.pool('sah_soak_rotation_test'));
    let snapshot = await create(repo);
    const photo = await imageInput(snapshot);
    assert.equal((await repo.saveEvidenceIfCurrent(photo)).status, 'saved');
    let output = await publication(repo, snapshot), saved = 0, reused = 0;
    for (let index = 0; index < SOAK_SESSION_ITERATIONS; index++) {
      const newGeneration = index % SOAK_PDF_GENERATION_ITERATIONS === 0;
      if (newGeneration && index > 0) {
        const oldArtifact = output.artifact.metadata.artifactId;
        const replacement = await repo.replaceIfCurrent(OWNER, snapshot.caseId, snapshot.revision, draft(snapshot.caseId));
        assert.equal(replacement.status, 'saved');
        if (replacement.status !== 'saved') throw new Error('Synthetic case renewal failed.');
        snapshot = replacement.snapshot;
        const old = (await admin.query('SELECT bytes FROM safeathome_private.exports WHERE artifact_id=$1', [oldArtifact])).rows[0];
        assert.equal(old.bytes, null);
        const quota = (await admin.query('SELECT artifact_count,stored_bytes FROM safeathome_private.repository_quota')).rows[0];
        assert.equal(Number(quota.artifact_count), 0); assert.equal(Number(quota.stored_bytes), photo.image.byteLength);
        assert.equal((await repo.readExportForUserIfCurrent({ userId: OWNER, caseId: snapshot.caseId, artifactId: oldArtifact,
          contextFingerprint: output.contextFingerprint, checkedAt: iso() })).status, 'conflict');
        output = await publication(repo, snapshot);
      }
      const result = await repo.publishExportIfCurrent(output);
      assert.equal(result.status, newGeneration ? 'saved' : 'reused');
      if (result.status === 'saved') saved++;
      else if (result.status === 'reused') reused++;
      const rows = (await admin.query('SELECT count(*)::integer AS history,count(bytes)::integer AS live FROM safeathome_private.exports')).rows[0];
      assert.equal(rows.history, Math.floor(index / SOAK_PDF_GENERATION_ITERATIONS) + 1); assert.equal(rows.live, 1);
      const quota = (await admin.query('SELECT artifact_count,stored_bytes FROM safeathome_private.repository_quota')).rows[0];
      assert.equal(Number(quota.artifact_count), 1);
      assert.equal(Number(quota.stored_bytes), photo.image.byteLength + output.artifact.bytes.byteLength);
    }
    assert.equal(saved, 7); assert.equal(reused, 54); assert.equal(snapshot.revision, 7);
    const request = { userId: OWNER, caseId: snapshot.caseId, artifactId: output.artifact.metadata.artifactId,
      contextFingerprint: output.contextFingerprint, checkedAt: iso() };
    assert.equal((await repo.readExportForUserIfCurrent(request)).status, 'found');
    assert.equal((await repo.readExportForUserIfCurrent({ ...request, userId: OTHER })).status, 'not_found');
  } finally { await cluster.close(); }
});
