import type { AuthenticatedUser } from '../api/match-case.ts';
import { invitationEmail } from './invitation-email.ts';

export interface SupabaseAuthConfig {
  projectUrl: string;
  publishableKey: string;
  timeoutMs?: number;
}

export const MAX_AUTH_RESPONSE_BYTES = 64 * 1024;

export class AuthServiceUnavailableError extends Error {
  constructor() {
    super('Authentication is temporarily unavailable.');
    this.name = 'AuthServiceUnavailableError';
  }
}

function configuration(input: SupabaseAuthConfig) {
  const fail = (): never => { throw new TypeError('Invalid Supabase authentication configuration.'); };
  if (input === null || typeof input !== 'object') return fail();
  const { projectUrl, publishableKey, timeoutMs = 5000 } = input;
  if (typeof projectUrl !== 'string' || projectUrl.length > 2048 || /\s/.test(projectUrl)
    || !/^https:\/\/[^@/?#\\\s]+\/?$/.test(projectUrl)) return fail();
  let parsed: URL;
  try { parsed = new URL(projectUrl); } catch { return fail(); }
  if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password
    || parsed.pathname !== '/' || parsed.search || parsed.hash) return fail();
  if (typeof publishableKey !== 'string' || !publishableKey.startsWith('sb_publishable_')
    || publishableKey.length <= 'sb_publishable_'.length || publishableKey.length > 512
    || /[^A-Za-z0-9_-]/.test(publishableKey)) return fail();
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 10_000) return fail();
  return { endpoint: `${parsed.origin}/auth/v1/user`, publishableKey, timeoutMs };
}

function validBearer(token: string): boolean {
  return typeof token === 'string' && token.length > 0 && token.length <= 4096
    && /^[A-Za-z0-9._~+/-]+=*$/.test(token) && !/\s/.test(token);
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function userFromResponse(value: unknown, requireConfirmedIdentity: boolean, includeVerifiedEmail: boolean): AuthenticatedUser | null {
  if (!record(value) || typeof value.id !== 'string'
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value.id)
    || value.id.length !== 36 || typeof value.role !== 'string') {
    throw new AuthServiceUnavailableError();
  }
  if (value.role !== 'authenticated') return null;
  if (requireConfirmedIdentity && (value.is_anonymous === true || ![value.email_confirmed_at, value.phone_confirmed_at].some(
    at => typeof at === 'string' && at.length > 0 && Number.isFinite(Date.parse(at))))) return null;
  const email = includeVerifiedEmail && value.is_anonymous !== true && typeof value.email_confirmed_at === 'string'
    && Number.isFinite(Date.parse(value.email_confirmed_at)) ? invitationEmail(value.email) : null;
  return Object.freeze({ userId: value.id, ...(email ? { verifiedEmail: email } : {}) });
}

export function createSupabaseAuthenticator(
  config: SupabaseAuthConfig,
  fetchImpl: typeof fetch = globalThis.fetch,
  requireConfirmedIdentity = false,
  includeVerifiedEmail = false,
): (token: string) => Promise<AuthenticatedUser | null> {
  const { endpoint, publishableKey, timeoutMs } = configuration(config);
  if (typeof fetchImpl !== 'function') throw new TypeError('Invalid authentication transport.');

  return async (token: string): Promise<AuthenticatedUser | null> => {
    if (!validBearer(token)) return null;
    const controller = new AbortController();
    const expiresAt = performance.now() + timeoutMs;
    let active = true;
    let body: ReadableStream<Uint8Array> | null = null;
    let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
    const cancelBody = () => {
      try {
        const cancellation = reader ? reader.cancel() : body?.cancel();
        void cancellation?.catch(() => {});
      } catch {   }
    };
    let timer: ReturnType<typeof setTimeout>;
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        active = false;
        controller.abort();
        cancelBody();
        reject(new AuthServiceUnavailableError());
      }, timeoutMs);
    });

    const request = async (): Promise<AuthenticatedUser | null> => {
      const response = await fetchImpl(endpoint, {
        method: 'GET',
        headers: { Accept: 'application/json', apikey: publishableKey, Authorization: `Bearer ${token}` },
        redirect: 'error',
        cache: 'no-store',
        signal: controller.signal,
      });
      body = response.body;
      if (!active || performance.now() >= expiresAt) {
        cancelBody();
        throw new AuthServiceUnavailableError();
      }
      if (response.redirected || (response.url !== '' && response.url !== endpoint)) {
        throw new AuthServiceUnavailableError();
      }
      if (response.status === 401 || response.status === 403) return null;
      if (response.status !== 200
        || response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() !== 'application/json'
        || body === null) throw new AuthServiceUnavailableError();
      const length = response.headers.get('content-length');
      if (length !== null && (!/^[0-9]+$/.test(length) || length.length > 10
        || Number(length) > MAX_AUTH_RESPONSE_BYTES)) throw new AuthServiceUnavailableError();

      const bytes = new Uint8Array(MAX_AUTH_RESPONSE_BYTES);
      let size = 0;
      reader = body.getReader();
      while (true) {
        const chunk = await reader.read();
        if (!active || performance.now() >= expiresAt) throw new AuthServiceUnavailableError();
        if (chunk.done) break;
        if (!(chunk.value instanceof Uint8Array)
          || chunk.value.byteLength > MAX_AUTH_RESPONSE_BYTES - size) {
          throw new AuthServiceUnavailableError();
        }
        bytes.set(chunk.value, size);
        size += chunk.value.byteLength;
      }
      const decoded: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, size)));
      return userFromResponse(decoded, requireConfirmedIdentity, includeVerifiedEmail);
    };

    try {
      return await Promise.race([request(), deadline]);
    } catch {
      throw new AuthServiceUnavailableError();
    } finally {
      active = false;
      clearTimeout(timer!);
      controller.abort();
      cancelBody();
    }
  };
}
