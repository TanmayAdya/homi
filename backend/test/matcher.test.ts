import assert from 'node:assert/strict';
import test from 'node:test';
import { InputValidationError, matchPrograms } from '../src/matcher.ts';
import type { CaseSnapshot, Criterion, ProgramDefinition, Rule } from '../src/types.ts';
import { demoContext, demoProgram } from '../fixtures/demo-program.ts';

const matchedCase: CaseSnapshot = {
  schemaVersion: '1', caseId: 'unit-test-case', revision: 1,
  profile: {
    city: 'Demo City', county: null, healthPlan: 'Example Plan', tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null,
  },
  unresolvedFields: [], findings: [],
};
const missingPlanCase: CaseSnapshot = { ...matchedCase, profile: { ...matchedCase.profile, healthPlan: null } };
const wrongPlanCase: CaseSnapshot = { ...matchedCase, profile: { ...matchedCase.profile, healthPlan: 'Different Plan' } };

const clone = <T>(value: T): T => structuredClone(value);
const result = (snapshot: unknown = matchedCase, program: unknown = demoProgram, context: unknown = demoContext) => matchPrograms(snapshot, [program], context).matches[0];
const rule = (field: 'city' | 'healthPlan', value: string): Extract<Rule, { kind: 'eq' }> => ({ kind: 'eq', field, value, sourceIds: [], resolvedBy: 'resident' });
const plan = rule('healthPlan', 'Example Plan');
const city = rule('city', 'Demo City');
const withCriterion = (criterion: Criterion): ProgramDefinition => ({ ...clone(demoProgram), criteria: [criterion] });

function sourcedProgram(): ProgramDefinition {
  const program = clone(demoProgram);
  program.isDemo = false;
  program.programId = 'synthetic-verified-program';
  program.programName = 'Synthetic verified-source test';
  program.rulesVerified = true;
  program.reviewedOn = '2026-10-12';
  program.sources = [{
    id: 'synthetic-source', url: 'https://example.org/fictional-rules', title: 'Synthetic policy fixture',
    reviewedOn: '2026-10-12', effectiveFrom: '2026-01-01', effectiveUntil: '2026-12-31',
  }];
  program.criteria = program.criteria.map(criterion => ({
    ...criterion,
    rule: { ...criterion.rule, sourceIds: ['synthetic-source'] } as Rule,
  }));
  return program;
}

const manualReview = {
  kind: 'manual_review', reason: 'Review the synthetic supporting evidence.',
  sourceIds: ['synthetic-source'], resolvedBy: 'professional',
} satisfies Rule;

function manualProgram(rule: Rule = clone(manualReview)): ProgramDefinition {
  return { ...sourcedProgram(), criteria: [{ id: 'review', label: 'Synthetic review', rule }] };
}

test('matching demo preserves case identity, revision, clock, and demo labels', () => {
  const response = matchPrograms(matchedCase, [demoProgram], demoContext);
  assert.equal(response.schemaVersion, '1');
  assert.equal(response.caseId, matchedCase.caseId);
  assert.equal(response.caseRevision, 1);
  assert.equal(response.evaluatedAt, demoContext.evaluatedAt);
  assert.equal(response.evaluationDate, demoContext.evaluationDate);
  assert.equal(response.matches[0].status, 'meets_known_criteria');
  assert.equal(response.matches[0].isDemo, true);
  assert.equal(response.matches[0].availability, 'unverified');
  assert.equal(response.matches[0].intake, null);
  assert.deepEqual(response.matches[0].checks.map(check => check.status), ['pass', 'pass']);
});

test('missing plan remains unknown and identifies the needed answer', () => {
  const match = result(missingPlanCase);
  assert.equal(match.status, 'needs_confirmation');
  assert.deepEqual(match.checks[1].missingFields, ['profile.healthPlan']);
  assert.equal(match.checks[1].resolvedBy, 'resident');
  assert.equal(match.checks[1].reasonCode, 'missing_input');
});

test('known wrong plan fails its criterion with an explanation', () => {
  const match = result(wrongPlanCase);
  assert.equal(match.status, 'does_not_meet_criterion');
  assert.equal(match.checks[1].status, 'fail');
  assert.equal(match.checks[1].reasonCode, 'criterion_not_satisfied');
  assert.match(match.checks[1].explanation, /Health plan:/);
});

