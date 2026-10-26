import { mkdir, writeFile } from 'node:fs/promises';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleSaveProgramIntake } from '../src/api/program-intake.ts';
import { handleReadFormAnswersV2 } from '../src/api/form-answers-v2.ts';
import { intakeDefinition } from '../src/programs/intake.ts';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import type { CaseSnapshot } from '../src/types.ts';
const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
const fixtures = [];
for (const programId of ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair']) {
  const snapshot: CaseSnapshot = { schemaVersion: '1', caseId: `fictional-${programId}`, revision: 1,
    profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
  const cases = new MemoryCaseRepository([{ userId: 'fictional-owner', snapshot }]);
  const deps = { cases, authenticate: async () => ({ userId: 'fictional-owner' }), now: () => new Date('2026-10-22T20:00:00.000Z'), loadFormTemplate: bundle.loadFormTemplate };
  const definition = intakeDefinition(programId)!;
  const intakeRequest = { schemaVersion: '2', caseId: snapshot.caseId, expectedCaseRevision: 1, programId,
    expectedIntakeRevision: 0, expectedQuestionnaireVersion: definition.questionnaireVersion,
    answers: definition.questions.map((q, i) => ({ key: q.key, value: i === 0 ? false : q.kind === 'money' ? 0 : null, reviewState: i === 0 || q.kind === 'money' ? 'reported' : 'unknown' })) };
  const intake = await handleSaveProgramIntake({ body: intakeRequest, bearerToken: 'fictional-token' }, deps);
  if (intake.status !== 200) throw new Error('Fixture intake failed.');
  const form = await handleReadFormAnswersV2({ body: { schemaVersion: '2', caseId: snapshot.caseId, expectedCaseRevision: 2, programId }, bearerToken: 'fictional-token' }, deps);
  if (form.status !== 200) throw new Error('Fixture form failed.');
  fixtures.push({ programId, case: snapshot, intakeRequest, intake: intake.body, form: form.body });
}
const dir = new URL('../../contracts/v2/fixtures/', import.meta.url);
await mkdir(dir, { recursive: true });
await writeFile(new URL('team-programs.json', dir), JSON.stringify(fixtures, null, 2) + '\n');
