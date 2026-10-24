import assert from 'node:assert/strict';
import test from 'node:test';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleReadProgramIntake, handleSaveProgramIntake } from '../src/api/program-intake.ts';
import { intakeDefinition, parseIntakeAnswers, parseSavedProgramIntake } from '../src/programs/intake.ts';
import type { CaseSnapshot } from '../src/types.ts';
const snapshot: CaseSnapshot = { schemaVersion: '1', caseId: 'intake-fictional', revision: 1,
  profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
const now = '2026-10-22T20:00:00.000Z';
function setup(programId = 'hpsm-eaa') {
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot }]);
  const deps = { cases, authenticate: async (token: string) => token === 'alice' ? { userId: 'alice' } : token === 'bob' ? { userId: 'bob' } : null, now: () => new Date(now) };
  const definition = intakeDefinition(programId)!;
  const body = { schemaVersion: '2', caseId: snapshot.caseId, expectedCaseRevision: 1, programId };
  const save = { ...body, expectedIntakeRevision: 0, expectedQuestionnaireVersion: definition.questionnaireVersion,
    answers: [{ key: 'activeMembershipReported', value: false, reviewState: 'reported' },
      { key: 'estimatedCostUsd', value: 0, reviewState: 'reported' }, { key: 'priorEaaPaidUsd', value: null, reviewState: 'unknown' }] };
  return { cases, deps, definition, body, save };
}
test('intake preserves false, zero and unknown independently and increments both revisions atomically', async () => {
  const { deps, body, save } = setup();
  const initial = await handleReadProgramIntake({ body, bearerToken: 'alice' }, deps);
  assert.equal(initial.status, 200); assert.ok('saved' in initial.body); assert.equal(initial.body.saved, null);
  const result = await handleSaveProgramIntake({ body: save, bearerToken: 'alice' }, deps);
  assert.equal(result.status, 200); assert.ok('saved' in result.body);
  assert.equal(result.body.caseRevision, 2); assert.equal(result.body.saved!.intakeRevision, 1);
  assert.deepEqual(result.body.saved!.answers.map(a => a.value), [false, 0, null]);
  assert.equal(result.body.saved!.updatedBy, 'alice');
  assert.equal((await handleSaveProgramIntake({ body: save, bearerToken: 'alice' }, deps)).status, 409);
});
test('intake enforces owner isolation and explicit version/revision conflicts', async () => {
  const { deps, body, save } = setup();
  assert.equal((await handleReadProgramIntake({ body, bearerToken: null }, deps)).status, 401);
  assert.equal((await handleReadProgramIntake({ body, bearerToken: 'bob' }, deps)).status, 404);
  for (const [patch, code] of [[{ expectedQuestionnaireVersion: 'a'.repeat(64) }, 'QUESTIONNAIRE_CHANGED'],
    [{ expectedIntakeRevision: 2 }, 'INTAKE_CONFLICT'], [{ expectedCaseRevision: 2 }, 'CASE_REVISION_MISMATCH']] as const) {
    const result = await handleSaveProgramIntake({ body: { ...save, ...patch }, bearerToken: 'alice' }, deps);
    assert.equal(result.status, 409); assert.ok('error' in result.body); assert.equal(result.body.error.code, code);
  }
});
test('unknown fields, invalid amounts, document/clinical injection and falsely confirmed unknown values are rejected', async () => {
  const { deps, save, definition } = setup();
  for (const answers of [
    [{ key: 'diagnosis', value: 'invented', reviewState: 'reported' }],
    [{ key: 'estimatedCostUsd', value: -1, reviewState: 'reported' }],
    [{ key: 'estimatedCostUsd', value: 1.001, reviewState: 'reported' }],
    [{ key: 'estimatedCostUsd', value: null, reviewState: 'reported' }],
    [{ key: 'activeMembershipReported', value: 'yes', reviewState: 'reported' }],
    [save.answers[0], save.answers[0]],
  ]) {
    assert.throws(() => parseIntakeAnswers(answers, definition));
    assert.equal((await handleSaveProgramIntake({ body: { ...save, answers }, bearerToken: 'alice' }, deps)).status, 400);
  }
  assert.equal((await handleSaveProgramIntake({ body: { ...save, updatedBy: 'bob' }, bearerToken: 'alice' }, deps)).status, 400);
});
test('cost above 7500 remains an answer for exception review and is never rejected as ineligible', async () => {
  const { deps, save } = setup();
  const result = await handleSaveProgramIntake({ body: { ...save, answers: [{ key: 'estimatedCostUsd', value: 9000, reviewState: 'reported' }] }, bearerToken: 'alice' }, deps);
  assert.equal(result.status, 200); assert.ok('saved' in result.body); assert.equal(result.body.saved!.answers[0].value, 9000);
});
test('each program has a distinct immutable questionnaire and restored records reject tampering', async () => {
  const { deps, save } = setup();
  const result = await handleSaveProgramIntake({ body: save, bearerToken: 'alice' }, deps);
  assert.ok('saved' in result.body);
  const saved = result.body.saved;
  assert.throws(() => parseSavedProgramIntake({ ...saved, programId: 'rtp-home-repair' }));
  const ids = ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair'];
  assert.equal(new Set(ids.map(id => intakeDefinition(id)!.questionnaireVersion)).size, 3);
  const changed = intakeDefinition('hpsm-eaa')!; changed.questions.length = 0;
  assert.ok(intakeDefinition('hpsm-eaa')!.questions.length > 0);
  assert.equal(intakeDefinition('__proto__'), null);
});
test('repository substitution after a successful write cannot masquerade as the requested answer', async () => {
  const { deps, save } = setup();
  const original = deps.cases.saveProgramIntakeIfCurrent.bind(deps.cases);
  deps.cases.saveProgramIntakeIfCurrent = async input => {
    input.intake.answers[0].value = true;
    return original(input);
  };
  const result = await handleSaveProgramIntake({ body: save, bearerToken: 'alice' }, deps);
  assert.equal(result.status, 500);
});
