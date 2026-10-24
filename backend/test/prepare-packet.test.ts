import assert from 'node:assert/strict';
import test from 'node:test';
import { demoContext, demoProgram } from '../fixtures/demo-program.ts';
import { matchPrograms } from '../src/matcher.ts';
import { instantMicros, isPacketCurrent, planDraftPacket } from '../src/packets.ts';
import type { CaseSnapshot, DraftPacket, Match, ProgramDefinition } from '../src/types.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handlePreparePacket, type CreatePacketInput, type PacketErrorCode, type PreparePacketDependencies, type PreparePacketRequest, type PreparePacketResult } from '../src/api/prepare-packet.ts';

function makeCase(caseId = 'packet-case-alice'): CaseSnapshot {
  return { schemaVersion: '1', caseId, revision: 1,
    profile: { city: 'Demo City', county: null, healthPlan: 'Example Plan', tenure: null,
      ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null },
    unresolvedFields: [], findings: [] };
}

const request: PreparePacketRequest = {
  schemaVersion: '1', caseId: 'packet-case-alice', expectedCaseRevision: 1,
  programId: demoProgram.programId, generationKey: 'draft-key-001',
};

function setup(snapshot = makeCase(), program = structuredClone(demoProgram)) {
  const repository = new MemoryCaseRepository([
    { userId: 'alice', snapshot }, { userId: 'bob', snapshot: makeCase('packet-case-bob') },
  ]);
  const calls: string[] = [];
  const attempts: CreatePacketInput[] = [];
  let now = demoContext.evaluatedAt;
  let sequence = 0;
  const deps: PreparePacketDependencies = {
    authenticate: async token => {
      calls.push('authenticate');
      return token === 'alice-token' ? { userId: 'alice' } : token === 'bob-token' ? { userId: 'bob' } : null;
    },
    cases: {
      loadForUser: async (userId, caseId) => { calls.push('load'); return repository.loadForUser(userId, caseId); },
      createPacketIfCurrent: async input => {
        calls.push('save'); attempts.push(structuredClone(input));
        return repository.createPacketIfCurrent(input);
      },
    },
    loadRegistry: async () => { calls.push('registry'); return [structuredClone(program)]; },
    now: () => new Date(now), newPacketId: () => `packet-test-${++sequence}`, allowDemoPrograms: true,
  };
  const send = (body: unknown = { ...request, caseId: snapshot.caseId, programId: program.programId }, bearerToken: string | null = 'alice-token') => handlePreparePacket({ body, bearerToken }, deps);
  return { deps, repository, calls, attempts, send, setNow: (value: string) => { now = value; } };
}

function error(result: PreparePacketResult, status: number, code: PacketErrorCode) {
  assert.equal(result.status, status);
  assert.ok('error' in result.body);
  assert.equal(result.body.error.code, code);
  assert.equal(result.headers?.['Cache-Control'], 'no-store');
}

function packet(result: PreparePacketResult): DraftPacket {
  assert.equal(result.status, 200);
  assert.ok('packetId' in result.body);
  return result.body;
}

function selectedMatch(snapshot = makeCase(), program = demoProgram): Match {
  return matchPrograms(snapshot, [program], demoContext).matches[0];
}

test('planner is deterministic and emits only a draft checklist with unverified forms and no attachments', () => {
  const snapshot = makeCase();
  const match = selectedMatch(snapshot);
  const context = { packetId: 'fixed-packet', generatedAt: demoContext.evaluatedAt };
  const draft = planDraftPacket(snapshot, match, context);
  assert.deepEqual(draft, planDraftPacket(snapshot, match, context));
  assert.deepEqual(Object.keys(draft).sort(), ['schemaVersion', 'packetId', 'caseId', 'caseRevision', 'programId', 'ruleVersion',
    'formVersion', 'mappingVersion', 'status', 'isDemo', 'generatedAt', 'recheckAfter', 'storageReference', 'attachments', 'missingItems'].sort());
  assert.equal(draft.status, 'draft');
  assert.equal(draft.formVersion, null); assert.equal(draft.mappingVersion, null); assert.equal(draft.storageReference, null);
  assert.deepEqual(draft.attachments, []);
  assert.deepEqual(draft.missingItems.map(item => item.id), ['official-form', 'field-mapping', 'intake-route', 'program-availability']);
  assert.ok(draft.missingItems.every(item => item.resolvedBy === 'program'));
  assert.equal(draft.isDemo, true);
});

