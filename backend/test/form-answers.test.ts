import assert from 'node:assert/strict';
import test from 'node:test';
import { createFormAnswerContext, createSavedFormAnswers, FORM_ANSWER_FIELDS, FormAnswerValidationError,
  formAnswersAreCurrent, parseFormAnswerInputs, parseSavedFormAnswers } from '../src/forms/form-answers.ts';
import { defineVerifiedFormTemplate, planFormFields } from '../src/forms/field-mapping.ts';
import { createScfhpEaaFormTemplate } from '../src/forms/scfhp-eaa-template.ts';
import { fictionalReviewedAnswers } from '../fixtures/reviewed-form-answers.ts';
import type { CaseSnapshot } from '../src/types.ts';

const snapshot: CaseSnapshot = { schemaVersion: '1', caseId: 'fictional-answers', revision: 2,
  profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: 100,
    householdSize: null, annualIncomeUsd: null, ownerConsentReported: true }, unresolvedFields: [], findings: [] };
const now = '2026-10-17T19:00:00.123456Z';
const template = createScfhpEaaFormTemplate();
const context = createFormAnswerContext(template);
const planning = { programId: template.programId, templateSha256: template.templateSha256, plannedAt: now };
const input = { key: 'memberFirstName', value: 'Alex', reviewState: 'reviewed' };
const saved = () => fictionalReviewedAnswers(snapshot, template, now);

test('answer policy allows precisely the 18 reviewed identity, contact and administrative fields', () => {
  assert.equal(FORM_ANSWER_FIELDS.length, 18);
  assert.ok(Object.isFrozen(FORM_ANSWER_FIELDS) && FORM_ANSWER_FIELDS.every(Object.isFrozen));
  assert.deepEqual(parseFormAnswerInputs([]), []);
  assert.deepEqual(parseFormAnswerInputs([{ ...input, value: null, reviewState: 'needs_review' }]), [
    { key: 'memberFirstName', value: null, reviewState: 'needs_review' },
  ]);
  for (const key of ['diagnosis', 'signature', 'signatureDate', 'ownerConsent', 'Text7', 'memberAge', '__proto__']) {
    assert.throws(() => parseFormAnswerInputs([{ ...input, key }]), FormAnswerValidationError);
  }
});

test('strict inputs reject provenance overrides, duplicates, controls, implicit normalization and invalid scalars', () => {
  for (const invalid of [null, {}, [input, input], [{ ...input, reviewedBy: 'other-user' }],
    [{ ...input, value: null }], [{ ...input, reviewState: 'confirmed' }],
    ...['', ' ', ' Alex', 'Alex ', 'Alex\nExample', 'a\0b', 'a\u0085b', 'a\u2028b', 'a\u2029b', '\ud800', 'x'.repeat(161)]
      .map(value => [{ ...input, value }])]) {
    assert.throws(() => parseFormAnswerInputs(invalid), FormAnswerValidationError);
  }
  assert.equal(parseFormAnswerInputs([{ ...input, value: '🙂'.repeat(160) }])[0].value, '🙂'.repeat(160));
  assert.equal(parseFormAnswerInputs([{ ...input, value: 'Zoë O’Example' }])[0].value, 'Zoë O’Example');
});

test('dates are actual supplied civil dates and email values have bounded email shape', () => {
  for (const value of ['0000-01-01', '2025-02-29', '2026-04-31', '10/17/2026', '2026-1-01']) {
    assert.throws(() => parseFormAnswerInputs([{ ...input, key: 'memberBirthDate', value }]));
  }
  assert.equal(parseFormAnswerInputs([{ ...input, key: 'memberBirthDate', value: '2000-02-29' }])[0].value, '2000-02-29');
  assert.throws(() => parseFormAnswerInputs([
    { ...input, key: 'memberBirthDate', value: '2001-01-01' },
    { ...input, key: 'referralDate', value: '2000-12-31' },
  ]));
  for (const value of ['missing-at.example.org', 'a@b', 'a b@example.org', 'a@@example.org']) {
    assert.throws(() => parseFormAnswerInputs([{ ...input, key: 'referrerEmail', value }]));
  }
});

test('server-stamped saved records are detached and canonical, with explicit null review provenance', () => {
  const inputs = parseFormAnswerInputs([{ ...input, reviewState: 'needs_review' },
    { key: 'memberPhone', value: '408-555-0101', reviewState: 'reviewed' }]);
  const result = createSavedFormAnswers({ snapshot, context, answerRevision: 1, answers: inputs,
    updatedAt: now, updatedBy: 'fictional-preparer' });
  inputs[0].value = 'changed';
  assert.equal(result.answers[0].value, 'Alex');
  assert.equal(result.answers[0].reviewedAt, null); assert.equal(result.answers[0].reviewedBy, null);
  assert.equal(result.answers[1].reviewedAt, now); assert.equal(result.answers[1].reviewedBy, 'fictional-preparer');
  const detached = parseSavedFormAnswers(result); result.answers[0].value = 'changed again';
  assert.equal(detached.answers[0].value, 'Alex');
});

