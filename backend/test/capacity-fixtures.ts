import assert from 'node:assert/strict';
import { CAPACITY_LIMITS } from '../src/storage/capacity-limits.ts';
import type { CaseSnapshot } from '../src/types.ts';
import { OWNER, OTHER, create, draft, imageInput, packetInput, publication,
  type Repository } from './postgres/fixtures.ts';

export async function caseCapacity(first: Repository, second: Repository) {
  const existing = await create(first);
  for (let i = 1; i < CAPACITY_LIMITS.casesPerOwner - 1; i++) await create(first);
  const candidates = [draft(), draft()];
  const results = await Promise.all([first.createForUser(OWNER, candidates[0]), second.createForUser(OWNER, candidates[1])]);
  assert.deepEqual(results.map(result => result.status).sort(), ['quota_exceeded', 'saved']);
  const failed = results.findIndex(result => result.status === 'quota_exceeded');
  assert.equal(await first.loadForUser(OWNER, candidates[failed].caseId), null);
  assert.equal((await first.createForUser(OWNER, draft(existing.caseId))).status, 'id_unavailable');
  assert.equal((await first.createForUser(OTHER, draft(existing.caseId))).status, 'id_unavailable');
  await create(second, OTHER);
  assert.equal((await first.replaceIfCurrent(OWNER, existing.caseId, existing.revision, draft(existing.caseId))).status, 'saved');
  return existing;
}

export async function packetCapacity(first: Repository, second: Repository) {
  let snapshot = await create(first);
  const old = packetInput(snapshot);
  assert.equal((await first.createPacketIfCurrent(old)).status, 'saved');
  assert.equal((await first.replaceIfCurrent(OWNER, snapshot.caseId, snapshot.revision, draft(snapshot.caseId))).status, 'saved');
  snapshot = (await first.loadForUser(OWNER, snapshot.caseId))!;
  for (let i = 1; i < CAPACITY_LIMITS.packetsPerCase - 1; i++) {
    assert.equal((await first.createPacketIfCurrent(packetInput(snapshot))).status, 'saved');
  }
  const inputs = [packetInput(snapshot), packetInput(snapshot)];
  const results = await Promise.all([first.createPacketIfCurrent(inputs[0]), second.createPacketIfCurrent(inputs[1])]);
  assert.deepEqual(results.map(result => result.status).sort(), ['quota_exceeded', 'saved']);
  const winner = inputs[results.findIndex(result => result.status === 'saved')];
  assert.equal((await second.createPacketIfCurrent(winner)).status, 'reused');
  assert.equal((await first.createPacketIfCurrent({ ...winner, contextFingerprint: 'e'.repeat(64) })).status, 'generation_conflict');
  assert.equal((await first.createPacketIfCurrent({ ...packetInput(snapshot), generationKey: old.generationKey })).status, 'generation_conflict');
  assert.equal((await second.createPacketIfCurrent({ ...winner, userId: OTHER })).status, 'not_found');
  assert.equal((await first.createPacketIfCurrent(packetInput(snapshot))).status, 'quota_exceeded');
  return snapshot;
}

async function evidenceCase(repository: Repository, owner = OWNER): Promise<CaseSnapshot> {
  const input = draft();
  input.findings[0].evidenceIds = Array.from({ length: 10 }, (_, i) => `capacity-photo-${i}`);
  const saved = await repository.createForUser(owner, input);
  assert.equal(saved.status, 'saved');
  if (saved.status !== 'saved') throw new Error('Capacity fixture failed.');
  return saved.snapshot;
}

export async function evidenceCapacity(first: Repository, second: Repository) {
  const a = await evidenceCase(first), b = await evidenceCase(first), bob = await evidenceCase(second, OTHER);
  for (let i = 0; i < 8; i++) assert.equal((await first.saveEvidenceIfCurrent(await imageInput(a, i, `capacity-photo-${i}`))).status, 'saved');
  for (let i = 0; i < 7; i++) assert.equal((await first.saveEvidenceIfCurrent(await imageInput(b, i, `capacity-photo-${i}`))).status, 'saved');
  const inputs = [await imageInput(a, 8, 'capacity-photo-8'), await imageInput(b, 7, 'capacity-photo-7')];
  const results = await Promise.all([first.saveEvidenceIfCurrent(inputs[0]), second.saveEvidenceIfCurrent(inputs[1])]);
  assert.deepEqual(results.map(result => result.status).sort(), ['quota_exceeded', 'saved']);
  const failed = results.findIndex(result => result.status === 'quota_exceeded');
  const catalog = await first.readEvidenceCatalogForUser(OWNER, inputs[failed].caseId);
  assert.equal(catalog.status, 'found');
  if (catalog.status === 'found') assert.equal(catalog.catalog.catalogRevision, inputs[failed].expectedCatalogRevision);
  const current = await first.readEvidenceCatalogForUser(OWNER, a.caseId);
  assert.equal(current.status, 'found');
  if (current.status !== 'found') throw new Error('Capacity fixture missing.');
  const deleted = await first.deleteEvidenceIfCurrent({ userId: OWNER, caseId: a.caseId, revision: a.revision,
    expectedCatalogRevision: current.catalog.catalogRevision, evidenceId: 'capacity-photo-0', expectedEvidenceRevision: 1 });
  assert.equal(deleted.status, 'deleted');
  if (deleted.status !== 'deleted') throw new Error('Capacity fixture deletion failed.');
  assert.equal((await first.saveEvidenceIfCurrent(await imageInput(a, deleted.catalogRevision, 'capacity-photo-9'))).status, 'quota_exceeded');
  assert.equal((await first.saveEvidenceIfCurrent(await imageInput(a, deleted.catalogRevision, 'capacity-photo-0', 2))).status, 'saved');
  assert.equal((await second.saveEvidenceIfCurrent({ ...await imageInput(bob, 0, 'capacity-photo-0'), userId: OTHER })).status, 'saved');
  return { a, b, bob };
}

export async function exportCapacity(first: Repository, second: Repository) {
  let snapshot = await create(first);
  assert.equal((await first.saveEvidenceIfCurrent(await imageInput(snapshot))).status, 'saved');
  let oldKey = '';
  for (let i = 0; i < CAPACITY_LIMITS.exportsPerCase - 1; i++) {
    const input = await publication(first, snapshot);
    if (i === 0) oldKey = input.generationKey;
    assert.equal((await first.publishExportIfCurrent(input)).status, 'saved');
    assert.equal((await first.replaceIfCurrent(OWNER, snapshot.caseId, snapshot.revision, draft(snapshot.caseId))).status, 'saved');
    snapshot = (await first.loadForUser(OWNER, snapshot.caseId))!;
  }
  const inputs = [await publication(first, snapshot), await publication(first, snapshot)];
  const results = await Promise.all([first.publishExportIfCurrent(inputs[0]), second.publishExportIfCurrent(inputs[1])]);
  assert.deepEqual(results.map(result => result.status).sort(), ['quota_exceeded', 'saved']);
  const winner = inputs[results.findIndex(result => result.status === 'saved')];
  assert.equal((await second.publishExportIfCurrent(winner)).status, 'reused');
  const newInput = await publication(first, snapshot);
  assert.equal((await first.publishExportIfCurrent({ ...newInput, generationKey: oldKey })).status, 'generation_conflict');
  assert.equal((await first.publishExportIfCurrent(newInput)).status, 'quota_exceeded');
  assert.equal((await second.publishExportIfCurrent({ ...winner, userId: OTHER })).status, 'not_found');
  return snapshot;
}
