import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as pause } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { hostedApiEnvironment } from './verify-hosted-api.ts';
import type { HostedApiConfiguration } from '../src/auth/hosted-api-verifier.ts';
import { createSupabaseAuthenticator } from '../src/auth/supabase-auth.ts';
import { validateRemoteApiOrigin, validateTestAccounts } from '../src/auth/live-session-verifier.ts';
import { isNewCaseId, parseWrittenCase } from '../src/cases/validation.ts';
import { emptyPlanName, parseNamedCaseListPage, parsePlanNameState, type PlanNameState, type SavePlanNameRequest } from '../src/cases/plan-name.ts';
import { canonicalJson, caseFingerprint } from '../src/evidence/validation.ts';

const MAX_REQUESTS = 60, MAX_DURATION_MS = 120_000, PACE_MS = 1200;
const sha = (value: string) => createHash('sha256').update(value).digest('hex');
const same = (a: unknown, b: unknown) => canonicalJson(a) === canonicalJson(b);
function check(value: unknown): asserts value { if (!value) throw new Error('Unexpected plan-name acceptance result.'); }
function object(value: unknown): Record<string, unknown> {
  check(value !== null && typeof value === 'object' && !Array.isArray(value)); return value as Record<string, unknown>;
}
function bearer(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 4096 && /^[A-Za-z0-9._~+/-]+=*$/.test(value);
}
export interface PlanNameCheckConfiguration extends HostedApiConfiguration { newCaseId: string; runId: string }
export interface PlanNameCheckEvent {
  stage: string; state: 'intent' | 'confirmed' | 'failed'; caseId: string;
  ownerHash?: string; requestHash?: string; mutationId?: string; nameRevision?: number;
  caseRevision?: number; caseFingerprint?: string; catalogRevision?: number;
  mutationUncertain?: boolean; cleanupPending?: boolean; sessionCleanupFailed?: boolean;
}
export interface PlanNameCheckReport {
  status: 'passed'; requests: number; elapsedMs: number; ownerSessions: 2; outsiderSessions: 1;
  crossSessionNamesVerified: true; exactRetriesVerified: true; staleWritesRejected: true;
  ownerIsolationVerified: true; resetRevisionVerified: true; caseRevisionUnchanged: true;
  caseDeleted: true; localSignOuts: 3;
}
export class PlanNameCheckError extends Error {
  readonly stage: string; readonly mutationUncertain: boolean; readonly cleanupPending: boolean; readonly sessionCleanupFailed: boolean;
  constructor(stage: string, mutationUncertain = false, cleanupPending = false, sessionCleanupFailed = false) {
    super(`Hosted plan-name check failed at ${stage}.${mutationUncertain ? ' A write may have completed; inspect the private journal.' : ''}${cleanupPending ? ' The temporary case is retained for guarded recovery.' : ''}${sessionCleanupFailed ? ' Session cleanup was not fully confirmed.' : ''}`);
    this.name = 'PlanNameCheckError'; this.stage = stage; this.mutationUncertain = mutationUncertain;
    this.cleanupPending = cleanupPending; this.sessionCleanupFailed = sessionCleanupFailed;
  }
}

export async function createPlanNameCheckJournal(directory: string, initial: {
  apiOrigin: string; projectOrigin: string; caseId: string; runId: string;
}) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await lstat(directory);
  check(stat.isDirectory() && !stat.isSymbolicLink() && (stat.mode & 0o077) === 0
    && (typeof process.getuid !== 'function' || stat.uid === process.getuid()));
  const handle = await open(join(directory, 'hosted-plan-names-check.jsonl'), 'wx', 0o600);
  try {
    await handle.writeFile(`${JSON.stringify({ schemaVersion: '1', kind: 'retained-identifiers', ...initial })}\n`); await handle.sync();
    const parent = await open(directory, constants.O_RDONLY | constants.O_NOFOLLOW);
    try { await parent.sync(); } finally { await parent.close(); }
  } catch (error) { await handle.close(); throw error; }
  return {
    async journal(event: Readonly<PlanNameCheckEvent>) { await handle.writeFile(`${JSON.stringify(event)}\n`); await handle.sync(); },
    async report(report: PlanNameCheckReport) { await handle.writeFile(`${JSON.stringify({ kind: 'report', ...report })}\n`); await handle.sync(); },
    close: () => handle.close(),
  };
}

