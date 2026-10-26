import assert from 'node:assert/strict';
import test from 'node:test';
import { matchPrograms } from '../src/matcher.ts';
import { planPacketWithForm } from '../src/forms/prepare-form-packet.ts';
import { createFederalPreparationPrograms } from '../src/programs/federal-preparation.ts';
import { benefitsBundleNameFromEnvironment, BenefitsBundleConfigurationError,
  loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import type { CaseSnapshot, Profile } from '../src/types.ts';

const context = { evaluatedAt: '2026-10-26T12:00:00Z', evaluationDate: '2026-10-26' };
const programIds = ['usda-section-504', 'va-hisa'];

function fictionalCase(profile: Partial<Profile> = {}): CaseSnapshot {
  return { schemaVersion: '1', caseId: 'fictional-federal-preparation', revision: 7,
    profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
      householdSize: null, annualIncomeUsd: null, ownerConsentReported: null, ...profile },
    unresolvedFields: [], findings: [] };
}

test('national checklist opt-in does not change disabled defaults or require any California PDF reads', async () => {
  assert.equal(benefitsBundleNameFromEnvironment({}), 'disabled');
  assert.equal(benefitsBundleNameFromEnvironment({ SAFEATHOME_BENEFITS_BUNDLE: 'nationwide-preparation-v1' }),
    'nationwide-preparation-v1');
  for (const value of ['nationwide-preparation-v1 ', 'NATIONWIDE-PREPARATION-V1', 'nationwide-preparation-v2']) {
    assert.throws(() => benefitsBundleNameFromEnvironment({ SAFEATHOME_BENEFITS_BUNDLE: value }),
      BenefitsBundleConfigurationError);
  }
  let reads = 0;
  const bundle = await loadRuntimeBenefitsBundle('nationwide-preparation-v1', {
    readTemplateBytes: async () => { reads++; throw new Error('Unavailable California asset'); },
  });
  assert.equal(bundle.enabled, true);
  assert.equal(bundle.name, 'nationwide-preparation-v1');
  assert.equal(Object.isFrozen(bundle), true);
  assert.deepEqual((await bundle.loadRegistry()).map(program => program.programId), programIds);
  for (const id of [...programIds, 'scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair', '../form.pdf']) {
    assert.equal(await bundle.loadFormTemplate(id), null);
  }
  assert.equal(reads, 0);
  assert.deepEqual(await (await loadRuntimeBenefitsBundle('disabled')).loadRegistry(), []);
});

test('federal catalog and bundle results are detached between callers', async () => {
  const expected = createFederalPreparationPrograms();
  const bundle = await loadRuntimeBenefitsBundle('nationwide-preparation-v1');
  const changed = await bundle.loadRegistry();
  changed[0].criteria.length = 0;
  changed[1].sources[0].url = 'https://untrusted.invalid';
  changed[1].requiredDocuments.length = 0;
  assert.deepEqual(await bundle.loadRegistry(), expected);
  expected[0].programName = 'Changed';
  assert.notEqual(createFederalPreparationPrograms()[0].programName, 'Changed');
});

test('federal route research never becomes verified eligibility, open intake or accepted forms', () => {
  for (const program of createFederalPreparationPrograms()) {
    assert.equal(program.isDemo, false);
    assert.equal(program.rulesVerified, false);
    assert.equal(program.availability, 'unverified');
    assert.equal(program.reviewedOn, '2026-10-26');
    assert.equal(program.recheckAfter, null);
    assert.equal(program.effectiveFrom, null);
    assert.equal(program.effectiveUntil, null);
    assert.match(program.programName, /preparation checklist/);
    assert.ok(program.criteria.every(criterion => criterion.rule.kind === 'manual_review'
      && criterion.rule.sourceIds.length > 0));
    assert.ok(program.sources.every(source => source.reviewedOn === '2026-10-26'
      && source.effectiveFrom === null && source.effectiveUntil === null));
    assert.ok(program.sources.every(source => ['.gov', '.usda.gov', '.va.gov'].some(suffix =>
      new URL(source.url).hostname.endsWith(suffix))));
  }
});

