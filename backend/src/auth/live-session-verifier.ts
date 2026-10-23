import { randomUUID } from 'node:crypto';
import { isIP } from 'node:net';
import { isNewCaseId } from '../cases/validation.ts';
import { parseCaseListPage, type CaseListSummary } from '../cases/discovery.ts';
import { matchPrograms } from '../matcher.ts';
import { createSupabaseAuthenticator, MAX_AUTH_RESPONSE_BYTES, type SupabaseAuthConfig } from './supabase-auth.ts';

export interface TestAccount { email: string; password: string }
export interface LiveSessionConfiguration {
  auth: SupabaseAuthConfig;
  apiOrigin: string;
  accounts: readonly [TestAccount, TestAccount];
  caseIds: readonly [string, string];
  createFixtures: boolean;
}
export type VerificationStage = 'configuration' | 'sign_in_a' | 'sign_in_b' | 'identity'
  | 'refresh' | 'fixture_a' | 'fixture_b' | 'ownership' | 'invalid_token' | 'case_discovery'
  | 'local_sign_out' | 'refresh_denial';

export class LiveSessionVerificationError extends Error {
  readonly stage: VerificationStage;
  readonly cleanupFailed: boolean;
  constructor(stage: VerificationStage, cleanupFailed = false) {
    super(`Live session verification failed at ${stage}.${cleanupFailed ? ' Session cleanup could not be fully confirmed.' : ''}`);
    this.name = 'LiveSessionVerificationError'; this.stage = stage; this.cleanupFailed = cleanupFailed;
  }
}
interface Session { accessToken: string; refreshToken: string }
interface JsonResponse { status: number; body: unknown }
const fail = (stage: VerificationStage): never => { throw new LiveSessionVerificationError(stage); };
const record = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);
const bearer = (value: unknown): value is string => typeof value === 'string' && value.length > 0
  && value.length <= 4096 && /^[A-Za-z0-9._~+/-]+=*$/.test(value) && !/\s/.test(value);

export function validateTestAccounts(value: readonly TestAccount[]): readonly [TestAccount, TestAccount] {
  if (!Array.isArray(value) || value.length !== 2) return fail('configuration');
  const accounts = value.map(account => {
    if (!record(account) || typeof account.email !== 'string' || account.email.length > 254
      || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(account.email)
      || /[\u0000-\u001f\u007f-\u009f]/.test(account.email)
      || typeof account.password !== 'string' || account.password.length === 0 || account.password.length > 4096
      || account.password.includes('\u0000')) return fail('configuration');
    return Object.freeze({ email: account.email, password: account.password });
  });
  if (accounts[0].email.toLowerCase() === accounts[1].email.toLowerCase()) return fail('configuration');
  return Object.freeze(accounts) as unknown as readonly [TestAccount, TestAccount];
}

export function validateRemoteApiOrigin(value: unknown): string {
  try {
    if (typeof value !== 'string' || value.length > 2048 || /\s|\\/.test(value)) return fail('configuration');
    const parsed = new URL(value);
    const hostname = parsed.hostname;
    if (parsed.protocol !== 'https:' || value !== parsed.origin || parsed.port !== ''
      || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/'
      || isIP(hostname.replace(/^\[|\]$/g, '')) !== 0 || !hostname.includes('.')
      || hostname.endsWith('.') || hostname === 'localhost' || hostname.endsWith('.localhost')
      || hostname.endsWith('.local') || !/^[a-z0-9.-]+$/.test(hostname)
      || hostname.split('.').some(label => !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label))) return fail('configuration');
    return parsed.origin;
  } catch { return fail('configuration'); }
}

function configuration(input: LiveSessionConfiguration, allowRemoteHttps: boolean) {
  try {
    createSupabaseAuthenticator(input.auth);
    const auth = { ...input.auth };
    const accounts = validateTestAccounts(input.accounts);
    const validOrigin = allowRemoteHttps ? validateRemoteApiOrigin(input.apiOrigin) === input.apiOrigin
      : /^http:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}$/.test(input.apiOrigin)
        && Number(new URL(input.apiOrigin).port) <= 65535;
    if (!validOrigin || typeof input.createFixtures !== 'boolean'
      || !Array.isArray(input.caseIds) || input.caseIds.length !== 2
      || !input.caseIds.every(value => isNewCaseId(value) && value.length === 36)
      || input.caseIds[0] === input.caseIds[1]) return fail('configuration');
    return { auth, accounts, apiOrigin: input.apiOrigin, caseIds: [...input.caseIds],
      createFixtures: input.createFixtures, origin: new URL(auth.projectUrl).origin,
      timeoutMs: auth.timeoutMs ?? 5000 };
  } catch { return fail('configuration'); }
}