test('planner preserves failed/unknown checks and explicitly coordinates unresolved responsibility', () => {
  const snapshot = makeCase();
  snapshot.profile.healthPlan = null;
  snapshot.profile.city = 'Other City';
  const match = selectedMatch(snapshot);
  match.checks.push({ id: 'mixed', status: 'unknown', reasonCode: 'SYNTHETIC_MIXED', explanation: 'Either documented alternative needs review.',
    missingFields: [], resolvedBy: null, sourceIds: [] });
  const draft = planDraftPacket(snapshot, match, { packetId: 'packet', generatedAt: demoContext.evaluatedAt });
  assert.match(draft.missingItems.find(item => item.id === 'check:city')!.description, /^Ask the program to identify who can resolve/);
  assert.match(draft.missingItems.find(item => item.id === 'check:plan')!.description, /^Confirm the unresolved requirement/);
  const mixed = draft.missingItems.find(item => item.id === 'check:mixed')!;
  assert.equal(mixed.resolvedBy, 'program');
  assert.match(mixed.description, /^Ask the program to identify who can resolve/);
});

test('document strings become coordination tasks without inventing their provider or supplied state', () => {
  const match = selectedMatch();
  match.requiredDocuments = ['Synthetic household statement', 'Synthetic professional statement'];
  match.intake = 'A route still requiring verification';
  const draft = planDraftPacket(makeCase(), match, { packetId: 'packet', generatedAt: demoContext.evaluatedAt });
  const documents = draft.missingItems.filter(item => item.id.startsWith('required-document:'));
  assert.equal(documents.length, 2);
  assert.ok(documents.every(item => item.resolvedBy === 'program' && item.description.includes('who should supply')));
  assert.ok(draft.missingItems.some(item => item.id === 'intake-route'));
  assert.deepEqual(draft.attachments, []);
});

test('finding review, uncertain measurements, unresolved answers and evidence stay explicit', () => {
  const snapshot = makeCase();
  snapshot.unresolvedFields = ['profile.county'];
  snapshot.findings = [
    { id: 'unreviewed', room: 'bathroom', observation: 'Synthetic observation', reviewState: 'needs_review', evidenceIds: ['photo-unverified'],
      measurements: [{ type: 'width', value: 0, unit: 'mm', method: 'estimated', confirmed: false }] },
    { id: 'dismissed', room: 'entrance', observation: 'Dismissed observation', reviewState: 'dismissed', evidenceIds: ['dismissed-photo'], measurements: [] },
    { id: 'confirmed', room: 'entrance', observation: 'Reviewed observation', reviewState: 'confirmed', evidenceIds: [],
      measurements: [{ type: 'width', value: 100, unit: 'mm', method: 'manual', confirmed: true }] },
  ];
  const draft = planDraftPacket(snapshot, selectedMatch(snapshot), { packetId: 'packet', generatedAt: demoContext.evaluatedAt });
  assert.ok(draft.missingItems.some(item => item.id === 'answer:profile.county'));
  assert.ok(draft.missingItems.some(item => item.id === 'finding:unreviewed'));
  assert.ok(draft.missingItems.some(item => item.id === 'measurement:unreviewed:0'));
  assert.ok(draft.missingItems.some(item => item.id === 'evidence:unreviewed'));
  assert.ok(!draft.missingItems.some(item => /dismissed|confirmed/.test(item.id) && !item.id.includes('unreviewed')));
  assert.deepEqual(draft.attachments, []);
  assert.doesNotMatch(JSON.stringify(draft), /medical necessity|diagnosed|signed|approved|submitted/);
});

test('authentication precedes all case lookups and malformed requests', async () => {
  for (const token of [null, '', 'bad token', 'invalid-token']) {
    const state = setup();
    const result = await state.send({ owner: 'alice' }, token);
    error(result, 401, 'UNAUTHENTICATED');
    assert.equal(result.headers?.['WWW-Authenticate'], 'Bearer');
    assert.ok(!state.calls.includes('load'));
  }
});

