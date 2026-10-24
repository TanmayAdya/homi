import assert from 'node:assert/strict';
import test from 'node:test';
import { createScfhpEaaFormTemplate } from '../src/forms/scfhp-eaa-template.ts';
import { planFormFields } from '../src/forms/field-mapping.ts';
import type { CaseSnapshot } from '../src/types.ts';

function snapshot(): CaseSnapshot {
  return { schemaVersion: '1', caseId: 'fictional-form-review', revision: 4,
    profile: { city: 'San Jose', county: 'Santa Clara', healthPlan: 'SCFHP', tenure: 'owner', ageYears: 70,
      householdSize: 1, annualIncomeUsd: 0, ownerConsentReported: true },
    unresolvedFields: [], findings: [{ id: 'step', room: 'entrance', observation: 'A step was observed.',
      reviewState: 'confirmed', evidenceIds: ['photo-not-attached'], measurements: [] }] };
}
const context = { programId: 'scfhp-eaa',
  templateSha256: 'ebd403673949e7fa01005789700fa6baddd77d351de90a44f7fee1eb81516cd7',
  plannedAt: '2026-10-17T19:00:00Z' };

test('reviewed 41567 inventory is exact: five pages, 48 canonical fields and 71 physical widgets', () => {
  const template = createScfhpEaaFormTemplate();
  assert.equal(template.templateSha256, context.templateSha256);
  assert.equal(template.publisherRevision, null);
  assert.equal(template.formVersion, `sha256:${context.templateSha256}`);
  assert.equal(template.pageCount, 5);
  assert.equal(template.fields.length, 48);
  assert.equal(template.fields.flatMap(field => field.widgets).length, 71);
  assert.equal(template.fields.filter(field => field.pdfType === 'Tx').length, 25);
  assert.equal(template.fields.filter(field => field.pdfType === 'Btn').length, 22);
  assert.equal(template.fields.filter(field => field.pdfType === 'Sig').length, 1);
});

test('only EAA routing maps and the asthma sibling explicitly stays off', () => {
  const plan = planFormFields(snapshot(), createScfhpEaaFormTemplate(), context);
  assert.deepEqual(plan.summary, { mapped: 1, missing: 18, requiresReview: 25, notApplicable: 4 });
  const route = plan.fields.find(field => field.status === 'mapped')!;
  assert.equal(route.fieldName, 'undefined_2'); assert.equal(route.value, 'On');
  assert.deepEqual(route.widgetValues, ['Off', 'On']);
  assert.equal(route.widgets[1].page, 1);
  assert.deepEqual(route.widgets[1].rect, [44.68, 64.16, 60.52, 80]);
  assert.ok(plan.fields.filter(field => field !== route).every(field => field.value === null));
  assert.equal(plan.caseRevision, 4); assert.equal(plan.status, 'draft');
});

test('age, ownership, permission and observed hazards cannot populate DOB, consent, clinical answers or signature', () => {
  const plan = planFormFields(snapshot(), createScfhpEaaFormTemplate(), context);
  for (const name of ['Date of Birth', 'ha', 'undefined_3', 'undefined_4', 'Check Box5', 'Check Box57', 'Text7', 'Signature4', 'Signature Date']) {
    const field = plan.fields.find(field => field.fieldName === name)!;
    assert.equal(field.value, null); assert.equal(field.origin, null);
    assert.ok(field.status === 'missing' || field.status === 'requires_review');
    assert.ok(field.widgetValues.every(value => value === null));
  }
  assert.ok(!JSON.stringify(plan).includes('A step was observed.'));
  assert.ok(!JSON.stringify(plan).includes('photo-not-attached'));
});

test('layout overlays and unrelated asthma questions do not become EAA requirements', () => {
  const plan = planFormFields(snapshot(), createScfhpEaaFormTemplate(), context);
  const skipped = plan.fields.filter(field => field.status === 'not_applicable');
  assert.equal(skipped.length, 4);
  assert.ok(skipped.every(field => field.resolvedBy === null && field.value === null));
  assert.ok(skipped.some(field => field.fieldName === 'undefined_31'));
  assert.ok(skipped.some(field => field.fieldName === 'undefined_41'));
});

test('another program, changed PDF or planning before source review cannot reuse this map', () => {
  for (const override of [{ programId: 'other' }, { templateSha256: 'a'.repeat(64) }, { plannedAt: '2026-10-16T23:59:59Z' }]) {
    assert.throws(() => planFormFields(snapshot(), createScfhpEaaFormTemplate(), { ...context, ...override }));
  }
});