async function requestJson(
  fetchImpl: typeof fetch, endpoint: string, headers: Record<string, string>, body: unknown,
  timeoutMs: number, stage: VerificationStage,
): Promise<JsonResponse> {
  const controller = new AbortController();
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let responseBody: ReadableStream<Uint8Array> | null = null;
  let active = true;
  const expiresAt = performance.now() + timeoutMs;
  const cancel = () => { try { void (reader ? reader.cancel() : responseBody?.cancel())?.catch(() => {}); } catch {   } };
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { active = false; controller.abort(); cancel(); reject(new LiveSessionVerificationError(stage)); }, timeoutMs);
  });
  const work = async () => {
    const response = await fetchImpl(endpoint, { method: 'POST',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify(body), redirect: 'error', cache: 'no-store', signal: controller.signal });
    responseBody = response.body;
    if (!active || performance.now() >= expiresAt) {
      cancel();
      return fail(stage);
    }
    if (response.redirected || (response.url !== '' && response.url !== endpoint)) return fail(stage);
    if (response.status === 204) return { status: 204, body: null };
    if (response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() !== 'application/json'
      || responseBody === null) return fail(stage);
    const length = response.headers.get('content-length');
    if (length !== null && (!/^[0-9]+$/.test(length) || length.length > 10
      || Number(length) > MAX_AUTH_RESPONSE_BYTES)) return fail(stage);
    const bytes = new Uint8Array(MAX_AUTH_RESPONSE_BYTES);
    let size = 0;
    reader = responseBody.getReader();
    while (true) {
      const chunk = await reader.read();
      if (!active || performance.now() >= expiresAt) return fail(stage);
      if (chunk.done) break;
      if (!(chunk.value instanceof Uint8Array) || chunk.value.byteLength > bytes.byteLength - size) return fail(stage);
      bytes.set(chunk.value, size); size += chunk.value.byteLength;
    }
    return { status: response.status,
      body: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, size))) as unknown };
  };
  try { return await Promise.race([work(), deadline]); }
  catch { return fail(stage); }
  finally { active = false; clearTimeout(timer!); controller.abort(); cancel(); }
}