test('strict request validation rejects overrides, invalid revisions, keys and nonscalar IDs', async () => {
  const invalidBodies: unknown[] = [null, [], {}, { ...request, schemaVersion: '2' },
    ...['', ' ', 'a'.repeat(201), '\ud800', '\udfff'].flatMap(value => [{ ...request, caseId: value }, { ...request, programId: value }]),
    ...[0, -1, 1.1, '1', Number.MAX_SAFE_INTEGER + 1].map(expectedCaseRevision => ({ ...request, expectedCaseRevision })),
    ...['short', 'x'.repeat(129), 'spaces forbidden', 'unicode-🙂', 'slashes/invalid', 'valid-key\n', 'valid-key\r\n', 'valid-key\0'].map(generationKey => ({ ...request, generationKey })),
    ...['owner', 'userId', 'profile', 'rules', 'generatedAt', 'packetId', 'storageReference'].map(field => ({ ...request, [field]: 'injected' })),
  ];
  for (const body of invalidBodies) {
    const state = setup();
    error(await state.send(body), 400, 'INVALID_REQUEST');
    assert.deepEqual(state.calls, ['authenticate']);
  }
});

test('request ID boundaries count Unicode scalar values and generation-key endpoints are inclusive', async () => {
  const snapshot = makeCase('🙂'.repeat(200));
  const program = { ...structuredClone(demoProgram), programId: '🚪'.repeat(200) };
  const state = setup(snapshot, program);
  for (const generationKey of ['a'.repeat(8), 'Z_-9'.repeat(32)]) {
    packet(await state.send({ ...request, caseId: snapshot.caseId, programId: program.programId, generationKey }));
  }
  error(await state.send({ ...request, caseId: '🙂'.repeat(201) }), 400, 'INVALID_REQUEST');
});

test('cross-user case IDs are unavailable and the same key never shares another owner’s packet', async () => {
  const state = setup();
  const alice = packet(await state.send());
  const denied = await state.send(request, 'bob-token');
  const missing = await state.send({ ...request, caseId: 'missing' }, 'bob-token');
  error(denied, 404, 'CASE_NOT_FOUND'); assert.deepEqual(denied, missing);
  const bob = packet(await state.send({ ...request, caseId: 'packet-case-bob' }, 'bob-token'));
  assert.notEqual(alice.packetId, bob.packetId);
  assert.equal(bob.caseId, 'packet-case-bob');
});

test('a valid retry returns the exact saved packet, including ID and original timestamp', async () => {
  const state = setup();
  const first = packet(await state.send());
  state.setNow('2026-10-13T19:01:00Z');
  assert.deepEqual(packet(await state.send()), first);
  assert.equal(state.calls.filter(call => call === 'registry').length, 2);
});

test('concurrent identical requests atomically return the same saved packet', async () => {
  const state = setup();
  const results = await Promise.all([state.send(), state.send(), state.send()]);
  assert.deepEqual(packet(results[1]), packet(results[0]));
  assert.deepEqual(packet(results[2]), packet(results[0]));
});

test('mutable authentication and request objects cannot retarget preparation across awaits', async () => {
  const state = setup();
  const identity = { userId: 'alice' };
  const body = { ...request };
  state.deps.authenticate = async () => identity;
  state.deps.loadRegistry = async () => {
    identity.userId = 'bob';
    body.caseId = 'packet-case-bob'; body.programId = 'changed-program'; body.generationKey = 'changed-key';
    return [structuredClone(demoProgram)];
  };
  const result = packet(await state.send(body));
  assert.equal(result.caseId, request.caseId);
  assert.equal(result.programId, request.programId);
  assert.equal(state.attempts[0].userId, 'alice');
  assert.equal(state.attempts[0].generationKey, request.generationKey);
});

test('different selected programs cannot reuse a generation key', async () => {
  const state = setup();
  packet(await state.send());
  state.deps.loadRegistry = async () => [structuredClone(demoProgram), { ...structuredClone(demoProgram), programId: 'other-program' }];
  error(await state.send({ ...request, programId: 'other-program' }), 409, 'PACKET_GENERATION_CONFLICT');
});

