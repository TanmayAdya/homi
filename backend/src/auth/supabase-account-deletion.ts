import type { AuthDeletionJob, LifecycleMaintenance } from '../lifecycle/types.ts';
import { MAX_AUTH_RESPONSE_BYTES } from './supabase-auth.ts';

export interface SupabaseAccountDeletionConfig {
  projectUrl: string;
  secretKey: string;
  timeoutMs?: number;
}
export type AccountDeletionProviderResult = { status: 'deleted' | 'already_absent' };
export type AccountDeleter = (userId: string) => Promise<AccountDeletionProviderResult>;

export class AccountDeletionProviderError extends Error {
  constructor() {
    super('Provider account deletion could not be confirmed. The request remains pending.');
    this.name = 'AccountDeletionProviderError';
  }
}

const record = (value: unknown): value is Record<string, unknown> => value !== null
  && typeof value === 'object' && !Array.isArray(value);
const uuid = (value: unknown): value is string => typeof value === 'string' && value.length === 36
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);

function configuration(input: SupabaseAccountDeletionConfig) {
  try {
    if (!record(input)) throw new Error();
    const { projectUrl, secretKey, timeoutMs = 5000 } = input;
    if (typeof projectUrl !== 'string' || projectUrl.length > 2048 || /\s/.test(projectUrl)
      || !/^https:\/\/[^@/?#\\\s]+\/?$/.test(projectUrl)) throw new Error();
    const parsed = new URL(projectUrl);
    if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password
      || parsed.pathname !== '/' || parsed.search || parsed.hash) throw new Error();
    if (typeof secretKey !== 'string' || secretKey.length > 512
      || !/^sb_secret_[A-Za-z0-9_-]+$/.test(secretKey) || /\s/.test(secretKey)) throw new Error();
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 10_000) throw new Error();
    return { origin: parsed.origin, secretKey, timeoutMs };
  } catch {
    throw new TypeError('Invalid operator account-deletion configuration.');
  }
}

export function createSupabaseAccountDeleter(
  config: SupabaseAccountDeletionConfig,
  fetchImpl: typeof fetch = globalThis.fetch,
): AccountDeleter {
  const { origin, secretKey, timeoutMs } = configuration(config);
  if (typeof fetchImpl !== 'function') throw new TypeError('Invalid account-deletion transport.');

  async function request(endpoint: string, method: 'GET' | 'DELETE') {
    const controller = new AbortController();
    const expiresAt = performance.now() + timeoutMs;
    let active = true;
    let body: ReadableStream<Uint8Array> | null = null;
    let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
    const cancel = () => {
      try { void (reader ? reader.cancel() : body?.cancel())?.catch(() => {}); } catch {   }
    };
    let timer: ReturnType<typeof setTimeout>;
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        active = false; controller.abort(); cancel(); reject(new AccountDeletionProviderError());
      }, timeoutMs);
    });
    const work = async (): Promise<{ status: number; value: unknown }> => {
      const response = await fetchImpl(endpoint, {
        method, headers: { Accept: 'application/json', apikey: secretKey,
          'X-Supabase-Api-Version': '2024-01-01',
          ...(method === 'DELETE' ? { 'Content-Type': 'application/json' } : {}) },
        ...(method === 'DELETE' ? { body: JSON.stringify({ should_soft_delete: false }) } : {}),
        redirect: 'error', cache: 'no-store', signal: controller.signal,
      });
      body = response.body;
      if (!active || performance.now() >= expiresAt) { cancel(); throw new AccountDeletionProviderError(); }
      if (response.redirected || (response.url !== '' && response.url !== endpoint)
        || ![200, 404].includes(response.status)
        || response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() !== 'application/json'
        || body === null) throw new AccountDeletionProviderError();
      const length = response.headers.get('content-length');
      if (length !== null && (!/^[0-9]+$/.test(length) || length.length > 10
        || Number(length) > MAX_AUTH_RESPONSE_BYTES)) throw new AccountDeletionProviderError();
      const bytes = new Uint8Array(MAX_AUTH_RESPONSE_BYTES);
      let size = 0;
      reader = body.getReader();
      while (true) {
        const chunk = await reader.read();
        if (!active || performance.now() >= expiresAt) throw new AccountDeletionProviderError();
        if (chunk.done) break;
        if (!(chunk.value instanceof Uint8Array) || chunk.value.byteLength > bytes.byteLength - size) {
          throw new AccountDeletionProviderError();
        }
        bytes.set(chunk.value, size); size += chunk.value.byteLength;
      }
      return { status: response.status,
        value: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, size))) as unknown };
    };
    try { return await Promise.race([work(), deadline]); }
    catch { throw new AccountDeletionProviderError(); }
    finally { active = false; clearTimeout(timer!); controller.abort(); cancel(); }
  }
  const absent = (response: { status: number; value: unknown }) => {
    if (response.status !== 404 || !record(response.value)) return false;
    const value = response.value;
    if (value.code === 'user_not_found') {
      return !Object.hasOwn(value, 'error_code') || value.error_code === 'user_not_found';
    }
    return value.code === 404 && value.error_code === 'user_not_found';
  };

  return async (userId: string): Promise<AccountDeletionProviderResult> => {
    if (!uuid(userId)) throw new AccountDeletionProviderError();
    const endpoint = `${origin}/auth/v1/admin/users/${userId}`;
    const before = await request(endpoint, 'GET');
    if (absent(before)) return { status: 'already_absent' };
    if (before.status !== 200 || !record(before.value) || before.value.id !== userId
      || before.value.role !== 'authenticated') throw new AccountDeletionProviderError();
    const removed = await request(endpoint, 'DELETE');
    if (!absent(removed) && (removed.status !== 200 || !record(removed.value)
      || Object.keys(removed.value).length !== 0)) throw new AccountDeletionProviderError();
    const after = await request(endpoint, 'GET');
    if (!absent(after)) throw new AccountDeletionProviderError();
    return { status: 'deleted' };
  };
}

