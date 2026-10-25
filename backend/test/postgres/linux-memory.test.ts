import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { AddressInfo } from 'node:net';
import { test } from 'node:test';
import { createDemoEvidenceImage } from '../../fixtures/demo-evidence.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { FIXTURE_NAMES } from '../../tool/memory/fixture.ts';
import { API_ORIGIN, OWNER } from '../../tool/linux-memory/protocol.ts';
import { seedScenario } from '../../tool/linux-memory/seed.ts';
import { createSyntheticMemoryServer } from '../../tool/linux-memory/server.ts';
import { runLinuxWorkload } from '../../tool/linux-memory/workload.ts';
import { TestPostgres } from './harness.ts';

test('container harness seeds through restricted PG and drives authenticated HTTP PDF storage/download', async () => {
  const cluster = await TestPostgres.start();
  const directory = await mkdtemp('/tmp/sah-memory-linux-test-');
  const admin = cluster.pool();
  try {
    await applyMigrations(admin);
    await admin.query('CREATE ROLE sah_linux_memory_test LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
    const pool = cluster.pool('sah_linux_memory_test');
    await assert.rejects(createSyntheticMemoryServer(admin));
    const image = await createDemoEvidenceImage();
    const metadata = { width: image.width, height: image.height, bytes: image.byteLength, sha256: image.sha256 };
    await writeFile(join(directory, 'solid.png'), image.bytes, { mode: 0o600 });
    await writeFile(join(directory, 'manifest.json'), JSON.stringify({ schemaVersion: '1',
      files: Object.fromEntries(FIXTURE_NAMES.map(name => [name, metadata])) }), { mode: 0o600 });
    const seeded = await seedScenario(pool, 'pdf-solid-16mp', directory);
    assert.equal(seeded.evidence, 1);
    await assert.rejects(seedScenario(pool, 'pdf-solid-16mp', directory));
    assert.equal((await admin.query('SELECT owner_id FROM safeathome_private.cases')).rows[0].owner_id, OWNER);
    const { server } = await createSyntheticMemoryServer(pool);
    try {
      await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
      const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
      const transport: typeof fetch = (input, init) => {
        assert.equal(typeof input, 'string'); assert.ok(String(input).startsWith(`${API_ORIGIN}/v1/`));
        return fetch(String(input).replace(API_ORIGIN, origin), init);
      };
      const report = await runLinuxWorkload('pdf-solid-16mp', directory, transport);
      assert.equal(report.status, 'passed', JSON.stringify(report.assertions));
      assert.equal(report.iterations, 1); assert.equal(report.iterationElapsedMs.length, 1);
      assert.equal(report.assertions.crossOwnerArtifactDenied, true);
      assert.equal(report.assertions.downloadDigestMatches, true);
      const stored = await admin.query('SELECT count(bytes)::integer AS count, min(octet_length(bytes))::integer AS bytes FROM safeathome_private.exports');
      assert.equal(stored.rows[0].count, 1); assert.ok(stored.rows[0].bytes > 0);
    } finally {
      await new Promise<void>((resolve, reject) => { server.close(error => error ? reject(error) : resolve()); server.closeAllConnections(); });
    }
  } finally { await cluster.close(); await rm(directory, { recursive: true, force: true }); }
});
