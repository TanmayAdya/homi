import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdir, writeFile } from 'node:fs/promises';
import { PDFDocument, PDFDict, PDFName } from 'pdf-lib';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import { createFormAnswerContext, createSavedFormAnswers, formAnswerFieldsForProgram, type FormAnswerInput } from '../src/forms/form-answers.ts';
import { defineVerifiedFormTemplate } from '../src/forms/field-mapping.ts';
import { renderDraftPreview } from '../src/forms/render-draft-preview.ts';
import { matchPrograms } from '../src/matcher.ts';
import { handleReadFormAnswersV2, handleSaveFormAnswersV2 } from '../src/api/form-answers-v2.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import type { CaseSnapshot } from '../src/types.ts';
const snapshot: CaseSnapshot = { schemaVersion: '1', caseId: 'fictional-team-beta-case', revision: 1,
  profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
const now = '2026-10-22T19:00:00.000Z';

test('team bundle exposes three independent draft routes without manufacturing eligibility or availability', async () => {
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const programs = await bundle.loadRegistry();
  assert.deepEqual(programs.map(p => p.programId), ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair']);
  const result = matchPrograms(snapshot, programs, { evaluatedAt: now, evaluationDate: now.slice(0, 10) });
  for (const match of result.matches) { assert.equal(match.status, 'needs_confirmation'); assert.ok(match.checks.every(c => c.status === 'unknown')); }
  for (const program of programs) { assert.equal(program.rulesVerified, false); assert.equal(program.availability, 'unverified'); }
  const hpsm = programs.find(p => p.programId === 'hpsm-eaa')!;
  const exception = hpsm.criteria.find(c => c.id === 'cost-exception')!;
  assert.equal(exception.rule.kind, 'manual_review');
  assert.match(JSON.stringify(exception), /not an automatic rejection/);
});

test('HPSM and RTP field mappings reject SCFHP names and preserve semantic allowlists', async () => {
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const hpsm = (await bundle.loadFormTemplate('hpsm-eaa'))!;
  assert.equal(hpsm.template.pageCount, 6);
  assert.equal(hpsm.template.fields.length, 11);
  assert.ok(hpsm.template.fields.some(f => f.fieldName === 'MembersFirstName'));
  const changed = structuredClone(hpsm.template);
  Object.assign(changed.fields[0], { fieldName: 'First Name' });
  assert.throws(() => defineVerifiedFormTemplate(changed));
  const rtp = (await bundle.loadFormTemplate('rtp-home-repair'))!;
  assert.match(rtp.template.publisherRevision!, /not an RTP form/);
  assert.equal(rtp.template.fields.length, 4);
  assert.notEqual(createFormAnswerContext(hpsm.template).formContextId, createFormAnswerContext(rtp.template).formContextId);
});

for (const programId of ['hpsm-eaa', 'rtp-home-repair']) {
  test(`${programId}: reviewed administrative fields render without active objects or missing pages`, async () => {
    const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
    const form = (await bundle.loadFormTemplate(programId))!;
    const fields = formAnswerFieldsForProgram(programId);
    const answers: FormAnswerInput[] = fields.map(field => ({ key: field.key, reviewState: 'reviewed',
      value: field.kind === 'date' ? (field.key === 'memberBirthDate' ? '1960-03-05' : '2026-10-22')
        : field.kind === 'email' ? 'fictional@example.invalid' : field.key.includes('Phone') ? '555-0100'
          : field.key === 'memberPreferredSpokenLanguage' ? 'English' : field.key === 'memberId' ? 'FICTIONAL-001' : 'Fictional Example' }));
    const saved = createSavedFormAnswers({ snapshot, context: createFormAnswerContext(form.template), answerRevision: 1,
      answers, updatedAt: now, updatedBy: 'fictional-user' });
    const preview = await renderDraftPreview(snapshot, form.template, form.bytes,
      { programId, templateSha256: form.template.templateSha256, plannedAt: now }, saved);
    assert.deepEqual(preview.renderIssues, []);
    assert.equal(preview.plan.summary.mapped, fields.length + (programId === 'hpsm-eaa' ? 1 : 0));
    const output = await PDFDocument.load(preview.bytes, { updateMetadata: false });
    assert.equal(output.getPageCount(), form.template.pageCount);
    assert.equal(output.getForm().getFields().length, 0);
    for (const [, object] of output.context.enumerateIndirectObjects()) if (object instanceof PDFDict) {
      for (const key of ['A', 'AA', 'OpenAction', 'JS', 'JavaScript']) assert.equal(object.has(PDFName.of(key)), false);
    }
    await mkdir(new URL('../local-artifacts/team-form-review/', import.meta.url), { recursive: true });
    await writeFile(new URL(`../local-artifacts/team-form-review/${programId}.pdf`, import.meta.url), preview.bytes);
  });
}

test('v2 form answers use per-program definitions and retain atomic revision and ownership checks', async () => {
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot }]);
  const deps = { authenticate: async (token: string) => token === 'alice-token' ? { userId: 'alice' } : { userId: 'bob' },
    cases, loadFormTemplate: bundle.loadFormTemplate, now: () => new Date(now) };
  const body = { schemaVersion: '2', caseId: snapshot.caseId, expectedCaseRevision: 1, programId: 'hpsm-eaa' };
  const read = await handleReadFormAnswersV2({ body, bearerToken: 'alice-token' }, deps);
  assert.equal(read.status, 200); assert.ok('fieldDefinitions' in read.body);
  assert.equal(read.body.fieldDefinitions.length, 10); assert.equal(read.body.artifactKind, 'official_form_draft');
  const saveBody = { ...body, expectedFormContextId: read.body.context.formContextId, expectedAnswerRevision: 0,
    answers: [{ key: 'memberFirstName', value: 'Fictional', reviewState: 'reviewed' }] };
  const saved = await handleSaveFormAnswersV2({ body: saveBody, bearerToken: 'alice-token' }, deps);
  assert.equal(saved.status, 200); assert.ok('caseRevision' in saved.body); assert.equal(saved.body.caseRevision, 2);
  assert.equal((await handleSaveFormAnswersV2({ body: saveBody, bearerToken: 'alice-token' }, deps)).status, 409);
  assert.equal((await handleReadFormAnswersV2({ body: { ...body, expectedCaseRevision: 2 }, bearerToken: 'bob-token' }, deps)).status, 404);
  assert.equal((await handleReadFormAnswersV2({ body: { ...body, schemaVersion: '1' }, bearerToken: 'alice-token' }, deps)).status, 400);
});