test('conflicting answers override an otherwise matching value', () => {
  const snapshot = { ...matchedCase, unresolvedFields: ['profile.healthPlan'] };
  assert.equal(result(snapshot).status, 'needs_confirmation');
  assert.equal(result(snapshot).checks[1].reasonCode, 'unresolved_input');
});

test('blank strings are rejected; nonblank answers are not silently normalized', () => {
  assert.throws(() => result({ ...matchedCase, profile: { ...matchedCase.profile, healthPlan: '  ' } }), InputValidationError);
  assert.equal(result({ ...matchedCase, profile: { ...matchedCase.profile, healthPlan: ' Example Plan ' } }).status, 'does_not_meet_criterion');
});

test('false remains a real boolean answer, not unknown', () => {
  const snapshot = { ...matchedCase, profile: { ...matchedCase.profile, ownerConsentReported: false } };
  const program = withCriterion({ id: 'consent', label: 'Synthetic consent check', rule: { kind: 'eq', field: 'ownerConsentReported', value: false, sourceIds: [], resolvedBy: 'resident' } });
  assert.equal(result(snapshot, program).status, 'meets_known_criteria');
  program.criteria[0].rule = { ...program.criteria[0].rule, value: true } as Rule;
  assert.equal(result(snapshot, program).status, 'does_not_meet_criterion');
});

test('zero income and zero age are real values; null remains unknown', () => {
  const program = withCriterion({ id: 'zero', label: 'Synthetic zero check', rule: {
    kind: 'and', rules: [
      { kind: 'lte', field: 'annualIncomeUsd', value: 0, sourceIds: [], resolvedBy: 'resident' },
      { kind: 'gte', field: 'ageYears', value: 0, sourceIds: [], resolvedBy: 'resident' },
    ],
  } });
  assert.equal(result({ ...matchedCase, profile: { ...matchedCase.profile, annualIncomeUsd: 0, ageYears: 0 } }, program).status, 'meets_known_criteria');
  assert.equal(result(matchedCase, program).status, 'needs_confirmation');
});

test('finite negative income is preserved by the shared schema', () => {
  const program = withCriterion({ id: 'income', label: 'Synthetic income check', rule: { kind: 'lte', field: 'annualIncomeUsd', value: 0, sourceIds: [], resolvedBy: 'resident' } });
  assert.equal(result({ ...matchedCase, profile: { ...matchedCase.profile, annualIncomeUsd: -10 } }, program).status, 'meets_known_criteria');
});

test('synthetic gte and lte boundaries are inclusive', () => {
  for (const [kind, expected] of [['gte', ['fail', 'pass', 'pass']], ['lte', ['pass', 'pass', 'fail']]] as const) {
    const program = withCriterion({ id: 'age', label: 'Synthetic age check', rule: { kind, field: 'ageYears', value: 60, sourceIds: [], resolvedBy: 'resident' } });
    for (const [index, ageYears] of [59, 60, 61].entries()) {
      assert.equal(result({ ...matchedCase, profile: { ...matchedCase.profile, ageYears } }, program).checks[0].status, expected[index]);
    }
  }
});

test('AND can fail a known requirement while retaining another missing input', () => {
  const program = withCriterion({ id: 'combined', label: 'Combined', rule: { kind: 'and', rules: [rule('city', 'Different City'), plan] } });
  const check = result(missingPlanCase, program).checks[0];
  assert.equal(check.status, 'fail');
  assert.deepEqual(check.missingFields, ['profile.healthPlan']);
});

test('OR with a failed alternative and unknown alternative cannot reject', () => {
  const program = withCriterion({ id: 'alternative', label: 'Alternative', rule: { kind: 'or', rules: [rule('city', 'Different City'), plan] } });
  assert.equal(result(missingPlanCase, program).status, 'needs_confirmation');
});

test('OR accepts a passing alternative without requesting an unnecessary answer', () => {
  const program = withCriterion({ id: 'alternative', label: 'Alternative', rule: { kind: 'or', rules: [city, plan] } });
  const check = result(missingPlanCase, program).checks[0];
  assert.equal(check.status, 'pass');
  assert.deepEqual(check.missingFields, []);
});