function session(response: JsonResponse, stage: VerificationStage): Session {
  if (response.status !== 200 || !record(response.body) || !bearer(response.body.access_token)
    || !bearer(response.body.refresh_token) || response.body.token_type !== 'bearer') return fail(stage);
  return { accessToken: response.body.access_token, refreshToken: response.body.refresh_token };
}
function apiError(response: JsonResponse, status: number, code: string): boolean {
  return response.status === status && record(response.body) && response.body.schemaVersion === '1'
    && Object.keys(response.body).length === 2 && record(response.body.error)
    && Object.keys(response.body.error).length === 2 && response.body.error.code === code
    && typeof response.body.error.message === 'string';
}
function snapshot(response: JsonResponse, caseId: string, stage: VerificationStage): void {
  if (response.status !== 200 || !record(response.body) || response.body.caseId !== caseId) return fail(stage);
  try { matchPrograms(response.body, [], { evaluationDate: '2000-01-01', evaluatedAt: '2000-01-01T00:00:00Z' }); }
  catch { return fail(stage); }
}
function fixture(caseId: string) {
  return { schemaVersion: '1', caseId, profile: { city: null, county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
}

export interface LiveSessionReport {
  status: 'passed'; signedInUsers: 2; distinctVerifiedUsers: true; refreshVerified: true;
  ownerReads: 2; crossOwnerDenials: 2; invalidTokenDenied: true;
  localSignOuts: 2; latestRefreshDeniedAfterSignOut: true; fixturesCreated: number;
  caseDiscovery?: CaseDiscoveryReport;
}

export interface CaseDiscoveryReport {
  pageSize: 1; pagesRead: number; userACaseCount: number; userBCaseCount: number;
  ownerFixturesFound: 2; crossOwnerFixturesExcluded: true; disjointOwnerLists: true;
  resumedCases: 2; resumedRevisionsCurrent: true; invalidTokenDenied: true;
}

type ApiRequest = (path: string, token: string, body: unknown, stage: VerificationStage) => Promise<JsonResponse>;

async function verifyCaseDiscovery(
  api: ApiRequest, sessions: readonly Session[], caseIds: readonly string[],
): Promise<CaseDiscoveryReport> {
  const stage = 'case_discovery';
  const lists: CaseListSummary[][] = [];
  let pagesRead = 0;
  for (let index = 0; index < 2; index++) {
    let afterCaseId: string | null = null;
    let complete = false;
    const summaries: CaseListSummary[] = [];
    for (let step = 0; step < 64; step++) {
      const query = { limit: 1, afterCaseId };
      const response = await api('list-cases', sessions[index].accessToken,
        { schemaVersion: '1', ...query }, stage);
      if (response.status !== 200 || !record(response.body) || response.body.schemaVersion !== '1'
        || Object.keys(response.body).length !== 3 || !Object.hasOwn(response.body, 'cases')
        || !Object.hasOwn(response.body, 'nextAfterCaseId')) return fail(stage);
      let page;
      try { page = parseCaseListPage({ cases: response.body.cases, nextAfterCaseId: response.body.nextAfterCaseId }, query); }
      catch { return fail(stage); }
      pagesRead++;
      summaries.push(...page.cases);
      afterCaseId = page.nextAfterCaseId;
      if (afterCaseId === null) { complete = true; break; }
    }
    if (!complete || !summaries.some(item => item.caseId === caseIds[index])
      || summaries.some(item => item.caseId === caseIds[1 - index])) return fail(stage);
    lists.push(summaries);
  }
  const firstIds = new Set(lists[0].map(item => item.caseId));
  if (lists[1].some(item => firstIds.has(item.caseId))) return fail(stage);
  for (let index = 0; index < 2; index++) {
    const caseId = caseIds[index];
    const listed = lists[index].find(item => item.caseId === caseId)!;
    const response = await api('read-case', sessions[index].accessToken, { schemaVersion: '1', caseId }, stage);
    snapshot(response, caseId, stage);
    if (!record(response.body) || typeof response.body.revision !== 'number'
      || response.body.revision < listed.caseRevision) return fail(stage);
  }
  if (!apiError(await api('list-cases', `invalid-session-check-${randomUUID()}`,
    { schemaVersion: '1', limit: 1, afterCaseId: null }, stage), 401, 'UNAUTHENTICATED')) return fail(stage);
  return Object.freeze({ pageSize: 1, pagesRead, userACaseCount: lists[0].length,
    userBCaseCount: lists[1].length, ownerFixturesFound: 2, crossOwnerFixturesExcluded: true,
    disjointOwnerLists: true, resumedCases: 2, resumedRevisionsCurrent: true, invalidTokenDenied: true });
}

export async function verifyLiveSessions(
  input: LiveSessionConfiguration,
  options: { fetchImpl?: typeof fetch; allowRemoteHttps?: boolean; verifyCaseDiscovery?: boolean } = {},
): Promise<LiveSessionReport> {
  if ((options.allowRemoteHttps !== undefined && typeof options.allowRemoteHttps !== 'boolean')
    || (options.verifyCaseDiscovery !== undefined && typeof options.verifyCaseDiscovery !== 'boolean')) return fail('configuration');
  const checkCaseDiscovery = options.verifyCaseDiscovery ?? false;
  const config = configuration(input, options.allowRemoteHttps ?? false);
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  if (typeof fetchImpl !== 'function') return fail('configuration');
  const authenticate = createSupabaseAuthenticator(config.auth, fetchImpl);
  const authHeaders = { apikey: config.auth.publishableKey };
  const provider = (path: string, body: unknown, stage: VerificationStage, token?: string) => requestJson(fetchImpl,
    `${config.origin}/auth/v1/${path}`, { ...authHeaders, ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body, config.timeoutMs, stage);
  const api = (path: string, token: string, body: unknown, stage: VerificationStage) => requestJson(fetchImpl,
    `${config.apiOrigin}/v1/${path}`, { Authorization: `Bearer ${token}` }, body, config.timeoutMs, stage);
  const sessions: Session[] = [];
  let unverifiedRefresh: Session | null = null;
  let stage: VerificationStage = 'sign_in_a';
  let failed: VerificationStage | null = null;
  let cleanupFailed = false;
  let unresolvedSignIn = false;
  let fixturesCreated = 0;
  let caseDiscovery: CaseDiscoveryReport | undefined;
  try {
    for (let index = 0; index < 2; index++) {
      stage = index === 0 ? 'sign_in_a' : 'sign_in_b';
      unresolvedSignIn = true;
      const response = await provider('token?grant_type=password', config.accounts[index], stage);
      if (response.status >= 400 && response.status < 500) unresolvedSignIn = false;
      sessions.push(session(response, stage)); unresolvedSignIn = false;
    }
    stage = 'identity';
    const a = await authenticate(sessions[0].accessToken);
    const b = await authenticate(sessions[1].accessToken);
    if (!a || !b || a.userId === b.userId) return fail(stage);
    stage = 'refresh';
    unverifiedRefresh = session(await provider('token?grant_type=refresh_token', { refresh_token: sessions[0].refreshToken }, stage), stage);
    const refreshed = await authenticate(unverifiedRefresh.accessToken);
    if (!refreshed || refreshed.userId !== a.userId) fail(stage);
    sessions[0] = unverifiedRefresh;
    unverifiedRefresh = null;
    for (let index = 0; index < 2; index++) {
      stage = index === 0 ? 'fixture_a' : 'fixture_b';
      const caseId = config.caseIds[index];
      const response = await api('read-case', sessions[index].accessToken, { schemaVersion: '1', caseId }, stage);
      if (config.createFixtures && apiError(response, 404, 'CASE_NOT_FOUND')) {
        snapshot(await api('create-case', sessions[index].accessToken, fixture(caseId), stage), caseId, stage);
        fixturesCreated++;
      } else snapshot(response, caseId, stage);
    }
    stage = 'ownership';
    for (let index = 0; index < 2; index++) {
      const caseId = config.caseIds[index];
      snapshot(await api('read-case', sessions[index].accessToken, { schemaVersion: '1', caseId }, stage), caseId, stage);
      if (!apiError(await api('read-case', sessions[1 - index].accessToken,
        { schemaVersion: '1', caseId }, stage), 404, 'CASE_NOT_FOUND')) fail(stage);
    }
    stage = 'invalid_token';
    if (!apiError(await api('read-case', `invalid-session-check-${randomUUID()}`,
      { schemaVersion: '1', caseId: config.caseIds[0] }, stage), 401, 'UNAUTHENTICATED')) fail(stage);
    if (checkCaseDiscovery) {
      stage = 'case_discovery';
      caseDiscovery = await verifyCaseDiscovery(api, sessions, config.caseIds);
    }
  } catch { failed = stage; }
  finally {
    cleanupFailed = unresolvedSignIn;
    const cleanupSessions = [...sessions, ...(unverifiedRefresh ? [unverifiedRefresh] : [])];
    const attemptedTokens = new Set<string>();
    for (const value of cleanupSessions) {
      if (attemptedTokens.has(value.accessToken)) continue;
      attemptedTokens.add(value.accessToken);
      try {
        if ((await provider('logout?scope=local', {}, 'local_sign_out', value.accessToken)).status !== 204) cleanupFailed = true;
      } catch { cleanupFailed = true; }
    }
  }
  if (failed) throw new LiveSessionVerificationError(failed, cleanupFailed);
  if (cleanupFailed) throw new LiveSessionVerificationError('local_sign_out', true);
  try {
    const response = await provider('token?grant_type=refresh_token', { refresh_token: sessions[0].refreshToken }, 'refresh_denial');
    if ((response.status === 400 || response.status === 401) && record(response.body)
      && typeof response.body.error_code === 'string'
      && ['refresh_token_not_found', 'session_not_found', 'session_expired'].includes(response.body.error_code)) {
      return Object.freeze({ status: 'passed', signedInUsers: 2, distinctVerifiedUsers: true, refreshVerified: true,
        ownerReads: 2, crossOwnerDenials: 2, invalidTokenDenied: true, localSignOuts: 2,
        latestRefreshDeniedAfterSignOut: true, fixturesCreated, ...(caseDiscovery ? { caseDiscovery } : {}) });
    }
    if (response.status === 200) {
      try {
        const unexpected = session(response, 'refresh_denial');
        cleanupFailed = (await provider('logout?scope=local', {}, 'local_sign_out', unexpected.accessToken)).status !== 204;
      } catch { cleanupFailed = true; }
    }
  } catch {
    cleanupFailed = true;
  }
  throw new LiveSessionVerificationError('refresh_denial', cleanupFailed);
}
