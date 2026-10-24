import assert from 'node:assert/strict';
import test from 'node:test';
import { exportEvidenceFitsBudget, MAX_EXPORT_EVIDENCE_BYTES, MAX_EXPORT_EVIDENCE_PIXELS } from '../src/evidence/export-budget.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { OWNER, create, imageInput } from './postgres/fixtures.ts';
import type { EvidenceAsset } from '../src/evidence/types.ts';

test('export evidence budgets are inclusive and distinguish compressed bytes from decoded pixels', () => {
  const first = { width: 4000, height: 2000, byteLength: MAX_EXPORT_EVIDENCE_BYTES / 2 };
  assert.equal(exportEvidenceFitsBudget([first, first]), true);
  assert.equal(first.width * first.height * 2, MAX_EXPORT_EVIDENCE_PIXELS);
  assert.equal(exportEvidenceFitsBudget([first, { ...first, byteLength: first.byteLength + 1 }]), false);
  assert.equal(exportEvidenceFitsBudget([{ width: 4000, height: 4000, byteLength: 100 },
    { width: 1, height: 1, byteLength: 100 }]), false);
  assert.equal(exportEvidenceFitsBudget([{ width: 4000, height: 4000, byteLength: 100 }]), true);
  assert.equal(exportEvidenceFitsBudget([]), true);
  for (const value of [NaN, Infinity, 0, -1, 1.5, Number.MAX_SAFE_INTEGER]) {
    assert.equal(exportEvidenceFitsBudget([{ ...first, width: value }]), false);
  }
});

test('memory export preflight rejects over-budget stored metadata before copying any private bytes', async () => {
  for (const kind of ['pixels', 'bytes'] as const) {
    const repository = new MemoryCaseRepository([]), snapshot = await create(repository);
    for (const [index, evidenceId] of snapshot.findings[0].evidenceIds.entries()) {
      assert.equal((await repository.saveEvidenceIfCurrent(await imageInput(snapshot, index, evidenceId))).status, 'saved');
    }
    const evidence = (repository as unknown as { evidence: Map<string, Map<string, { asset: EvidenceAsset }>> }).evidence;
    for (const stored of evidence.get(snapshot.caseId)!.values()) {
      if (kind === 'pixels') Object.assign(stored.asset.descriptor, { width: 4000, height: 3000 });
      else stored.asset.descriptor.byteLength = MAX_EXPORT_EVIDENCE_BYTES / 2 + 1;
      Object.defineProperty(stored.asset, 'bytes', { get() { throw new Error('Private bytes were copied before the budget check.'); } });
    }
    assert.deepEqual(await repository.loadExportSnapshotForUser({ userId: OWNER, caseId: snapshot.caseId,
      revision: snapshot.revision, expectedCatalogRevision: 2, programId: 'program-a',
      selections: snapshot.findings[0].evidenceIds.map(evidenceId => ({ evidenceId,
        expectedEvidenceRevision: 1, reviewedForExport: true })) }), { status: 'selection_too_large' });
  }
});
