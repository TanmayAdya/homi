import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { createDemoEvidenceImage } from '../../fixtures/demo-evidence.ts';
import { demoProgram } from '../../fixtures/demo-program.ts';
import type { FormAnswerSaveInput, FormAnswerCaseRepository } from '../../src/api/form-answers.ts';
import type { MatchCaseRepository } from '../../src/api/match-case.ts';
import type { CreatePacketInput, PacketCaseRepository } from '../../src/api/prepare-packet.ts';
import type { CaseWriteRepository } from '../../src/cases/repository.ts';
import type { CaseDraft } from '../../src/cases/types.ts';
import type { EvidenceRepository, EvidenceSaveInput, ExportPublishInput } from '../../src/evidence/repository.ts';
import { createSavedFormAnswers } from '../../src/forms/form-answers.ts';
import { matchPrograms } from '../../src/matcher.ts';
import { planDraftPacket } from '../../src/packets.ts';
import type { CaseSnapshot } from '../../src/types.ts';

export type Repository = CaseWriteRepository & MatchCaseRepository & FormAnswerCaseRepository & EvidenceRepository & PacketCaseRepository;
export const OWNER = 'fictional-alice';
export const OTHER = 'fictional-bob';
export const FORM_CONTEXT = { programId: demoProgram.programId, formVersion: 'fictional-form-v1',
  mappingVersion: 'fictional-mapping-v1', formContextId: 'b'.repeat(64) };
export const EXPORT_CONTEXT = 'c'.repeat(64);
export const image = createDemoEvidenceImage();
export const iso = (offset = 0) => new Date(Date.now() + offset).toISOString();

export function draft(caseId: string = randomUUID()): CaseDraft {
  return { schemaVersion: '1', caseId,
    profile: { city: 'Demo City', county: null, healthPlan: 'Example Plan', tenure: null,
      ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null },
    unresolvedFields: [], findings: [{ id: 'fictional-finding', room: 'entrance',
      observation: 'Fictional threshold observation for database tests.', reviewState: 'confirmed',
      evidenceIds: ['fictional-photo-a', 'fictional-photo-b'], measurements: [] }] };
}

export async function create(repository: Repository, owner = OWNER): Promise<CaseSnapshot> {
  const result = await repository.createForUser(owner, draft());
  assert.equal(result.status, 'saved');
  if (result.status !== 'saved') throw new Error('Fictional case setup failed.');
  return result.snapshot;
}

export function answerInput(snapshot: CaseSnapshot, expectedAnswerRevision = 0): FormAnswerSaveInput {
  return { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision,
    programId: FORM_CONTEXT.programId, expectedAnswerRevision,
    answers: createSavedFormAnswers({ snapshot: { ...snapshot, revision: snapshot.revision + 1 }, context: FORM_CONTEXT,
      answerRevision: expectedAnswerRevision + 1, answers: [{ key: 'memberFirstName', value: 'Fictional', reviewState: 'reviewed' }],
      updatedAt: iso(-1000), updatedBy: OWNER }) };
}

export async function imageInput(snapshot: CaseSnapshot, expectedCatalogRevision = 0,
  evidenceId = 'fictional-photo-a', expectedEvidenceRevision = 0): Promise<EvidenceSaveInput> {
  return { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, expectedCatalogRevision,
    evidenceId, expectedEvidenceRevision, findingId: 'fictional-finding', image: await image,
    capturedAt: null, preparedAt: iso(-1000) };
}

export function packetInput(snapshot: CaseSnapshot, expiresIn = 600000): CreatePacketInput {
  const evaluatedAt = iso(-1000), recheckAfter = iso(expiresIn);
  const match = matchPrograms(snapshot, [{ ...demoProgram, recheckAfter }],
    { evaluatedAt, evaluationDate: evaluatedAt.slice(0, 10) }).matches[0];
  return { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, generationKey: randomUUID(),
    contextFingerprint: 'd'.repeat(64), checkedAt: evaluatedAt,
    packet: planDraftPacket(snapshot, match, { packetId: randomUUID(), generatedAt: evaluatedAt }) };
}

export async function publication(repository: Repository, snapshot: CaseSnapshot, catalogRevision = 1,
  expiresIn = 600000): Promise<ExportPublishInput> {
  const selections = [{ evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1, reviewedForExport: true as const }];
  const loaded = await repository.loadExportSnapshotForUser({ userId: OWNER, caseId: snapshot.caseId,
    revision: snapshot.revision, expectedCatalogRevision: catalogRevision, programId: FORM_CONTEXT.programId, selections });
  assert.equal(loaded.status, 'found');
  if (loaded.status !== 'found') throw new Error('Fictional export setup failed.');
  const generatedAt = iso(-500), expiresAt = iso(expiresIn);
  const bytes = Buffer.from('%PDF-1.7\nFictional database persistence bytes; PDF structure is checked by renderer tests.\n%%EOF');
  return { userId: OWNER, caseId: snapshot.caseId, revision: snapshot.revision, expectedCatalogRevision: catalogRevision,
    programId: FORM_CONTEXT.programId, selections, expectedCaseFingerprint: loaded.snapshot.caseFingerprint,
    expectedAnswersFingerprint: loaded.snapshot.answersFingerprint, contextFingerprint: EXPORT_CONTEXT,
    generationKey: randomUUID(), checkedAt: generatedAt,
    artifact: { bytes, metadata: { schemaVersion: '1', artifactId: randomUUID(), caseId: snapshot.caseId,
      caseRevision: snapshot.revision, ...FORM_CONTEXT, ruleVersion: 'fictional-rule-v1',
      answerRevision: loaded.snapshot.answers?.answerRevision ?? 0, evidenceCatalogRevision: catalogRevision,
      exportContextId: EXPORT_CONTEXT, generatedAt, expiresAt, recheckAfter: null, status: 'draft', isDemo: true,
      mediaType: 'application/pdf', byteLength: bytes.byteLength, sha256: createHash('sha256').update(bytes).digest('hex'),
      pageCount: 1, renderingVersion: 'draft-export-v1', selectedEvidence: loaded.snapshot.assets.map(asset => ({
        evidenceId: asset.descriptor.evidenceId, evidenceRevision: asset.descriptor.evidenceRevision,
        findingId: asset.descriptor.findingId, sha256: asset.descriptor.sha256, reviewedAt: generatedAt, reviewedBy: OWNER,
      })), missingItems: [], warnings: ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', 'POLICY_CURRENTNESS_UNKNOWN'] } } };
}
