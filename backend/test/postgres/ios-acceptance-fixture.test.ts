import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { stat } from 'node:fs/promises';
import test from 'node:test';
import { startIosAcceptanceFixture } from '../../tool/ios-acceptance-fixture.ts';

test('iOS fixture uses a new local restricted PostgreSQL cluster, explicit fake sessions and real owner/deletion routes', async () => {
  const fixture = await startIosAcceptanceFixture();
  const post = async (route: string, body: unknown, token?: string, control = false) => {
    const response = await fetch(`${fixture.baseUri}${route}`, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10_000),
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(control ? { 'x-fictional-fixture-key': fixture.fixtureKey } : {}) }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() as any };
  };
  try {
    assert.equal(new URL(fixture.baseUri).hostname, '127.0.0.1');
    assert.equal((await fixture.status()).cases, 0);
    assert.equal((await post('/__fixture/session', { account: 'alice', password: 'fictional-password-only' })).status, 404);
    assert.equal((await post('/__fixture/session', { account: 'alice', password: 'not-a-real-password' }, undefined, true)).status, 401);
    const alice = await post('/__fixture/session', { account: 'alice', password: 'fictional-password-only' }, undefined, true);
    const bob = await post('/__fixture/session', { account: 'bob', password: 'fictional-password-only' }, undefined, true);
    assert.equal(alice.status, 200); assert.equal(alice.body.userId, fixture.owners.alice);
    assert.equal(alice.body.authentication, 'fictional_provider_only');
    const input = { schemaVersion: '1', caseId: randomUUID(), profile: { city: null, county: null, healthPlan: null, tenure: null,
      ageYears: null, householdSize: null, annualIncomeUsd: 0, ownerConsentReported: false }, unresolvedFields: [], findings: [] };
    assert.equal((await post('/v1/create-case', input, 'forged')).status, 401);
    const created = await post('/v1/create-case', input, alice.body.accessToken);
    assert.equal(created.status, 200); assert.deepEqual(created.body, { ...input, revision: 1 });
    const read = { schemaVersion: '1', caseId: input.caseId };
    assert.equal((await post('/v1/read-case', read, bob.body.accessToken)).status, 404);
    const intake = await post('/v2/read-program-intake', { ...read, schemaVersion: '2', expectedCaseRevision: 1, programId: 'rtp-home-repair' }, alice.body.accessToken);
    assert.equal(intake.status, 200); assert.equal(intake.body.definition.programId, 'rtp-home-repair');
    assert.equal((await post('/v1/delete-case', { ...read, expectedCaseRevision: 1, expectedCatalogRevision: 0, confirmation: 'DELETE_CASE' }, bob.body.accessToken)).status, 404);
    assert.equal((await post('/v1/delete-case', { ...read, expectedCaseRevision: 1, expectedCatalogRevision: 0, confirmation: 'DELETE_CASE' }, alice.body.accessToken)).status, 200);
    assert.equal((await post('/v1/read-case', read, alice.body.accessToken)).status, 404);
    const status = await post('/__fixture/status', {}, undefined, true);
    assert.equal(status.status, 200); assert.equal(status.body.cases, 0); assert.equal(status.body.evidence, 0);
    assert.equal(status.body.derivedRows, 0); assert.equal(status.body.closedAccounts, 0);
    assert.equal(JSON.stringify(status.body).includes(alice.body.accessToken), false);
    assert.equal(JSON.stringify(status.body).includes(fixture.owners.alice), false);
  } finally { await fixture.close(); }
  await assert.rejects(stat(fixture.directory), { code: 'ENOENT' });
  await fixture.close();
});
