import { pathToFileURL } from 'node:url';
import type { Pool } from 'pg';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { bootstrapRuntimeRole } from '../../src/storage/bootstrap-runtime.ts';
import { assertRestrictedRuntimeRole } from '../../src/storage/postgres-pool.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { readFixture } from '../memory/fixture.ts';
import type { Scenario } from '../memory/workload.ts';
import { AGGREGATE_CASE_ID, CASE_ID, OWNER, RUNTIME_PASSWORD, parseScenario, scenarioFixture, syntheticDiagnostic, syntheticDraft, syntheticPool } from './protocol.ts';

export async function seedScenario(pool: Pool, scenario: Scenario, directory: string) {
  await assertRestrictedRuntimeRole(pool);
  const cases = new PostgresCaseRepository(pool);
  if (scenario.startsWith('upload-')) return { schemaVersion: '1', kind: 'seeded', scenario, cases: 0, evidence: 0 };
  const { name, count } = scenarioFixture(scenario);
  const { bytes, metadata } = await readFixture(directory, name);
  const caseId = scenario === 'reject-oversize' ? AGGREGATE_CASE_ID : CASE_ID;
  const created = await cases.createForUser(OWNER, syntheticDraft(count, caseId));
  if (created.status !== 'saved' || created.snapshot.revision !== 1) throw new Error('Synthetic database is not fresh.');
  for (let index = 0; index < count; index++) {
    const saved = await cases.saveEvidenceIfCurrent({ userId: OWNER, caseId, revision: 1,
      expectedCatalogRevision: index, evidenceId: `synthetic-photo-${index + 1}`, expectedEvidenceRevision: 0,
      findingId: 'synthetic-finding', image: { bytes, width: metadata.width, height: metadata.height,
        byteLength: bytes.length, sha256: metadata.sha256, mediaType: 'image/png', processingVersion: 'evidence-png-v1' },
      capturedAt: null, preparedAt: new Date().toISOString() });
    if (saved.status !== 'saved') throw new Error('Synthetic evidence setup failed.');
  }
  return { schemaVersion: '1', kind: 'seeded', scenario, cases: 1, evidence: count };
}

let phase = 'arguments';
async function main() {
  if (process.argv.length !== 4) throw new Error('Synthetic setup arguments are invalid.');
  const scenario = parseScenario(process.argv[2]);
  phase = 'admin-tls';
  const admin = await syntheticPool(true);
  try {
    phase = 'admin-connect';
    await admin.query('SELECT 1');
    phase = 'migrations';
    await applyMigrations(admin);
    phase = 'bootstrap-runtime';
    const result = await bootstrapRuntimeRole(admin, { password: RUNTIME_PASSWORD });
    if (result.status !== 'created') throw new Error('Synthetic database must be fresh.');
  } finally { await admin.end(); }
  phase = 'runtime-tls';
  const runtime = await syntheticPool();
  try { phase = 'seed'; console.log(JSON.stringify(await seedScenario(runtime, scenario, process.argv[3]))); }
  finally { await runtime.end(); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(error => { syntheticDiagnostic(phase, error); process.exitCode = 1; });
}
