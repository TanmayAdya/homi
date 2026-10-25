import { createSupabaseAuthenticator, type SupabaseAuthConfig } from './supabase-auth.ts';
import { RecentAuthenticationRequiredError } from '../lifecycle/types.ts';

const MAX_AUTH_AGE_SECONDS = 600;
const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

export function createRecentSupabaseAuthenticator(
  config: SupabaseAuthConfig, fetchImpl: typeof fetch = globalThis.fetch,
  now: () => number = Date.now,
) {
  const authenticate = createSupabaseAuthenticator(config, fetchImpl);
  const issuer = `${new URL(config.projectUrl).origin}/auth/v1`;
  if (typeof now !== 'function') throw new TypeError('Invalid authentication clock.');
  return async (token: string) => {
    const user = await authenticate(token);
    if (user === null) return null;
    try {
      const segments = token.split('.');
      if (segments.length !== 3 || !segments.every(part => /^[A-Za-z0-9_-]+$/.test(part))) throw new Error();
      const bytes = Buffer.from(segments[1], 'base64url');
      if (bytes.toString('base64url') !== segments[1]) throw new Error();
      const claims: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      const seconds = Math.floor(now() / 1000);
      if (!Number.isSafeInteger(seconds) || !isObject(claims) || claims.sub !== user.userId
        || claims.iss !== issuer || claims.aud !== 'authenticated' || claims.role !== 'authenticated'
        || !Number.isSafeInteger(claims.exp) || (claims.exp as number) <= seconds
        || !Array.isArray(claims.amr) || claims.amr.length > 16
        || !claims.amr.some(method => isObject(method) && typeof method.method === 'string' && ['password', 'totp'].includes(method.method)
          && typeof method.timestamp === 'number' && Number.isSafeInteger(method.timestamp) && method.timestamp >= seconds - MAX_AUTH_AGE_SECONDS
          && method.timestamp <= seconds + 30)) throw new Error();
      return user;
    } catch { throw new RecentAuthenticationRequiredError(); }
  };
}