test('missing, conflicting, extreme and California-specific profile facts all keep federal checks unknown', () => {
  const profiles: Partial<Profile>[] = [
    {},
    { ageYears: 61 }, { ageYears: 62 }, { ageYears: 63 },
    { annualIncomeUsd: 0 }, { annualIncomeUsd: 1_000_000 },
    { householdSize: 1 }, { householdSize: 10 },
    { tenure: 'owner', ownerConsentReported: true },
    { tenure: 'renter', ownerConsentReported: false },
    { healthPlan: 'SCFHP', county: 'Santa Clara', city: 'San Jose' },
    { healthPlan: 'HPSM', county: 'San Mateo' },
    { healthPlan: 'Other', county: 'Washington', city: 'Portland' },
  ];
  for (const profile of profiles) {
    const snapshot = fictionalCase(profile);
    snapshot.unresolvedFields = ['profile.annualIncomeUsd', 'profile.county'];
    snapshot.findings = [{ id: 'fictional-observation', room: 'entrance',
      observation: 'Resident reports a difficult entrance.', reviewState: 'confirmed',
      measurements: [], evidenceIds: ['fictional-photo'] }];
    const first = matchPrograms(snapshot, createFederalPreparationPrograms(), context);
    const repeat = matchPrograms(snapshot, createFederalPreparationPrograms(), context);
    assert.deepEqual(first, repeat);
    assert.equal(first.caseRevision, 7);
    for (const match of first.matches) {
      assert.equal(match.status, 'needs_confirmation');
      assert.equal(match.availability, 'unverified');
      assert.ok(match.checks.every(check => check.status === 'unknown'
        && check.reasonCode === 'rules_unverified' && check.sourceIds.length > 0));
    }
  }
});

test('USDA conflicting income sources, grant-only age and optional intake stay explicit', () => {
  const program = createFederalPreparationPrograms()[0];
  const reason = (id: string) => {
    const rule = program.criteria.find(item => item.id === id)!.rule;
    assert.equal(rule.kind, 'manual_review');
    return rule.kind === 'manual_review' ? rule.reason : '';
  };
  assert.match(reason('income-policy-conflict'), /low- and very-low-income.*3550\.103\(c\).*very-low-income/);
  assert.match(reason('income-policy-conflict'), /applies neither conflicting threshold/);
  assert.match(reason('grant-age-alternative'), /younger does not by itself reject a possible loan/);
  assert.match(reason('local-intake-currentness'), /prequalification is not a prerequisite/);
  assert.ok(program.sources.some(item => /03-24.*November 30, 2026/.test(item.title)));
});

test('VA preserves beneficiary alternatives, professional determinations, remaining balance and form discrepancy', () => {
  const program = createFederalPreparationPrograms()[1];
  const detail = (id: string) => JSON.stringify(program.criteria.find(item => item.id === id));
  assert.match(detail('beneficiary-alternatives'), /medical-discharge alternative/);
  assert.match(detail('clinical-prescription'), /professional/);
  assert.match(detail('benefit-category-prior-use'), /missing history means zero/);
  assert.match(detail('form-intake-currentness'), /February 2025.*MAR 2025/);
  assert.match(detail('estimate-and-evidence'), /does not require three bids/);
  assert.match(program.intake!, /paperwork-feedback email is not an application destination/);
  assert.ok(program.sources.some(item => /June 30, 2027/.test(item.title)));
});

test('federal preparation retains draft provenance, unmapped forms, empty attachments and unresolved review', () => {
  const snapshot = fictionalCase({ ownerConsentReported: true });
  const result = matchPrograms(snapshot, createFederalPreparationPrograms(), context);
  for (const match of result.matches) {
    const packet = planPacketWithForm(snapshot, match,
      { packetId: `fictional-${match.programId}-draft`, generatedAt: context.evaluatedAt }, null);
    assert.equal(packet.status, 'draft');
    assert.equal(packet.caseRevision, snapshot.revision);
    assert.equal(packet.ruleVersion, match.ruleVersion);
    assert.equal(packet.formVersion, null);
    assert.equal(packet.mappingVersion, null);
    assert.equal(packet.storageReference, null);
    assert.equal(packet.recheckAfter, null);
    assert.deepEqual(packet.attachments, []);
    assert.ok(packet.missingItems.some(item => item.id === 'official-form'));
    assert.ok(packet.missingItems.some(item => item.id === 'field-mapping'));
    assert.ok(packet.missingItems.some(item => item.id === 'program-availability'));
    assert.ok(packet.missingItems.some(item => item.id.startsWith('check:')));
  }
});