interface Wire { status: number; headers: Headers; body: unknown }
async function wire(fetcher: typeof fetch, url: string, headers: Record<string, string>, body: unknown, timeout: number,
  onParsed?: (value: unknown, status: number) => void): Promise<Wire> {
  const controller = new AbortController(); let active = true;
  let stream: ReadableStream<Uint8Array> | null = null, reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  const cancel = () => { try { void (reader ? reader.cancel() : stream?.cancel())?.catch(() => {}); } catch {   } };
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<never>((_, reject) => { timer = setTimeout(() => { active = false; controller.abort(); cancel(); reject(new Error()); }, timeout); });
  try {
    return await Promise.race([deadline, (async () => {
      const response = await fetcher(url, { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...headers },
        body: JSON.stringify(body), redirect: 'error', cache: 'no-store', signal: controller.signal });
      stream = response.body; check(active && !response.redirected && (response.url === '' || response.url === url));
      if (response.status === 204) { check(stream === null); return { status: 204, headers: response.headers, body: null }; }
      check(stream && response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() === 'application/json');
      const maximum = 64 * 1024, length = response.headers.get('content-length');
      check(length === null || /^\d{1,10}$/.test(length) && Number(length) <= maximum);
      const bytes = new Uint8Array(maximum); let size = 0; reader = stream.getReader();
      while (true) { const part = await reader.read(); check(active); if (part.done) break;
        check(part.value instanceof Uint8Array && part.value.length <= maximum - size); bytes.set(part.value, size); size += part.value.length; }
      const parsed: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, size)));
      onParsed?.(parsed, response.status);
      const encoding = response.headers.get('content-encoding')?.trim().toLowerCase();
      check(encoding !== undefined && encoding !== '' && encoding !== 'identity' || length === null || Number(length) === size);
      return { status: response.status, headers: response.headers, body: parsed };
    })()]);
  } finally { active = false; clearTimeout(timer!); controller.abort(); cancel(); }
}
function errorIs(response: Wire, status: number, code: string) {
  const body = object(response.body), error = object(body.error);
  check(response.status === status && ['1', '2'].includes(String(body.schemaVersion)) && error.code === code && typeof error.message === 'string');
}