test('OR fails only when all alternatives fail', () => {
  const program = withCriterion({ id: 'alternative', label: 'Alternative', rule: { kind: 'or', rules: [rule('city', 'Different City'), plan] } });
  assert.equal(result(wrongPlanCase, program).status, 'does_not_meet_criterion');
});

test('a passing documented exception overrides a failing base check', () => {
  const program = withCriterion({ id: 'exception', label: 'Exception', rule: rule('city', 'Different City'), exception: plan });
  const check = result(matchedCase, program).checks[0];
  assert.equal(check.status, 'pass');
  assert.equal(check.reasonCode, 'exception_satisfied');
});

test('an unknown applicable exception keeps an apparent rejection unresolved', () => {
  const program = withCriterion({ id: 'exception', label: 'Exception', rule: rule('city', 'Different City'), exception: plan });
  const check = result(missingPlanCase, program).checks[0];
  assert.equal(check.status, 'unknown');
  assert.equal(check.reasonCode, 'criterion_or_exception_unresolved');
});

test('a failed base and failed exception make a resolved failure', () => {
  const program = withCriterion({ id: 'exception', label: 'Exception', rule: rule('city', 'Different City'), exception: plan });
  assert.equal(result(wrongPlanCase, program).checks[0].reasonCode, 'criterion_and_exception_failed');
});

test('a passing exception can resolve missing base information', () => {
  const program = withCriterion({ id: 'exception', label: 'Exception', rule: plan, exception: city });
  const check = result(missingPlanCase, program).checks[0];
  assert.equal(check.status, 'pass');
  assert.deepEqual(check.missingFields, []);
});

test('independent known disqualifier remains a failure while unknowns stay visible', () => {
  const program = clone(demoProgram);
  program.criteria[0].rule = rule('city', 'Different City');
  assert.equal(result(missingPlanCase, program).status, 'does_not_meet_criterion');
  assert.deepEqual(result(missingPlanCase, program).checks.map(check => check.status), ['fail', 'unknown']);
});

test('rule output is deterministic and does not mutate input or registry', () => {
  const snapshotBefore = clone(matchedCase);
  const registryBefore = clone(demoProgram);
  const first = matchPrograms(matchedCase, [demoProgram], demoContext);
  assert.deepEqual(first, matchPrograms(matchedCase, [demoProgram], demoContext));
  assert.deepEqual(matchedCase, snapshotBefore);
  assert.deepEqual(demoProgram, registryBefore);
  first.matches[0].requiredDocuments.push('external mutation');
  assert.deepEqual(demoProgram, registryBefore);
});

test('changed case revision and answer produce a new attributable result', () => {
  const revised = { ...missingPlanCase, caseId: matchedCase.caseId, revision: 2 };
  const response = matchPrograms(revised, [demoProgram], demoContext);
  assert.equal(response.caseRevision, 2);
  assert.equal(response.matches[0].status, 'needs_confirmation');
});

test('an unverified real program cannot produce positive or negative eligibility conclusions', () => {
  const program = { ...demoProgram, isDemo: false };
  for (const snapshot of [matchedCase, wrongPlanCase]) {
    assert.equal(result(snapshot, program).status, 'needs_confirmation');
    assert.ok(result(snapshot, program).checks.every(check => check.reasonCode === 'rules_unverified'));
  }
});

test('verified current synthetic rules can evaluate; intake availability stays separate', () => {
  const program = sourcedProgram();
  program.availability = 'not_accepting';
  const match = result(matchedCase, program);
  assert.equal(match.status, 'meets_known_criteria');
  assert.equal(match.availability, 'not_accepting');
  assert.deepEqual(match.checks[0].sourceIds, ['synthetic-source']);
});

test('real programs need sources on every leaf and a scheduled recheck', () => {
  const program = sourcedProgram();
  program.criteria[0].rule = city;
  assert.equal(result(matchedCase, program).checks[0].reasonCode, 'rule_source_missing');
  const noRecheck = { ...sourcedProgram(), recheckAfter: null };
  assert.equal(result(matchedCase, noRecheck).status, 'needs_confirmation');
});