export interface AccountDeletionWorkerOptions { apply: boolean; limit: number }
export interface AccountDeletionWorkerReport {
  mode: 'dry_run' | 'apply';
  pendingBefore: number | null;
  claimed: number;
  completed: number;
  retryPending: number;
  failed: number;
  databaseFailure: boolean;
}

export async function completePendingAccountDeletions(
  maintenance: LifecycleMaintenance, deleteUser: AccountDeleter | undefined,
  options: AccountDeletionWorkerOptions,
): Promise<AccountDeletionWorkerReport> {
  if (!record(options) || typeof options.apply !== 'boolean' || !Number.isInteger(options.limit)
    || options.limit < 1 || options.limit > 5 || (options.apply && typeof deleteUser !== 'function')) {
    throw new TypeError('Invalid account-deletion worker options.');
  }
  const { apply, limit } = options;
  const report: AccountDeletionWorkerReport = { mode: apply ? 'apply' : 'dry_run', pendingBefore: null,
    claimed: 0, completed: 0, retryPending: 0, failed: 0, databaseFailure: false };
  try {
    const count = await maintenance.pendingAuthDeletionCount();
    if (!Number.isSafeInteger(count) || count < 0) throw new Error();
    report.pendingBefore = count;
  } catch { report.databaseFailure = true; return report; }
  if (!apply) return report;

  const seen = new Set<string>();
  for (let index = 0; index < limit; index++) {
    let job: AuthDeletionJob;
    try {
      const jobs: unknown = await maintenance.claimAuthDeletionJobs(1);
      if (!Array.isArray(jobs) || jobs.length > 1) throw new Error();
      if (jobs.length === 0) break;
      const value: unknown = jobs[0];
      if (!record(value) || Object.keys(value).length !== 3) throw new Error();
      const { jobId, userId, leaseToken } = value;
      if (!uuid(jobId) || !uuid(userId) || !uuid(leaseToken) || seen.has(jobId)) throw new Error();
      job = { jobId, userId, leaseToken };
      seen.add(job.jobId); report.claimed++;
    } catch { report.databaseFailure = true; break; }
    let outcome: 'deleted' | 'retry' = 'retry';
    try {
      const result: unknown = await deleteUser!(job.userId);
      if (!record(result) || Object.keys(result).length !== 1
        || !['deleted', 'already_absent'].includes(result.status as string)) throw new Error();
      outcome = 'deleted';
    } catch {   }
    try {
      const finished = await maintenance.finishAuthDeletionJob({ jobId: job.jobId, leaseToken: job.leaseToken, outcome });
      if (finished !== true) throw new Error();
      if (outcome === 'deleted') report.completed++;
      else { report.retryPending++; report.failed++; }
    } catch { report.failed++; report.databaseFailure = true; break; }
  }
  return report;
}