export async function verifyHostedPlanNames(input: PlanNameCheckConfiguration, options: {
  journal(event: Readonly<PlanNameCheckEvent>): Promise<void>; fetchImpl?: typeof fetch;
  testNoPacing?: boolean;
}): Promise<PlanNameCheckReport> {
  let config: PlanNameCheckConfiguration;
  try {
    check(typeof options.journal === 'function' && (!options.testNoPacing || options.fetchImpl !== undefined));
    check(isNewCaseId(input.newCaseId) && input.newCaseId.length === 36 && isNewCaseId(input.runId) && input.runId.length === 36
      && Array.isArray(input.caseIds) && input.caseIds.length === 2 && input.caseIds.every(id => isNewCaseId(id) && id.length === 36 && id !== input.newCaseId)
      && input.caseIds[0] !== input.caseIds[1]);
    config = { ...input, auth: { ...input.auth }, apiOrigin: validateRemoteApiOrigin(input.apiOrigin),
      accounts: validateTestAccounts(input.accounts), caseIds: [input.caseIds[0], input.caseIds[1]] };
    createSupabaseAuthenticator(config.auth);
  } catch { throw new PlanNameCheckError('configuration'); }
  const started = performance.now(), fetchImpl = options.fetchImpl ?? fetch;
  let requests = 0, nextApiAt = 0, cleanupMode = false, stage = 'configuration';
  let uncertain = false, createAttempted = false, created = false, deleted = false, unknownSignIn = false, signOutFailed = false;
  let failureStage: string | null = null, ownerHash = '';
  const tokens: string[] = [], remaining = () => MAX_DURATION_MS - (performance.now() - started);
  const journal = (state: PlanNameCheckEvent['state'], extra: Partial<PlanNameCheckEvent> = {}) => options.journal(Object.freeze({ stage, state, caseId: config.newCaseId, ...extra }));
  const transport: typeof fetch = async (url, init) => { check(requests < MAX_REQUESTS && remaining() > 0); requests++; return fetchImpl(url, init); };
  const provider = (path: string, body: unknown, access?: string, onParsed?: (value: unknown, status: number) => void) => wire(transport,
    `${new URL(config.auth.projectUrl).origin}/auth/v1/${path}`, { apikey: config.auth.publishableKey,
      ...(access ? { Authorization: `Bearer ${access}` } : {}) }, body, Math.min(5000, Math.max(1, remaining())), onParsed);
  const api = async (path: string, body: unknown, who = 0, token?: string) => {
    const reserve = cleanupMode ? 0 : 30_000; check(remaining() > reserve);
    const delay = nextApiAt - performance.now(); if (delay > 0) await pause(delay);
    check(remaining() > reserve); nextApiAt = performance.now() + (options.testNoPacing ? 0 : PACE_MS);
    const response = await wire(transport, `${config.apiOrigin}/${path}`, { Authorization: `Bearer ${token ?? tokens[who]}` }, body,
      Math.min(10_000, Math.max(1, remaining() - reserve)));
    check(response.headers.get('cache-control')?.split(',').some(value => value.trim().toLowerCase() === 'no-store')); return response;
  };
  const read = async (path: string, body: unknown, who = 0) => { const r = await api(path, body, who); check(r.status === 200); return r.body; };
  const readBody = { schemaVersion: '2', caseId: config.newCaseId }, caseBody = { schemaVersion: '1', caseId: config.newCaseId };
  const draft = { ...caseBody, profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
    householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
  const expectedCase = { ...draft, revision: 1 };
  const mutation = async <T>(request: unknown, work: () => Promise<T>, extra: Partial<PlanNameCheckEvent> = {}): Promise<T> => {
    await journal('intent', { requestHash: sha(canonicalJson(request)), ...extra }); uncertain = true;
    const result = await work(); await journal('confirmed', extra); uncertain = false; return result;
  };
  const nameRead = async (expected: PlanNameState, who = 0) => {
    check(same(parsePlanNameState(await read('v2/read-plan-name', readBody, who)), expected));
  };
  const nameSave = async (request: SavePlanNameRequest, who = 0) => mutation(request, async () => {
    const result = parsePlanNameState(await read('v2/save-plan-name', request, who));
    const expected: PlanNameState = { ...readBody, schemaVersion: '2', name: request.name,
      nameRevision: request.expectedNameRevision + 1, lastMutationId: request.mutationId };
    check(same(result, expected)); return result;
  }, { mutationId: request.mutationId, nameRevision: request.expectedNameRevision + 1 });
  const listQuery = { limit: 20, afterCaseId: config.newCaseId.slice(0, -1) };
  const listName = async (expected: PlanNameState | null, who = 0) => {
    const raw = object(await read('v2/list-cases', { schemaVersion: '2', ...listQuery }, who));
    check(Object.keys(raw).length === 3 && raw.schemaVersion === '2');
    const page = parseNamedCaseListPage({ cases: raw.cases, nextAfterCaseId: raw.nextAfterCaseId }, listQuery);
    const found = page.cases.find(item => item.caseId === config.newCaseId);
    check(expected ? found && same(found, { caseId: expected.caseId, caseRevision: 1, name: expected.name,
      nameRevision: expected.nameRevision, lastMutationId: expected.lastMutationId }) : !found);
  };
  try {
    await journal('confirmed'); stage = 'sign_in';
    for (const account of [config.accounts[0], config.accounts[0], config.accounts[1]]) {
      let retained: string | null = null; unknownSignIn = true;
      const response = await provider('token?grant_type=password', account, undefined, (value, status) => {
        if (status !== 200 || value === null || typeof value !== 'object' || Array.isArray(value)) return;
        const access = (value as Record<string, unknown>).access_token;
        if (bearer(access)) { tokens.push(access); retained = access; unknownSignIn = false; }
      });
      if (response.status >= 400 && response.status < 500) unknownSignIn = false;
      const value = object(response.body); check(response.status === 200 && value.token_type === 'bearer' && retained !== null && value.access_token === retained);
    }
    stage = 'identity'; check(new Set(tokens).size === 3);
    const authenticate = createSupabaseAuthenticator(config.auth, transport);
    const first = await authenticate(tokens[0]), second = await authenticate(tokens[1]), outsider = await authenticate(tokens[2]);
    check(first && second && outsider && first.userId === second.userId && first.userId !== outsider.userId);
    ownerHash = sha(first.userId); await journal('confirmed', { ownerHash });
    stage = 'existing_fixture_guards';
    for (let i = 0; i < 2; i++) {
      const body = { schemaVersion: '1', caseId: config.caseIds[i] }, who = i === 0 ? 0 : 2;
      check(parseWrittenCase(await read('v1/read-case', body, who)).caseId === config.caseIds[i]);
      errorIs(await api('v1/read-case', body, i === 0 ? 2 : 0), 404, 'CASE_NOT_FOUND');
    }
    errorIs(await api('v1/read-case', caseBody), 404, 'CASE_NOT_FOUND');
    stage = 'create_case';
    await mutation(draft, async () => { createAttempted = true;
      check(same(parseWrittenCase(await read('v1/create-case', draft)), expectedCase)); created = true;
    }, { caseRevision: 1, caseFingerprint: caseFingerprint(parseWrittenCase(expectedCase)) });
    stage = 'initial_name'; await nameRead(emptyPlanName(config.newCaseId), 1);
    const firstWrite: SavePlanNameRequest = { schemaVersion: '2', caseId: config.newCaseId, expectedNameRevision: 0,
      mutationId: `${config.runId}-first`, name: 'Fictional Cedar 🏠' };
    stage = 'first_name'; const firstName = await nameSave(firstWrite);
    stage = 'second_session_read'; await nameRead(firstName, 1);
    stage = 'exact_retry'; check(same(await nameSave(firstWrite, 1), firstName));
    stage = 'stale_write'; const stale = { ...firstWrite, mutationId: `${config.runId}-stale`, name: 'Fictional stale name' };
    await mutation(stale, async () => errorIs(await api('v2/save-plan-name', stale, 1), 409, 'PLAN_NAME_CONFLICT'));
    stage = 'mutation_identity'; const changed = { ...firstWrite, name: 'Fictional altered retry' };
    await mutation(changed, async () => errorIs(await api('v2/save-plan-name', changed), 409, 'PLAN_NAME_CONFLICT'));
    stage = 'second_session_write'; const secondName = await nameSave({ ...firstWrite, expectedNameRevision: 1,
      mutationId: `${config.runId}-second`, name: 'Fictional Maple plan' }, 1);
    stage = 'first_session_resume'; await nameRead(secondName); await listName(secondName);
    stage = 'owner_isolation';
    errorIs(await api('v2/read-plan-name', readBody, 2), 404, 'CASE_NOT_FOUND');
    const foreign = { ...firstWrite, expectedNameRevision: 2, mutationId: `${config.runId}-outsider` };
    await mutation(foreign, async () => errorIs(await api('v2/save-plan-name', foreign, 2), 404, 'CASE_NOT_FOUND'));
    await listName(null, 2);
    stage = 'reset_name'; const reset = await nameSave({ ...firstWrite, expectedNameRevision: 2,
      mutationId: `${config.runId}-reset`, name: null }, 1);
    await nameRead(reset); await listName(reset);
    stage = 'invalid_requests';
    errorIs(await api('v2/read-plan-name', readBody, 0, `invalid-plan-name-check-${config.runId}`), 401, 'UNAUTHENTICATED');
    const invalid = { ...firstWrite, expectedNameRevision: 3, mutationId: `${config.runId}-invalid`, name: 'x'.repeat(81) };
    await mutation(invalid, async () => errorIs(await api('v2/save-plan-name', invalid), 400, 'INVALID_REQUEST'));
    stage = 'cleanup_guards'; cleanupMode = true;
    check(created && !uncertain && ownerHash === sha(first.userId));
    check(same(parseWrittenCase(await read('v1/read-case', caseBody)), expectedCase));
    check(same(await read('v1/list-evidence', { ...caseBody, expectedCaseRevision: 1 }),
      { ...caseBody, caseRevision: 1, catalogRevision: 0, evidence: [] }));
    await nameRead(reset);
    stage = 'delete_test_case'; const remove = { ...caseBody, expectedCaseRevision: 1, expectedCatalogRevision: 0, confirmation: 'DELETE_CASE' };
    await mutation(remove, async () => { check(same(await read('v1/delete-case', remove), { ...caseBody, deleted: true })); deleted = true; },
      { caseRevision: 1, catalogRevision: 0, nameRevision: reset.nameRevision });
    stage = 'deleted_absence'; errorIs(await api('v1/read-case', caseBody), 404, 'CASE_NOT_FOUND');
    errorIs(await api('v2/read-plan-name', readBody, 1), 404, 'CASE_NOT_FOUND'); await listName(null, 1);
  } catch { failureStage = stage; }
  finally {
    cleanupMode = true;
    for (const token of new Set(tokens)) { try { check((await provider('logout?scope=local', {}, token)).status === 204); } catch { signOutFailed = true; } }
    if (unknownSignIn) signOutFailed = true;
    if (failureStage || signOutFailed) {
      stage = failureStage ?? 'sign_out';
      try { await journal('failed', { mutationUncertain: uncertain, cleanupPending: createAttempted && !deleted, sessionCleanupFailed: signOutFailed }); }
      catch {   }
    }
  }
  if (failureStage || signOutFailed) throw new PlanNameCheckError(failureStage ?? 'sign_out', uncertain, createAttempted && !deleted, signOutFailed);
  stage = 'complete'; await journal('confirmed');
  return { status: 'passed', requests, elapsedMs: Math.round(performance.now() - started), ownerSessions: 2, outsiderSessions: 1,
    crossSessionNamesVerified: true, exactRetriesVerified: true, staleWritesRejected: true, ownerIsolationVerified: true,
    resetRevisionVerified: true, caseRevisionUnchanged: true, caseDeleted: true, localSignOuts: 3 };
}

async function main() {
  if (process.argv.length !== 3 || process.argv[2] !== '--create-fictional-case') throw new PlanNameCheckError('configuration');
  const config: PlanNameCheckConfiguration = { ...await hostedApiEnvironment(process.env), newCaseId: randomUUID(), runId: randomUUID() };
  const journal = await createPlanNameCheckJournal(fileURLToPath(new URL('../local-artifacts/hosted-plan-names/', import.meta.url)), {
    apiOrigin: config.apiOrigin, projectOrigin: new URL(config.auth.projectUrl).origin, caseId: config.newCaseId, runId: config.runId });
  try { const report = await verifyHostedPlanNames(config, journal); await journal.report(report); console.log(JSON.stringify(report)); }
  finally { await journal.close(); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) main().catch(error => {
  console.error(error instanceof PlanNameCheckError ? error.message : 'Hosted plan-name check could not finish. Inspect the private journal before recovery; no sensitive details logged.'); process.exitCode = 1;
});