test('invalid saved identities, revisions, temporal provenance and future supplied dates fail closed', () => {
  const invalids = [
    { ...saved(), updatedAt: '0000-01-01T00:00:00Z' }, { ...saved(), caseRevision: 0 },
    { ...saved(), answerRevision: Number.MAX_SAFE_INTEGER + 1 }, { ...saved(), formContextId: 'A'.repeat(64) },
    { ...saved(), updatedBy: ' actor ' }, { ...saved(), extra: true },
  ];
  for (const item of invalids) assert.throws(() => parseSavedFormAnswers(item));
  for (const change of [
    { reviewedAt: '2026-10-17T19:00:00.123457Z' }, { reviewedBy: null }, { reviewedAt: null },
    { reviewState: 'needs_review' },
  ]) {
    const record = saved(); Object.assign(record.answers[0], change);
    assert.throws(() => parseSavedFormAnswers(record));
  }
  for (const key of ['memberBirthDate', 'referralDate']) {
    assert.throws(() => createSavedFormAnswers({ snapshot, context, answerRevision: 1,
      answers: parseFormAnswerInputs([{ ...input, key, value: '2026-10-18' }]), updatedAt: now, updatedBy: 'actor' }));
  }
});

test('currentness and full form context bind version strings, field labels, geometry and policy', () => {
  assert.equal(formAnswersAreCurrent(saved(), snapshot, context), true);
  for (const override of [{ caseId: 'other' }, { revision: 3 }]) {
    assert.equal(formAnswersAreCurrent(saved(), { ...snapshot, ...override }, context), false);
  }
  for (const override of [{ programId: 'other' }, { formVersion: 'other' }, { mappingVersion: 'other' }, { formContextId: 'b'.repeat(64) }]) {
    assert.equal(formAnswersAreCurrent(saved(), snapshot, { ...context, ...override }), false);
  }
  const changed = structuredClone(template) as any;
  changed.fields[0].label = 'Changed reviewed label';
  assert.notEqual(createFormAnswerContext(defineVerifiedFormTemplate(changed)).formContextId, context.formContextId);
  assert.deepEqual(createFormAnswerContext(defineVerifiedFormTemplate(structuredClone(template))), context);
});

test('only reviewed current answers populate exact values with explicit date transformation and provenance', () => {
  const record = saved();
  const plan = planFormFields(snapshot, template, planning, record);
  assert.deepEqual(plan.summary, { mapped: 19, missing: 0, requiresReview: 25, notApplicable: 4 });
  const birth = plan.fields.find(field => field.fieldName === 'Date of Birth')!;
  assert.equal(birth.value, '02/29/1956');
  assert.deepEqual(birth.origin, { kind: 'reviewed_form_answer', answerKey: 'memberBirthDate', sourceValue: '1956-02-29',
    answerRevision: 1, reviewedBy: 'fictional-preparer', reviewedAt: now,
    formContextId: context.formContextId, valueTransform: 'iso_date_to_mm_dd_yyyy' });
  assert.ok(plan.fields.filter(field => ['clinical', 'consent', 'signature'].includes(field.semantic)).every(field => field.value === null));
  assert.ok(Object.isFrozen(plan.fields));
});

test('missing and unreviewed answers stay blank; stale records and future saves cannot be silently reused', () => {
  const record = createSavedFormAnswers({ snapshot, context, answerRevision: 1,
    answers: parseFormAnswerInputs([{ ...input, reviewState: 'needs_review' }]), updatedAt: now, updatedBy: 'actor' });
  const plan = planFormFields(snapshot, template, planning, record);
  assert.equal(plan.fields[0].status, 'requires_review'); assert.equal(plan.fields[0].value, null);
  assert.equal(plan.fields[1].status, 'missing');
  for (const override of [{ caseRevision: 1 }, { caseId: 'other' }, { formContextId: 'b'.repeat(64) },
    { updatedAt: '2026-10-18T00:00:00Z' }]) {
    assert.throws(() => planFormFields(snapshot, template, planning, { ...record, ...override }));
  }
});

test('allowlisted answer bindings cannot be repurposed for clinical or signature fields', () => {
  for (const override of [{ fieldName: 'Text7', semantic: 'clinical' }, { semantic: 'consent' },
    { semantic: 'signature', pdfType: 'Sig' }, { binding: { kind: 'reviewed_answer', answerKey: 'diagnosis' } }]) {
    const changed = structuredClone(template) as any;
    Object.assign(changed.fields[0], override);
    assert.throws(() => defineVerifiedFormTemplate(changed));
  }
});