test('recheck deadline invalidates both demo and verified rules at the boundary', () => {
  for (const program of [demoProgram, sourcedProgram()]) {
    for (const evaluatedAt of ['2026-10-14T19:00:00Z', '2026-10-14T19:00:01Z']) {
      const match = result(matchedCase, program, { evaluatedAt, evaluationDate: '2026-10-14' });
      assert.equal(match.status, 'needs_confirmation');
      assert.equal(match.checks[0].reasonCode, 'rules_recheck_due');
      assert.equal(match.recheckAfter, program.recheckAfter);
    }
  }
});

test('program effective-until is inclusive and expires the following day', () => {
  const program = { ...demoProgram, effectiveUntil: '2026-10-13', recheckAfter: '2026-10-15T19:00:00Z' };
  assert.equal(result(matchedCase, program).status, 'meets_known_criteria');
  assert.equal(result(matchedCase, program, { evaluatedAt: '2026-10-14T00:00:00Z', evaluationDate: '2026-10-14' }).checks[0].reasonCode, 'rules_expired');
});

test('cache boundary is capped at program expiry midnight instead of a later review', () => {
  const program = { ...demoProgram, effectiveUntil: '2026-10-13', recheckAfter: '2026-10-20T19:00:00Z' };
  const match = result(matchedCase, program);
  assert.equal(match.status, 'meets_known_criteria');
  assert.equal(match.recheckAfter, '2026-10-14T00:00:00.000Z');
});

test('cache boundary includes source expiry and future source/program activation', () => {
  const program = sourcedProgram();
  program.recheckAfter = '2026-10-20T19:00:00Z';
  program.sources[0].effectiveUntil = '2026-10-13';
  assert.equal(result(matchedCase, program).recheckAfter, '2026-10-14T00:00:00.000Z');
  program.sources[0].effectiveUntil = null;
  program.sources[0].effectiveFrom = '2026-10-15';
  assert.equal(result(matchedCase, program).recheckAfter, '2026-10-15T00:00:00Z');
  program.effectiveFrom = '2026-10-14';
  assert.equal(result(matchedCase, program).recheckAfter, '2026-10-14T00:00:00Z');
});

test('a null review boundary remains null and an earlier manual review is preserved', () => {
  assert.equal(result(matchedCase, { ...demoProgram, recheckAfter: null, effectiveUntil: '2026-10-13' }).recheckAfter, null);
  assert.equal(result(matchedCase, { ...demoProgram, effectiveUntil: '2026-10-20' }).recheckAfter, demoProgram.recheckAfter);
});

test('mixed unresolved owners do not invent program responsibility', () => {
  const program = withCriterion({ id: 'mixed-review', label: 'Mixed review', rule: {
    kind: 'and', rules: [
      { kind: 'eq', field: 'ownerConsentReported', value: true, sourceIds: [], resolvedBy: 'resident' },
      { kind: 'gte', field: 'ageYears', value: 0, sourceIds: [], resolvedBy: 'professional' },
    ],
  } });
  const check = result(matchedCase, program).checks[0];
  assert.equal(check.status, 'unknown');
  assert.equal(check.resolvedBy, null);
  assert.deepEqual(check.missingFields, ['profile.ownerConsentReported', 'profile.ageYears']);
});

test('future effective dates, future reviews, and expired sources require verification', () => {
  assert.equal(result(matchedCase, { ...demoProgram, effectiveFrom: '2026-10-14' }).checks[0].reasonCode, 'rules_not_yet_effective');
  assert.equal(result(matchedCase, { ...demoProgram, reviewedOn: '2026-10-14' }).checks[0].reasonCode, 'future_review_date');
  const program = sourcedProgram();
  program.sources[0].effectiveUntil = '2026-10-12';
  assert.equal(result(matchedCase, program).checks[0].reasonCode, 'source_not_current');
});

test('invalid case identity, revision, unknown fields, and profile types are rejected', () => {
  for (const snapshot of [
    null, [], { ...matchedCase, schemaVersion: '2' }, { ...matchedCase, caseId: '' },
    { ...matchedCase, revision: 0 }, { ...matchedCase, revision: 1.5 },
    { ...matchedCase, revision: Number.MAX_SAFE_INTEGER + 1 },
    { ...matchedCase, extra: true }, { ...matchedCase, profile: { ...matchedCase.profile, extra: true } },
    ...['42', false, -1, Infinity, NaN].map(ageYears => ({ ...matchedCase, profile: { ...matchedCase.profile, ageYears } })),
    { ...matchedCase, profile: { ...matchedCase.profile, ownerConsentReported: 'false' } },
    { ...matchedCase, profile: { ...matchedCase.profile, householdSize: 0 } },
    { ...matchedCase, profile: { ...matchedCase.profile, city: undefined } },
    { ...matchedCase, unresolvedFields: [false] },
  ]) assert.throws(() => result(snapshot), InputValidationError);
});

