import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { benefitsBundleNameFromEnvironment, BenefitsBundleConfigurationError,
  loadRuntimeBenefitsBundle, type BenefitsBundleName } from '../src/programs/runtime-bundle.ts';
import { MAX_TEMPLATE_BYTES, verifyTemplateBytes } from '../src/forms/template-artifact.ts';
import { matchPrograms } from '../src/matcher.ts';
import { planPacketWithForm } from '../src/forms/prepare-form-packet.ts';
import type { CaseSnapshot } from '../src/types.ts';

const pin = 'ebd403673949e7fa01005789700fa6baddd77d351de90a44f7fee1eb81516cd7';
const artifact = () => readFile(new URL('../assets/forms/scfhp-41567.pdf', import.meta.url));

test('default and explicit disabled bundle perform no artifact I/O and return empty detached results', async () => {
  assert.equal(benefitsBundleNameFromEnvironment({}), 'disabled');
  assert.equal(benefitsBundleNameFromEnvironment({ SAFEATHOME_BENEFITS_BUNDLE: 'disabled' }), 'disabled');
  let calls = 0;
  const bundle = await loadRuntimeBenefitsBundle('disabled', { readTemplateBytes: async () => { calls++; throw new Error('Must not read'); } });
  assert.equal(bundle.name, 'disabled'); assert.equal(bundle.enabled, false); assert.equal(Object.isFrozen(bundle), true);
  assert.deepEqual(await bundle.loadRegistry(), []);
  assert.notEqual(await bundle.loadRegistry(), await bundle.loadRegistry());
  assert.equal(await bundle.loadFormTemplate('scfhp-eaa'), null);
  assert.equal(calls, 0);
});

test('bundle environment is an exact enum, never a URL, path or arbitrary program selector', async () => {
  assert.equal(benefitsBundleNameFromEnvironment({ SAFEATHOME_BENEFITS_BUNDLE: 'scfhp-eaa-draft-v1' }), 'scfhp-eaa-draft-v1');
  const invalid = ['', 'true', 'SCFHP-EAA-DRAFT-V1', 'scfhp-eaa-draft-v1 ', 'disabled\n',
    '/tmp/41567.pdf', 'https://example.invalid/form.pdf', 'scfhp-eaa-draft-v2'];
  for (const value of invalid) {
    assert.throws(() => benefitsBundleNameFromEnvironment({ SAFEATHOME_BENEFITS_BUNDLE: value }), BenefitsBundleConfigurationError);
    let calls = 0;
    await assert.rejects(loadRuntimeBenefitsBundle(value as BenefitsBundleName,
      { readTemplateBytes: async () => { calls++; return new Uint8Array(); } }), BenefitsBundleConfigurationError);
    assert.equal(calls, 0);
  }
});

test('fixed production asset is the exact public 223295-byte reviewed PDF', async () => {
  const bytes = await artifact();
  assert.equal(bytes.byteLength, 223295);
  assert.equal(verifyTemplateBytes(bytes, pin), pin);
  const bundle = await loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1');
  assert.equal(bundle.name, 'scfhp-eaa-draft-v1'); assert.equal(bundle.enabled, true);
  const form = await bundle.loadFormTemplate('scfhp-eaa');
  assert.ok(form);
  assert.equal(form.template.templateSha256, pin);
  assert.equal(form.template.formVersion, `sha256:${pin}`);
  assert.equal(form.template.publisherRevision, null);
  assert.equal(form.template.pageCount, 5);
  assert.deepEqual(form.bytes, Uint8Array.from(bytes));
  for (const id of ['another-program', '../assets/forms/scfhp-41567.pdf', 'https://example.invalid/', 'scfhp-eaa ']) {
    assert.equal(await bundle.loadFormTemplate(id), null);
  }
});

test('corrupt, non-PDF, truncated, missing and oversized artifacts fail with a sanitized configuration error', async () => {
  const original = await artifact();
  const changed = Uint8Array.from(original); changed[changed.length - 1] ^= 1;
  const nonPdf = Uint8Array.from(original); nonPdf[0] = 0;
  for (const bytes of [changed, nonPdf, original.subarray(0, 100), new Uint8Array(7), new Uint8Array(MAX_TEMPLATE_BYTES + 1)]) {
    await assert.rejects(loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1', { readTemplateBytes: async () => bytes }),
      BenefitsBundleConfigurationError);
  }
  await assert.rejects(loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1', { readTemplateBytes: async () => {
    throw new Error('ENOENT /private/operator/path SECRET_PROVIDER_DETAIL');
  } }), error => {
    assert.ok(error instanceof BenefitsBundleConfigurationError);
    assert.equal('cause' in error, false);
    assert.equal(`${String(error.stack)} ${JSON.stringify(error)}`.includes('SECRET_PROVIDER_DETAIL'), false);
    assert.equal(String(error.stack).includes('/private/operator/path'), false);
    return true;
  });
});