test('rule versions, rule content, documents and intake metadata invalidate the same key', async () => {
  const edits: ((program: ProgramDefinition) => void)[] = [
    program => { program.ruleVersion = 'changed-v2'; },
    program => { program.criteria[0].rule = { kind: 'eq', field: 'city', value: 'Different city', sourceIds: [], resolvedBy: 'resident' }; },
    program => { program.requiredDocuments = ['Synthetic additional document']; },
    program => { program.intake = 'New unverified intake'; },
    program => { program.reviewedOn = '2026-10-12'; },
  ];
  for (const edit of edits) {
    const state = setup(); packet(await state.send());
    const changed = structuredClone(demoProgram); edit(changed);
    state.deps.loadRegistry = async () => [changed];
    error(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
    packet(await state.send({ ...request, generationKey: 'new-reviewed-key' }));
  }
});

test('full case content is bound even if a faulty adapter forgets to increment its revision', async () => {
  const state = setup(); packet(await state.send());
  const changed = makeCase(); changed.profile.county = 'A field not used by this matcher';
  state.deps.cases.loadForUser = async () => changed;
  error(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
});

test('expected revision mismatches fail before loading a registry or saving', async () => {
  const state = setup();
  error(await state.send({ ...request, expectedCaseRevision: 2 }), 409, 'CASE_REVISION_MISMATCH');
  assert.ok(!state.calls.includes('registry')); assert.equal(state.attempts.length, 0);
});

test('atomic revision changes, deletion and access loss during evaluation cannot return a draft', async () => {
  for (const status of ['conflict', 'not_found'] as const) {
    const state = setup();
    state.deps.cases.createPacketIfCurrent = async () => ({ status });
    error(await state.send(), status === 'conflict' ? 409 : 404, status === 'conflict' ? 'CASE_REVISION_MISMATCH' : 'CASE_NOT_FOUND');
  }
});

test('draft capacity exhaustion returns the existing safe storage-limit contract', async () => {
  const state = setup();
  state.deps.cases.createPacketIfCurrent = async () => ({ status: 'quota_exceeded' });
  error(await state.send(), 507, 'STORAGE_LIMIT_REACHED');
});

test('unknown selected programs return 404 without saving', async () => {
  const state = setup();
  error(await state.send({ ...request, programId: 'missing-program' }), 404, 'PROGRAM_NOT_FOUND');
  assert.equal(state.attempts.length, 0);
});

test('server-selected rules and clock drive the packet while missing facts remain unresolved', async () => {
  const snapshot = makeCase(); snapshot.profile.healthPlan = null;
  const program = { ...structuredClone(demoProgram), ruleVersion: 'server-version' };
  const state = setup(snapshot, program); state.setNow('2026-10-13T22:23:24.123Z');
  const draft = packet(await state.send());
  assert.equal(draft.generatedAt, '2026-10-13T22:23:24.123Z');
  assert.equal(draft.ruleVersion, 'server-version');
  assert.ok(draft.missingItems.some(item => item.id === 'check:plan'));
  assert.equal(draft.status, 'draft');
});

test('demo programs require explicit opt-in', async () => {
  for (const allowDemoPrograms of [undefined, false]) {
    const state = setup(); state.deps.allowDemoPrograms = allowDemoPrograms;
    error(await state.send(), 500, 'INTERNAL_ERROR'); assert.equal(state.attempts.length, 0);
  }
});

test('unknown freshness permits a new clearly unresolved draft but never a cached retry', async () => {
  const program = { ...structuredClone(demoProgram), recheckAfter: null };
  const state = setup(makeCase(), program);
  const first = packet(await state.send()); assert.equal(first.recheckAfter, null);
  assert.equal(isPacketCurrent(first, demoContext.evaluatedAt), false);
  error(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
});

test('expired saved drafts are not served, even when the registry extends its deadline', async () => {
  const state = setup(); packet(await state.send());
  state.setNow(demoProgram.recheckAfter!);
  error(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
  state.deps.loadRegistry = async () => [{ ...structuredClone(demoProgram), recheckAfter: '2026-10-20T00:00:00Z' }];
  error(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
  packet(await state.send({ ...request, generationKey: 'new-freshness-key' }));
});

test('source expiry caps packet freshness and a registry read crossing expiry cannot save a stale pass', async () => {
  const program = structuredClone(demoProgram);
  program.recheckAfter = '2026-10-20T00:00:00Z';
  program.sources = [{ id: 'source', url: 'https://example.org/synthetic', title: 'Synthetic source', reviewedOn: '2026-10-12', effectiveFrom: null, effectiveUntil: '2026-10-13' }];
  const state = setup(makeCase(), program);
  assert.equal(packet(await state.send()).recheckAfter, '2026-10-14T00:00:00.000Z');
  const crossing = setup(makeCase(), program);
  crossing.deps.loadRegistry = async () => { crossing.setNow('2026-10-14T00:00:00Z'); return [program]; };
  error(await crossing.send(), 409, 'PACKET_GENERATION_CONFLICT');
  assert.equal(crossing.attempts.length, 0);
});

test('freshness is checked again after an awaited save or cached lookup', async () => {
  for (const retry of [false, true]) {
    const state = setup(); if (retry) packet(await state.send());
    const save = state.deps.cases.createPacketIfCurrent;
    state.deps.cases.createPacketIfCurrent = async input => {
      const result = await save(input); state.setNow(demoProgram.recheckAfter!); return result;
    };
    error(await state.send(), 409, 'PACKET_GENERATION_CONFLICT');
  }
});

test('freshness comparisons retain submillisecond precision and reject impossible dates', () => {
  const draft = planDraftPacket(makeCase(), selectedMatch(), { packetId: 'packet', generatedAt: demoContext.evaluatedAt });
  draft.recheckAfter = '2026-10-13T19:00:00.000001Z';
  assert.equal(isPacketCurrent(draft, '2026-10-13T19:00:00.000000Z'), true);
  assert.equal(isPacketCurrent(draft, '2026-10-13T19:00:00.000001Z'), false);
  assert.throws(() => instantMicros('2026-02-30T00:00:00Z'));
});

test('dependency exceptions are sanitized and never return a successful packet', async () => {
  for (const dependency of ['auth', 'load', 'registry', 'save']) {
    const state = setup();
    const reject = async () => { throw new Error('alice-token PRIVATE-CASE SECRET'); };
    if (dependency === 'auth') state.deps.authenticate = reject;
    if (dependency === 'load') state.deps.cases.loadForUser = reject;
    if (dependency === 'registry') state.deps.loadRegistry = reject;
    if (dependency === 'save') state.deps.cases.createPacketIfCurrent = reject;
    const result = await state.send(); error(result, 503, 'SERVICE_UNAVAILABLE');
    assert.doesNotMatch(JSON.stringify(result), /alice-token|PRIVATE-CASE|SECRET/);
  }
});

test('malformed internal case, registry, identity, clock and saved packets fail closed', async () => {
  const mutations: ((deps: PreparePacketDependencies) => void)[] = [
    deps => { deps.cases.loadForUser = async () => ({ ...makeCase(), caseId: 'wrong-case' }); },
    deps => { deps.cases.loadForUser = async () => ({ ...makeCase(), profile: {} } as CaseSnapshot); },
    deps => { deps.loadRegistry = async () => [{ ...demoProgram, criteria: [] }]; },
    deps => { deps.loadRegistry = async () => null as unknown as ProgramDefinition[]; },
    deps => { deps.authenticate = async () => ({ userId: '' }); },
    deps => { deps.now = () => new Date('invalid'); },
    deps => { deps.newPacketId = () => ''; },
    deps => { deps.cases.createPacketIfCurrent = async input => ({ status: 'saved', packet: { ...input.packet, caseId: 'another-owner-case' } }); },
    deps => { deps.cases.createPacketIfCurrent = async input => ({ status: 'saved', packet: { ...input.packet, storageReference: 'https://private-record.example' } }); },
  ];
  for (const mutate of mutations) {
    const state = setup(); mutate(state.deps); error(await state.send(), 500, 'INTERNAL_ERROR');
  }
});

test('memory packet writes recheck owner, revision, identity and copy stored outputs', async () => {
  const state = setup(); const first = packet(await state.send());
  const input = state.attempts[0];
  assert.deepEqual(await state.repository.createPacketIfCurrent({ ...input, userId: 'bob' }), { status: 'not_found' });
  assert.deepEqual(await state.repository.createPacketIfCurrent({ ...input, revision: 2 }), { status: 'conflict' });
  await assert.rejects(state.repository.createPacketIfCurrent({ ...input, packet: { ...first, caseId: 'other' } }));
  first.missingItems[0].description = 'Changed by client'; input.packet.missingItems.length = 0;
  const retry = packet(await state.send());
  assert.notEqual(retry.missingItems[0].description, 'Changed by client');
  assert.ok(retry.missingItems.length > 0);
});