test('findings use the exact shared boundary including units and booleans', () => {
  const finding: CaseSnapshot['findings'][number] = {
    id: 'entry-1', room: 'entrance', observation: 'Example observation', reviewState: 'needs_review',
    evidenceIds: ['photo-1'], measurements: [{ type: 'threshold-height', value: 0, unit: 'mm', method: 'manual', confirmed: false }],
  };
  assert.equal(result({ ...matchedCase, findings: [finding] }).status, 'meets_known_criteria');
  for (const invalid of [
    null, { ...finding, extra: true }, { ...finding, room: 'roof' },
    { ...finding, reviewState: 'approved' }, { ...finding, evidenceIds: [''] },
    ...[{ unit: 'cm' }, { value: -1 }, { confirmed: 'false' }, { method: 'scanner' }, { extra: true }].map(patch => ({ ...finding, measurements: [{ ...finding.measurements[0], ...patch }] })),
  ]) assert.throws(() => result({ ...matchedCase, findings: [invalid] }), InputValidationError);
});

test('malformed registry/rules cannot create a vacuous or coerced pass', () => {
  for (const program of [
    { ...demoProgram, criteria: [] }, { ...demoProgram, isDemo: 'false' },
    { ...demoProgram, extra: true }, { ...demoProgram, effectiveFrom: '2026-02-30' },
    { ...demoProgram, criteria: [...demoProgram.criteria, demoProgram.criteria[0]] },
    withCriterion({ id: 'empty', label: 'Empty', rule: { kind: 'and', rules: [] } }),
    withCriterion({ id: 'bad-value', label: 'Bad value', rule: { ...city, value: false } as Rule }),
    withCriterion({ id: 'bad-ref', label: 'Bad reference', rule: { ...city, sourceIds: ['nonexistent'] } as Rule }),
  ]) assert.throws(() => result(matchedCase, program), InputValidationError);
  assert.throws(() => matchPrograms(matchedCase, [demoProgram, demoProgram], demoContext), InputValidationError);
});

test('clock input rejects impossible dates, offsets, and inconsistent UTC dates', () => {
  for (const context of [
    {}, { ...demoContext, extra: true }, { ...demoContext, evaluatedAt: '2026-10-13T12:00:00-07:00' },
    { ...demoContext, evaluatedAt: '2026-02-30T19:00:00Z', evaluationDate: '2026-02-30' },
    { ...demoContext, evaluationDate: '2026-10-14' },
  ]) assert.throws(() => result(matchedCase, demoProgram, context), InputValidationError);
  assert.equal(result(matchedCase, demoProgram, { ...demoContext, evaluatedAt: '2026-10-13T19:00:00.000Z' }).status, 'meets_known_criteria');
});

test('all shared fractional timestamp precisions are accepted and preserved', () => {
  for (const fraction of ['1', '12', '123', '1234', '12345', '123456']) {
    const context = { ...demoContext, evaluatedAt: `2026-10-13T19:00:00.${fraction}Z` };
    const response = matchPrograms(matchedCase, [demoProgram], context);
    assert.equal(response.evaluatedAt, context.evaluatedAt);
    assert.equal(response.matches[0].status, 'meets_known_criteria');
  }
  const program = { ...demoProgram, recheckAfter: '2026-10-13T19:00:00.123456Z' };
  assert.equal(result(matchedCase, program, { ...demoContext, evaluatedAt: '2026-10-13T19:00:00.123455Z' }).status, 'meets_known_criteria');
  assert.equal(result(matchedCase, program, { ...demoContext, evaluatedAt: '2026-10-13T19:00:00.123456Z' }).status, 'needs_confirmation');
});