test('startup reads once and returned nested program, template and byte copies cannot alter later requests', async () => {
  let reads = 0;
  const input = Uint8Array.from(await artifact());
  const bundle = await loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1', {
    readTemplateBytes: async () => { reads++; return input; },
  });
  const baselinePrograms = await bundle.loadRegistry(), baselineForm = await bundle.loadFormTemplate('scfhp-eaa');
  assert.ok(baselineForm);
  const alteredPrograms = await bundle.loadRegistry(), alteredForm = await bundle.loadFormTemplate('scfhp-eaa');
  assert.ok(alteredForm);
  input.fill(0);
  alteredPrograms[0].programName = 'Changed by caller';
  alteredPrograms[0].sources[0].url = 'https://untrusted.invalid';
  alteredPrograms[0].criteria.length = 0;
  alteredForm.bytes.fill(0);
  assert.equal(Reflect.set(alteredForm.template, 'mappingVersion', 'caller-override'), true);
  assert.equal(Reflect.set(alteredForm.template.fields[0].widgets[0].rect, 0, 9999), true);
  assert.deepEqual(await bundle.loadRegistry(), baselinePrograms);
  assert.deepEqual(await bundle.loadFormTemplate('scfhp-eaa'), baselineForm);
  assert.equal(await bundle.loadFormTemplate('unknown'), null);
  assert.equal(reads, 1);
});

test('enabling the verified artifact leaves policy, availability and clinical review unresolved and outputs draft-only', async () => {
  const bundle = await loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1');
  const registry = await bundle.loadRegistry();
  assert.equal(registry.length, 1);
  assert.equal(registry[0].isDemo, false);
  assert.equal(registry[0].rulesVerified, false);
  assert.equal(registry[0].availability, 'unverified');
  assert.equal(registry[0].recheckAfter, null);
  const snapshot: CaseSnapshot = { schemaVersion: '1', caseId: 'fictional-bundle-case', revision: 1,
    profile: { city: 'San Jose', county: 'Santa Clara', healthPlan: 'SCFHP', tenure: 'owner',
      ageYears: 70, householdSize: 1, annualIncomeUsd: 0, ownerConsentReported: true },
    unresolvedFields: [], findings: [] };
  const generatedAt = '2026-10-18T12:00:00Z';
  const match = matchPrograms(snapshot, registry, { evaluatedAt: generatedAt, evaluationDate: '2026-10-18' }).matches[0];
  assert.equal(match.status, 'needs_confirmation');
  assert.equal(match.checks.every(check => check.status === 'unknown'), true);
  const form = await bundle.loadFormTemplate(match.programId); assert.ok(form);
  const packet = planPacketWithForm(snapshot, match, { packetId: 'fictional-bundle-packet', generatedAt },
    { template: form.template, templateSha256: verifyTemplateBytes(form.bytes, form.template.templateSha256) });
  assert.equal(packet.status, 'draft'); assert.equal(packet.isDemo, false);
  assert.equal(packet.recheckAfter, null); assert.equal(packet.storageReference, null);
  assert.deepEqual(packet.attachments, []);
  assert.equal(packet.formVersion, `sha256:${pin}`);
  assert.ok(packet.missingItems.some(item => item.id === 'form-currentness'));
  assert.ok(packet.missingItems.some(item => item.id === 'program-availability'));
  assert.ok(packet.missingItems.some(item => item.id === 'check:clinical-need'));
});

test('combined team-beta + nationwide bundle is explicit and serves all five routes with their own versions', async () => {
  assert.equal(benefitsBundleNameFromEnvironment({ SAFEATHOME_BENEFITS_BUNDLE: 'team-beta-with-nationwide-v1' }),
    'team-beta-with-nationwide-v1');
  for (const value of ['team-beta-with-nationwide-v1 ', 'TEAM-BETA-WITH-NATIONWIDE-V1', 'team-beta-with-nationwide-v2',
    'team-beta-drafts-v2,nationwide-preparation-v1']) {
    assert.throws(() => benefitsBundleNameFromEnvironment({ SAFEATHOME_BENEFITS_BUNDLE: value }), BenefitsBundleConfigurationError);
  }
  const teamBeta = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const nationwide = await loadRuntimeBenefitsBundle('nationwide-preparation-v1');
  const combined = await loadRuntimeBenefitsBundle('team-beta-with-nationwide-v1');
  assert.equal(combined.name, 'team-beta-with-nationwide-v1'); assert.equal(combined.enabled, true);
  assert.equal(Object.isFrozen(combined), true);
  const teamPrograms = await teamBeta.loadRegistry(), federalPrograms = await nationwide.loadRegistry();
  assert.deepEqual(teamPrograms.map(p => p.programId), ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair']);
  assert.deepEqual(federalPrograms.map(p => p.programId), ['usda-section-504', 'va-hisa']);
  const registry = await combined.loadRegistry();
  assert.deepEqual(registry, [...teamPrograms, ...federalPrograms]);
  assert.deepEqual(registry.map(p => [p.programId, p.ruleVersion]), [
    ['scfhp-eaa', 'referral-draft-2026-10-26-v3'],
    ['hpsm-eaa', 'hpsm-referral-preparation-2026-10-26-v1'],
    ['rtp-home-repair', 'rtp-preparation-2026-10-26-v1'],
    ['usda-section-504', 'usda-504-preparation-2026-10-26-v1'],
    ['va-hisa', 'va-hisa-preparation-2026-10-26-v1'],
  ]);
  for (const program of registry) {
    assert.equal(program.rulesVerified, false); assert.equal(program.availability, 'unverified');
  }
  for (const id of ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair']) {
    assert.deepEqual(await combined.loadFormTemplate(id), await teamBeta.loadFormTemplate(id));
  }
  for (const id of ['usda-section-504', 'va-hisa', 'unknown']) assert.equal(await combined.loadFormTemplate(id), null);
  const changed = await combined.loadRegistry(); changed[3].criteria.length = 0;
  assert.deepEqual(await combined.loadRegistry(), registry);
});
