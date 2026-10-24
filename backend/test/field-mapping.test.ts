import assert from 'node:assert/strict';
import test from 'node:test';
import {
  defineVerifiedFormTemplate, FormMappingError, planFormFields,
  type FormFieldDefinition, type FormPlanningContext, type VerifiedFormTemplate,
} from '../src/forms/field-mapping.ts';
import type { CaseSnapshot } from '../src/types.ts';

const hash = 'a'.repeat(64);
const context: FormPlanningContext = {
  programId: 'fictional-home-support', templateSha256: hash, plannedAt: '2026-10-17T19:00:00.123456Z',
};

function snapshot(): CaseSnapshot {
  return { schemaVersion: '1', caseId: 'fictional-case', revision: 3,
    profile: { city: 'Demo City', county: 'Demo County', healthPlan: 'Example Plan', tenure: 'owner',
      ageYears: 65, householdSize: 1, annualIncomeUsd: 0, ownerConsentReported: true },
    unresolvedFields: ['profile.city', 'profile.ownerConsentReported'],
    findings: [{ id: 'fictional-finding', room: 'bathroom', observation: 'Fictional resident observation, not a diagnosis.',
      reviewState: 'confirmed', evidenceIds: ['fictional-evidence'], measurements: [] }] };
}

function manualField(
  fieldName: string, semantic: string, reason: string, resolvedBy = 'resident', pdfType = 'Tx',
): Record<string, unknown> {
  return { fieldName, label: `Synthetic ${fieldName}`, semantic, pdfType, required: false, maxLength: null,
    widgets: [{ page: 1, rect: [10, 20, 40, 30], exportValue: pdfType === 'Btn' ? 'Yes' : null }],
    binding: { kind: 'manual', reason, resolvedBy } };
}

function definition(): Record<string, unknown> {
  return { schemaVersion: '1', programId: context.programId, formVersion: `sha256:${hash}`,
    mappingVersion: 'synthetic-mapping-v1', templateSha256: hash, publisherRevision: null,
    sourceUrl: 'https://example.org/synthetic-template.pdf', sourcePageUrl: 'https://example.org/forms',
    reviewedOn: '2026-10-17', pageCount: 2,
    fields: [
      { fieldName: 'synthetic_route', label: 'Synthetic service route', semantic: 'routing', pdfType: 'Btn',
        required: false, maxLength: null,
        widgets: [{ page: 1, rect: [10, 40, 20, 50], exportValue: 'OtherRoute' },
          { page: 1, rect: [10, 20, 20, 30], exportValue: 'HomeRoute' }],
        binding: { kind: 'routing', programId: context.programId, widgetIndex: 1, value: 'HomeRoute' } },
      manualField('member_name', 'identity', 'not_collected'),
      manualField('birth_date', 'identity', 'not_collected'),
      manualField('full_address', 'contact', 'not_collected'),
      manualField('medical_necessity', 'clinical', 'clinical_review', 'professional'),
      manualField('member_consent', 'consent', 'consent_review', 'resident', 'Btn'),
      manualField('signature', 'signature', 'signature_review', 'resident', 'Sig'),
      manualField('heading_artifact', 'layout', 'layout_only', 'program'),
      manualField('unrelated_question', 'clinical', 'out_of_scope', 'professional', 'Btn'),
    ] };
}

function fields(value: Record<string, unknown>): Record<string, unknown>[] {
  return value.fields as Record<string, unknown>[];
}

function rejectDefinition(mutate: (value: Record<string, unknown>) => void): void {
  const input = definition();
  mutate(input);
  assert.throws(() => defineVerifiedFormTemplate(input), FormMappingError);
}

test('plan binds deterministic decisions to case, reviewed mapping and exact PDF content', () => {
  const template = defineVerifiedFormTemplate(definition());
  const value = snapshot();
  const plan = planFormFields(value, template, context);
  assert.deepEqual(plan, planFormFields(value, template, context));
  assert.equal(plan.schemaVersion, '1');
  assert.equal(plan.status, 'draft');
  assert.equal(plan.caseId, value.caseId);
  assert.equal(plan.caseRevision, value.revision);
  assert.equal(plan.programId, template.programId);
  assert.equal(plan.formVersion, `sha256:${hash}`);
  assert.equal(plan.mappingVersion, template.mappingVersion);
  assert.equal(plan.publisherRevision, null);
  assert.equal(plan.plannedAt, context.plannedAt);
  assert.deepEqual(plan.summary, { mapped: 1, missing: 3, requiresReview: 3, notApplicable: 2 });
  const route = plan.fields[0];
  assert.equal(route.status, 'mapped');
  assert.equal(route.value, 'HomeRoute');
  assert.deepEqual(route.widgetValues, ['Off', 'HomeRoute']);
  assert.deepEqual(route.origin, { kind: 'verified_program_routing', programId: template.programId,
    templateSha256: hash, mappingVersion: template.mappingVersion,
    sourceUrl: template.sourceUrl, reviewedOn: template.reviewedOn });
  assert.equal(route.reasonCode, 'ROUTING_SELECTED');
  assert.equal(route.resolvedBy, null);
});