test('duplicate string-list items and invalid URL/availability types are rejected', () => {
  assert.throws(() => result({ ...matchedCase, unresolvedFields: ['profile.city', 'profile.city'] }), InputValidationError);
  assert.throws(() => result(matchedCase, { ...demoProgram, requiredDocuments: ['Proof', 'Proof'] }), InputValidationError);
  assert.throws(() => result(matchedCase, { ...demoProgram, availability: ['accepting'] }), InputValidationError);
  const program = sourcedProgram();
  for (const url of ['https://example.org/has space', 'https://example.org:invalid', 'https://', 'http://example.org', 'https:example.org', 'https://example.org\\path']) {
    program.sources[0].url = url;
    assert.throws(() => result(matchedCase, program), InputValidationError);
  }
  const duplicates = sourcedProgram();
  duplicates.criteria[0].rule = { ...city, sourceIds: ['synthetic-source', 'synthetic-source'] } as Rule;
  assert.throws(() => result(matchedCase, duplicates), InputValidationError);
});

test('an empty registry returns no matches without inventing a program', () => {
  assert.deepEqual(matchPrograms(matchedCase, [], demoContext).matches, []);
});

test('manual review stays unknown with an explicit reason, source and responsible party', () => {
  for (const resolvedBy of ['resident', 'program', 'professional'] as const) {
    const program = manualProgram({ ...manualReview, resolvedBy });
    for (const snapshot of [matchedCase, wrongPlanCase, missingPlanCase]) {
      const match = result(snapshot, program);
      assert.equal(match.status, 'needs_confirmation');
      assert.equal(match.isDemo, false);
      assert.equal(match.checks[0].id, 'review');
      assert.equal(match.checks[0].status, 'unknown');
      assert.equal(match.checks[0].reasonCode, 'manual_review_required');
      assert.equal(match.checks[0].resolvedBy, resolvedBy);
      assert.deepEqual(match.checks[0].missingFields, []);
      assert.deepEqual(match.checks[0].sourceIds, ['synthetic-source']);
      assert.ok(match.checks[0].explanation.includes(`Manual review (${resolvedBy}): ${manualReview.reason}`));
    }
  }
});

test('profile answers and confirmed observations cannot manufacture a manual decision', () => {
  const snapshot: CaseSnapshot = {
    ...clone(matchedCase),
    profile: { city: 'Demo City', county: 'Demo County', healthPlan: 'Example Plan', tenure: 'owner',
      ageYears: 65, householdSize: 1, annualIncomeUsd: 0, ownerConsentReported: true },
    findings: [{ id: 'confirmed-finding', room: 'entrance', observation: 'Synthetic reviewed observation',
      reviewState: 'confirmed', evidenceIds: ['evidence-1'],
      measurements: [{ type: 'opening', value: 800, unit: 'mm', method: 'manual', confirmed: true }] }],
  };
  assert.equal(result(snapshot, manualProgram()).checks[0].status, 'unknown');
});

test('manual reviews compose with AND and OR without turning uncertainty into rejection', () => {
  const passing = { ...city, sourceIds: ['synthetic-source'] };
  const failing = { ...rule('city', 'Different City'), sourceIds: ['synthetic-source'] };
  for (const [kind, other, expected] of [
    ['and', passing, 'unknown'], ['and', failing, 'fail'],
    ['or', failing, 'unknown'], ['or', passing, 'pass'],
  ] as const) {
    const check = result(matchedCase, manualProgram({ kind, rules: [manualReview, other] })).checks[0];
    assert.equal(check.status, expected);
    assert.equal(check.resolvedBy, expected === 'pass' ? null : 'professional');
    assert.equal(check.explanation.includes(manualReview.reason), expected !== 'pass');
    assert.deepEqual(check.missingFields, []);
    assert.deepEqual(check.sourceIds, ['synthetic-source']);
  }
});

