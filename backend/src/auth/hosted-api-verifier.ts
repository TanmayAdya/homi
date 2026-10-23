import { isNewCaseId } from '../cases/validation.ts';
import { createSupabaseAuthenticator } from './supabase-auth.ts';
import { validateRemoteApiOrigin, validateTestAccounts, verifyLiveSessions,
  type LiveSessionConfiguration, type LiveSessionReport } from './live-session-verifier.ts';

export type HostedApiConfiguration = Omit<LiveSessionConfiguration, 'createFixtures'>;
export interface HostedVerificationOptions {
  fetchImpl?: typeof fetch;
  warmupTimeoutMs?: number;
  healthRequestTimeoutMs?: number;
  pollIntervalMs?: number;
  verifyCaseDiscovery?: boolean;
}
export interface HostedApiReport extends LiveSessionReport {
  healthReady: true; healthHeadVerified: true; healthAttempts: number;
}
export class HostedApiVerificationError extends Error {
  readonly stage: 'configuration' | 'health';
  constructor(stage: 'configuration' | 'health') {
    super(stage === 'configuration' ? 'Invalid hosted API verification configuration.'
      : 'Hosted API health verification failed. Check the HTTPS origin, readiness and health response.');
    this.name = 'HostedApiVerificationError'; this.stage = stage;
  }
}
const fail = (stage: 'configuration' | 'health'): never => { throw new HostedApiVerificationError(stage); };
const MAX_HEALTH_BYTES = 1024;
const transientStatuses = new Set([429, 502, 503, 504]);

function configuration(input: HostedApiConfiguration, options: HostedVerificationOptions) {
  try {
    const apiOrigin = validateRemoteApiOrigin(input.apiOrigin);
    createSupabaseAuthenticator(input.auth);
    const auth = { ...input.auth };
    const accounts = validateTestAccounts(input.accounts);
    if (!Array.isArray(input.caseIds) || input.caseIds.length !== 2
      || !input.caseIds.every(value => isNewCaseId(value) && value.length === 36)
      || input.caseIds[0] === input.caseIds[1] || Object.hasOwn(input, 'createFixtures')) return fail('configuration');
    const fetchImpl = options.fetchImpl ?? globalThis.fetch;
    const warmupTimeoutMs = options.warmupTimeoutMs ?? 90_000;
    const healthRequestTimeoutMs = options.healthRequestTimeoutMs ?? 10_000;
    const pollIntervalMs = options.pollIntervalMs ?? 2000;
    const verifyCaseDiscovery = options.verifyCaseDiscovery ?? false;
    if (typeof fetchImpl !== 'function' || !Number.isInteger(warmupTimeoutMs) || warmupTimeoutMs < 1 || warmupTimeoutMs > 90_000
      || !Number.isInteger(healthRequestTimeoutMs) || healthRequestTimeoutMs < 1 || healthRequestTimeoutMs > 10_000
      || !Number.isInteger(pollIntervalMs) || pollIntervalMs < 1 || pollIntervalMs > 5000
      || (options.verifyCaseDiscovery !== undefined && typeof options.verifyCaseDiscovery !== 'boolean')) return fail('configuration');
    return { input: { apiOrigin, auth, accounts, caseIds: [...input.caseIds] as [string, string] },
      fetchImpl, warmupTimeoutMs, healthRequestTimeoutMs, pollIntervalMs, verifyCaseDiscovery };
  } catch { return fail('configuration'); }
}

async function healthRequest(
  endpoint: string, method: 'GET' | 'HEAD', timeoutMs: number, fetchImpl: typeof fetch,
): Promise<boolean> {
  const controller = new AbortController();
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let responseBody: ReadableStream<Uint8Array> | null = null;
  let active = true;
  const expiresAt = performance.now() + timeoutMs;
  const cancel = () => { try { void (reader ? reader.cancel() : responseBody?.cancel())?.catch(() => {}); } catch {   } };
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<false>(resolve => {
    timer = setTimeout(() => { active = false; controller.abort(); cancel(); resolve(false); }, timeoutMs);
  });
  const work = async () => {
    let response: Response;
    try {
      response = await fetchImpl(endpoint, { method, headers: { Accept: 'application/json' },
        redirect: 'error', cache: 'no-store', signal: controller.signal });
    } catch { return false; }
    responseBody = response.body;
    if (!active || performance.now() >= expiresAt) { cancel(); return false; }
    if (response.redirected || (response.url !== '' && response.url !== endpoint)
      || (response.status >= 300 && response.status < 400)) return fail('health');
    if (transientStatuses.has(response.status)) return false;
    if (response.status !== 200
      || response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() !== 'application/json'
      || !response.headers.get('cache-control')?.split(',').some(value => value.trim().toLowerCase() === 'no-store')) return fail('health');
    const length = response.headers.get('content-length');
    if (length !== null && (!/^[0-9]+$/.test(length) || length.length > 10 || Number(length) > MAX_HEALTH_BYTES)) return fail('health');
    if (method === 'HEAD') {
      if (responseBody !== null) return fail('health');
      return true;
    }
    if (responseBody === null) return fail('health');
    reader = responseBody.getReader();
    const bytes = new Uint8Array(MAX_HEALTH_BYTES);
    let size = 0;
    try {
      while (true) {
        const chunk = await reader.read();
        if (!active || performance.now() >= expiresAt) return false;
        if (chunk.done) break;
        if (!(chunk.value instanceof Uint8Array) || chunk.value.byteLength > bytes.byteLength - size) return fail('health');
        bytes.set(chunk.value, size); size += chunk.value.byteLength;
      }
      const value: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, size)));
      if (typeof value !== 'object' || value === null || Array.isArray(value)
        || Object.keys(value).length !== 1 || !('status' in value) || value.status !== 'ok') return fail('health');
      return true;
    } catch { return fail('health'); }
  };
  try { return await Promise.race([work(), deadline]); }
  finally { active = false; clearTimeout(timer!); controller.abort(); cancel(); }
}

export async function verifyHostedApi(
  input: HostedApiConfiguration, options: HostedVerificationOptions = {},
): Promise<HostedApiReport> {
  const config = configuration(input, options);
  const endpoint = `${config.input.apiOrigin}/healthz`;
  const expiresAt = performance.now() + config.warmupTimeoutMs;
  let healthAttempts = 0;
  while (true) {
    const remaining = expiresAt - performance.now();
    if (remaining <= 0) return fail('health');
    healthAttempts++;
    if (await healthRequest(endpoint, 'GET', Math.min(config.healthRequestTimeoutMs, remaining), config.fetchImpl)) break;
    const pause = Math.min(config.pollIntervalMs, expiresAt - performance.now());
    if (pause <= 0) return fail('health');
    await new Promise<void>(resolve => setTimeout(resolve, pause));
  }
  const remaining = expiresAt - performance.now();
  if (remaining <= 0 || !await healthRequest(endpoint, 'HEAD', Math.min(config.healthRequestTimeoutMs, remaining), config.fetchImpl)) return fail('health');
  const sessions = await verifyLiveSessions({ ...config.input, createFixtures: false },
    { fetchImpl: config.fetchImpl, allowRemoteHttps: true, verifyCaseDiscovery: config.verifyCaseDiscovery });
  return Object.freeze({ ...sessions, healthReady: true, healthHeadVerified: true, healthAttempts });
}