test('age, city, plan, reported owner consent and reviewed observations never fill protected fields', () => {
  const template = defineVerifiedFormTemplate(definition());
  const plan = planFormFields(snapshot(), template, context);
  for (const decision of plan.fields.slice(1)) {
    assert.equal(decision.value, null);
    assert.ok(decision.widgetValues.every(value => value === null));
    assert.equal(decision.origin, null);
  }
  assert.equal(plan.fields.find(field => field.fieldName === 'birth_date')!.status, 'missing');
  assert.equal(plan.fields.find(field => field.fieldName === 'full_address')!.status, 'missing');
  assert.equal(plan.fields.find(field => field.fieldName === 'member_consent')!.status, 'requires_review');
  assert.equal(plan.fields.find(field => field.fieldName === 'medical_necessity')!.resolvedBy, 'professional');
  const serialized = JSON.stringify(plan);
  assert.ok(!serialized.includes('Demo City'));
  assert.ok(!serialized.includes('Example Plan'));
  assert.ok(!serialized.includes('Fictional resident observation'));
  assert.ok(!serialized.includes('fictional-evidence'));
  const changed = snapshot();
  changed.profile.city = null;
  changed.profile.ageYears = null;
  changed.profile.ownerConsentReported = false;
  assert.deepEqual(planFormFields(changed, template, context).fields, plan.fields);
});

test('PDF optional flags do not suppress unknown identity or required human reviews', () => {
  const input = definition();
  fields(input).forEach(field => { field.required = false; });
  let plan = planFormFields(snapshot(), defineVerifiedFormTemplate(input), context);
  assert.equal(plan.summary.missing, 3);
  assert.equal(plan.summary.requiresReview, 3);
  fields(input).filter(field => ['consent', 'clinical', 'signature'].includes(String(field.semantic)))
    .forEach(field => { field.required = true; });
  plan = planFormFields(snapshot(), defineVerifiedFormTemplate(input), context);
  assert.ok(plan.fields.filter(field => ['member_consent', 'medical_necessity', 'signature'].includes(field.fieldName))
    .every(field => field.value === null && field.status === 'requires_review'));
});

test('layout artifacts and reviewed unrelated questions stay blank without actionable tasks', () => {
  const plan = planFormFields(snapshot(), defineVerifiedFormTemplate(definition()), context);
  const skipped = plan.fields.filter(field => field.status === 'not_applicable');
  assert.deepEqual(skipped.map(field => field.fieldName), ['heading_artifact', 'unrelated_question']);
  assert.ok(skipped.every(field => field.value === null && field.resolvedBy === null));
  assert.deepEqual(skipped.map(field => field.reasonCode), ['LAYOUT_ONLY', 'OUT_OF_SCOPE']);
});

test('template data and planned decisions are detached, frozen and serializable', () => {
  const input = definition();
  const template = defineVerifiedFormTemplate(input);
  const plan = planFormFields(snapshot(), template, context);
  fields(input)[0].label = 'Changed later';
  assert.notEqual(template.fields[0].label, 'Changed later');
  assert.ok(Object.isFrozen(template));
  assert.ok(Object.isFrozen(template.fields));
  assert.ok(Object.isFrozen(template.fields[0].widgets[0].rect));
  assert.ok(Object.isFrozen(plan.fields[0].widgetValues));
  assert.throws(() => Object.defineProperty(plan.fields[0], 'value', { value: 'OtherRoute' }), TypeError);
  assert.deepEqual(defineVerifiedFormTemplate(JSON.parse(JSON.stringify(template))), template);
  assert.deepEqual(JSON.parse(JSON.stringify(plan)), plan);
});

test('program, artifact hash, case identity and preparation time cannot silently drift', () => {
  const template = defineVerifiedFormTemplate(definition());
  for (const bad of [
    { ...context, programId: 'other-program' },
    { ...context, templateSha256: 'b'.repeat(64) },
    { ...context, templateSha256: hash.toUpperCase() },
    { ...context, plannedAt: '2026-02-30T19:00:00Z' },
    { ...context, plannedAt: '2026-10-17T19:00:00-07:00' },
    { ...context, plannedAt: '2026-10-16T19:00:00Z' },
    { ...context, plannedAt: '2026-10-17T19:00:00Z\n' },
  ]) assert.throws(() => planFormFields(snapshot(), template, bad), FormMappingError);
  for (const change of [
    { caseId: ' ' }, { caseId: '😀'.repeat(201) }, { caseId: '\ud800' },
    { revision: 0 }, { revision: 1.5 }, { revision: Number.MAX_SAFE_INTEGER + 1 },
    { schemaVersion: '2' },
  ]) assert.throws(() => planFormFields({ ...snapshot(), ...change } as CaseSnapshot, template, context), FormMappingError);
  const valid = { ...snapshot(), caseId: '😀'.repeat(200), revision: Number.MAX_SAFE_INTEGER };
  assert.equal(planFormFields(valid, template, context).caseRevision, Number.MAX_SAFE_INTEGER);
});

