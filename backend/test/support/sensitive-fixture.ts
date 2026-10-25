import { randomUUID, randomBytes, createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import type { Pool } from 'pg';
import { draft, imageInput, OWNER } from '../postgres/fixtures.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { PostgresSharingRepository } from '../../src/sharing/postgres-sharing-repository.ts';
import { handleSaveProgramIntake } from '../../src/api/program-intake.ts';
import { intakeDefinition } from '../../src/programs/intake.ts';
import { demoProgram } from '../../fixtures/demo-program.ts';
export const HELPER = '33333333-3333-4333-8333-333333333333', VIEWER = '22222222-2222-4222-8222-222222222222', OTHER = '44444444-4444-4444-8444-444444444444';
export { OWNER };
export async function seedSensitive(pool: Pool, recipient = HELPER, role: 'helper' | 'viewer' = 'helper') {
  const cases = new PostgresCaseRepository(pool), shares = new PostgresSharingRepository(pool);
  const input = draft(); input.findings[0].measurements = [{ type: 'clear_width', value: 750, unit: 'mm', method: 'manual', confirmed: true }];
  const created = await cases.createForUser(OWNER, input); assert.equal(created.status, 'saved'); if (created.status !== 'saved') throw Error();
  const photo = await imageInput(created.snapshot); assert.equal((await cases.saveEvidenceIfCurrent(photo)).status, 'saved');
  await cases.saveProgressForUser(OWNER, { schemaVersion: '3', caseId: input.caseId, expectedCaseRevision: 1, expectedProgressRevision: 0,
    mutationId: randomUUID(), operation: { type: 'track_program', programId: 'scfhp-eaa' } }, new Date().toISOString(), [{ ...demoProgram, programId: 'scfhp-eaa' }]);
  const definition = intakeDefinition('scfhp-eaa')!;
  const saved = await handleSaveProgramIntake({ bearerToken: OWNER, body: { schemaVersion: '2', caseId: input.caseId, expectedCaseRevision: 1,
    programId: 'scfhp-eaa', expectedIntakeRevision: 0, expectedQuestionnaireVersion: definition.questionnaireVersion,
    answers: [{ key: 'estimatedCostUsd', value: 0, reviewState: 'reported' }, { key: 'professionalOrderReported', value: false, reviewState: 'reported' },
      { key: 'professionalEvaluationReported', value: null, reviewState: 'unknown' }, { key: 'willingServicesReported', value: true, reviewState: 'reported' }] } },
  { cases, now: () => new Date(), authenticate: async () => ({ userId: OWNER }) });
  assert.equal(saved.status, 200);
  const code = randomBytes(32).toString('base64url'), tokenHash = createHash('sha256').update(code).digest('hex'), membershipId = randomUUID();
  assert.equal((await shares.execute(OWNER, 'create-invitation', { schemaVersion: '3', caseId: input.caseId, expectedCaseRevision: 2,
    invitationId: membershipId, recipientId: recipient, role, scope: { findingIds: ['fictional-finding'], programIds: ['scfhp-eaa'], allowHelperNotes: false }, expiresAt: null }, tokenHash)).status, 'ok');
  assert.equal((await shares.execute(recipient, 'accept-invitation', { schemaVersion: '3', code, expectedPermissionRevision: 1 }, tokenHash)).status, 'ok');
  return { cases, shares, caseId: input.caseId, membershipId, recipient, photo, code };
}