test('a manual exception prevents rejection while a passing alternative clears unnecessary review', () => {
  const program = manualProgram({ ...rule('city', 'Different City'), sourceIds: ['synthetic-source'] });
  program.criteria[0].exception = manualReview;
  const unresolved = result(matchedCase, program).checks[0];
  assert.equal(unresolved.status, 'unknown');
  assert.equal(unresolved.reasonCode, 'criterion_or_exception_unresolved');
  assert.equal(unresolved.resolvedBy, 'professional');
  assert.ok(unresolved.explanation.includes(manualReview.reason));

  program.criteria[0].rule = { ...city, sourceIds: ['synthetic-source'] };
  const passingBase = result(matchedCase, program).checks[0];
  assert.equal(passingBase.status, 'pass');
  assert.ok(!passingBase.explanation.includes(manualReview.reason));
  program.criteria[0].rule = manualReview;
  program.criteria[0].exception = { ...city, sourceIds: ['synthetic-source'] };
  const passingException = result(matchedCase, program).checks[0];
  assert.equal(passingException.reasonCode, 'exception_satisfied');
  assert.equal(passingException.status, 'pass');
  assert.equal(passingException.resolvedBy, null);
  assert.ok(!passingException.explanation.includes(manualReview.reason));
});

test('mixed manual reviewers remain explicit without inventing a single owner', () => {
  const other: Rule = { ...manualReview, reason: 'Review a separate synthetic determination.', resolvedBy: 'program' };
  const check = result(matchedCase, manualProgram({ kind: 'and', rules: [manualReview, other] })).checks[0];
  assert.equal(check.status, 'unknown');
  assert.equal(check.resolvedBy, null);
  assert.ok(check.explanation.includes(`Manual review (professional): ${manualReview.reason}`));
  assert.ok(check.explanation.includes(`Manual review (program): ${other.reason}`));
  assert.deepEqual(check.sourceIds, ['synthetic-source']);
});

test('unverified and stale policy gates keep manual reasons without evaluating alternatives', () => {
  const program = manualProgram({ kind: 'or', rules: [manualReview, { ...city, sourceIds: ['synthetic-source'] }] });
  program.criteria[0].exception = { ...manualReview, reason: 'Review a synthetic exception.', resolvedBy: 'resident' };
  const unverified = { ...clone(program), rulesVerified: false };
  const expired = clone(program);
  expired.sources[0].effectiveUntil = '2026-10-12';
  for (const [record, reasonCode] of [[unverified, 'rules_unverified'], [expired, 'source_not_current']] as const) {
    const match = result(matchedCase, record);
    assert.equal(match.status, 'needs_confirmation');
    const check = match.checks[0];
    assert.equal(check.status, 'unknown');
    assert.equal(check.reasonCode, reasonCode);
    assert.equal(check.resolvedBy, 'program');
    assert.deepEqual(check.missingFields, []);
    assert.deepEqual(check.sourceIds, ['synthetic-source']);
    assert.match(check.explanation, /current program rules need verification/);
    assert.ok(check.explanation.includes(`Manual review (professional): ${manualReview.reason}`));
    assert.match(check.explanation, /Manual review \(resident\): Review a synthetic exception/);
  }
});

test('manual leaves require valid metadata and cannot accept hidden decisions or profile inputs', () => {
  const invalidRules = [
    ...[undefined, null, '', '   ', 1, false].map(reason => ({ ...manualReview, reason })),
    ...[undefined, null, 'agency', 1].map(resolvedBy => ({ ...manualReview, resolvedBy })),
    ...[undefined, null, 'synthetic-source', ['missing'], ['synthetic-source', 'synthetic-source']].map(sourceIds => ({ ...manualReview, sourceIds })),
    ...[{ field: 'city' }, { value: true }, { status: 'pass' }, { id: 'hidden-id' }, { rules: [city] }].map(extra => ({ ...manualReview, ...extra })),
  ];
  for (const rule of invalidRules) {
    const program = { ...sourcedProgram(), criteria: [{ id: 'review', label: 'Review', rule }] };
    assert.throws(() => result(matchedCase, program), InputValidationError);
  }
  const unsourced = manualProgram({ ...manualReview, sourceIds: [] });
  assert.equal(result(matchedCase, unsourced).checks[0].reasonCode, 'rule_source_missing');
});

test('manual review outputs are deterministic and preserve case and registry inputs', () => {
  const snapshot = clone(matchedCase);
  const program = manualProgram();
  const before = clone({ snapshot, program });
  const first = matchPrograms(snapshot, [program], demoContext);
  assert.deepEqual(first, matchPrograms(snapshot, [program], demoContext));
  first.matches[0].checks[0].sourceIds.push('mutated-output');
  assert.deepEqual({ snapshot, program }, before);
});