test('content version cannot masquerade as a publisher revision', () => {
  rejectDefinition(input => { input.formVersion = '2025-12-07'; });
  rejectDefinition(input => { input.formVersion = `sha256:${'b'.repeat(64)}`; });
  const input = definition();
  input.publisherRevision = 'Explicit fictional publisher revision';
  const template = defineVerifiedFormTemplate(input);
  assert.equal(template.formVersion, `sha256:${hash}`);
  assert.equal(template.publisherRevision, 'Explicit fictional publisher revision');
});

test('template and nested field boundaries reject unknown, missing and unsupported data', () => {
  for (const mutation of [
    (value: Record<string, unknown>) => { value.unknown = true; },
    (value: Record<string, unknown>) => { delete value.publisherRevision; },
    (value: Record<string, unknown>) => { value.fields = []; },
    (value: Record<string, unknown>) => { value.fields = [fields(value)[0], fields(value)[0]]; },
    (value: Record<string, unknown>) => { value.reviewedOn = '2026-02-30'; },
    (value: Record<string, unknown>) => { value.sourceUrl = 'http://example.org/form.pdf'; },
    (value: Record<string, unknown>) => { value.sourceUrl = 'https://private@example.org/form.pdf'; },
    (value: Record<string, unknown>) => { value.pageCount = 0; },
    (value: Record<string, unknown>) => { fields(value)[0].pdfType = 'unknown'; },
    (value: Record<string, unknown>) => { fields(value)[0].pdfType = { toString: () => 'Btn' }; },
    (value: Record<string, unknown>) => { fields(value)[0].maxLength = -1; },
    (value: Record<string, unknown>) => { fields(value)[0].fieldName = 'x'.repeat(1025); },
    (value: Record<string, unknown>) => { fields(value)[0].required = 'true'; },
    (value: Record<string, unknown>) => { fields(value)[1].casePath = 'profile.ageYears'; },
    (value: Record<string, unknown>) => { fields(value)[0].binding = { kind: 'case', path: 'profile.city' }; },
  ]) rejectDefinition(mutation);
  for (const value of [null, [], 'template']) assert.throws(() => defineVerifiedFormTemplate(value), FormMappingError);
});

test('physical widget metadata and routing appearances must match the reviewed inventory', () => {
  for (const mutate of [
    (field: Record<string, unknown>) => { field.widgets = []; },
    (field: Record<string, unknown>) => { (field.widgets as Record<string, unknown>[])[0].page = 3; },
    (field: Record<string, unknown>) => { (field.widgets as Record<string, unknown>[])[0].rect = [0, 0, 0, 1]; },
    (field: Record<string, unknown>) => { (field.widgets as Record<string, unknown>[])[0].rect = [0, 0, Infinity, 1]; },
    (field: Record<string, unknown>) => { (field.widgets as Record<string, unknown>[])[0].exportValue = 'Off'; },
    (field: Record<string, unknown>) => { field.widgets = [
      (field.widgets as Record<string, unknown>[])[0], (field.widgets as Record<string, unknown>[])[0],
    ]; },
    (field: Record<string, unknown>) => { (field.binding as Record<string, unknown>).programId = 'another'; },
    (field: Record<string, unknown>) => { (field.binding as Record<string, unknown>).widgetIndex = 2; },
    (field: Record<string, unknown>) => { (field.binding as Record<string, unknown>).value = 'OtherRoute'; },
  ]) rejectDefinition(value => mutate(fields(value)[0]));
});

test('protected semantics cannot be automatically mapped or silently skipped', () => {
  for (const semantic of ['identity', 'contact', 'clinical', 'consent', 'signature', 'layout']) {
    rejectDefinition(value => { fields(value)[0].semantic = semantic; });
  }
  rejectDefinition(value => { fields(value)[0].pdfType = 'Tx'; });
  rejectDefinition(value => { fields(value)[4].binding = { kind: 'manual', reason: 'not_collected', resolvedBy: 'resident' }; });
  rejectDefinition(value => { fields(value)[4].binding = { kind: 'manual', reason: 'clinical_review', resolvedBy: 'resident' }; });
  rejectDefinition(value => { fields(value)[5].binding = { kind: 'manual', reason: 'out_of_scope', resolvedBy: 'resident' }; });
  rejectDefinition(value => { fields(value)[6].binding = { kind: 'manual', reason: 'program_review', resolvedBy: 'program' }; });
  rejectDefinition(value => { fields(value)[1].binding = { kind: 'manual', reason: 'layout_only', resolvedBy: 'program' }; });
});

test('runtime planning revalidates configuration even if a TypeScript type assertion bypasses construction', () => {
  const template = structuredClone(defineVerifiedFormTemplate(definition()));
  const forged = { ...template, fields: [{ ...template.fields[0],
    binding: { kind: 'routing', programId: context.programId, widgetIndex: 0, value: 'HomeRoute' },
  } as FormFieldDefinition] } as VerifiedFormTemplate;
  assert.throws(() => planFormFields(snapshot(), forged, context), FormMappingError);
});