test('v2 draft includes reported intake facts and cost exception while v1 cannot silently omit them', async () => {
  const { handleSaveProgramIntake } = await import('../src/api/program-intake.ts');
  const { intakeDefinition } = await import('../src/programs/intake.ts');
  const { handleDraftExport } = await import('../src/api/draft-export.ts');
  const { PDFArray, PDFRawStream, decodePDFRawStream } = await import('pdf-lib');
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const cases = new MemoryCaseRepository([{ userId: 'alice', snapshot }]);
  const deps = { authenticate: async () => ({ userId: 'alice' }), cases,
    loadFormTemplate: bundle.loadFormTemplate, loadRegistry: bundle.loadRegistry, now: () => new Date(now) };
  const definition = intakeDefinition('hpsm-eaa')!;
  const saved = await handleSaveProgramIntake({ bearerToken: 'alice-token', body: { schemaVersion: '2', caseId: snapshot.caseId,
    expectedCaseRevision: 1, programId: 'hpsm-eaa', expectedIntakeRevision: 0, expectedQuestionnaireVersion: definition.questionnaireVersion,
    answers: [{ key: 'estimatedCostUsd', value: 9000, reviewState: 'reported' }] } }, deps);
  assert.equal(saved.status, 200);
  const template = (await bundle.loadFormTemplate('hpsm-eaa'))!.template;
  const form = await handleSaveFormAnswersV2({ bearerToken: 'alice-token', body: { schemaVersion: '2', caseId: snapshot.caseId,
    expectedCaseRevision: 2, programId: 'hpsm-eaa', expectedFormContextId: createFormAnswerContext(template).formContextId,
    expectedAnswerRevision: 0, answers: [] } }, deps);
  assert.equal(form.status, 200);
  const body = { schemaVersion: '2', caseId: snapshot.caseId, expectedCaseRevision: 3, programId: 'hpsm-eaa',
    expectedFormContextId: createFormAnswerContext(template).formContextId, expectedAnswerRevision: 1,
    expectedEvidenceCatalogRevision: 0, generationKey: 'intake-export-001', selectedEvidence: [] };
  const blocked = await handleDraftExport({ bearerToken: 'alice-token', body: { ...body, schemaVersion: '1' } }, deps, 'create-draft-export');
  assert.equal(blocked.status, 409); assert.ok('error' in blocked.body); assert.equal(blocked.body.error.code, 'INTAKE_REQUIRES_V2');
  const exported = await handleDraftExport({ bearerToken: 'alice-token', body }, deps, 'create-draft-export', 2);
  assert.equal(exported.status, 200, JSON.stringify(exported.body)); assert.ok('artifactId' in exported.body);
  assert.ok(exported.body.pageCount >= 7);
  const download = { schemaVersion: '2', caseId: snapshot.caseId, expectedCaseRevision: 3, artifactId: exported.body.artifactId };
  const file = await handleDraftExport({ bearerToken: 'alice-token', body: download }, deps, 'download-draft-export', 2);
  assert.equal(file.status, 200); assert.ok(file.body instanceof Uint8Array);
  const pdf = await PDFDocument.load(file.body);
  const operators = pdf.getPages().slice(6).flatMap(page => {
    const contents = page.node.Contents();
    return (contents instanceof PDFArray ? contents.asArray() : [contents]).map(ref => {
      const stream = pdf.context.lookup(ref); assert.ok(stream instanceof PDFRawStream);
      return Buffer.from(decodePDFRawStream(stream).decode()).toString('latin1');
    });
  }).join('\n');
  for (const text of ['Reported USD 9000.00', 'EXCEPTION REVIEW:', 'The case changed after these answers were saved.']) {
    assert.ok(operators.includes(Buffer.from(text).toString('hex').toUpperCase()), text);
  }
  await writeFile(new URL('../local-artifacts/team-form-review/hpsm-intake-export.pdf', import.meta.url), file.body);
  const changed = await handleSaveProgramIntake({ bearerToken: 'alice-token', body: { schemaVersion: '2', caseId: snapshot.caseId,
    expectedCaseRevision: 3, programId: 'hpsm-eaa', expectedIntakeRevision: 1, expectedQuestionnaireVersion: definition.questionnaireVersion,
    answers: [] } }, deps);
  assert.equal(changed.status, 200);
  assert.equal((await handleDraftExport({ bearerToken: 'alice-token', body: download }, deps, 'download-draft-export', 2)).status, 409);
});
