import { COLLABORATION_ROUTES } from '../sharing/collaboration.ts';
import { SENSITIVE_ROUTES, handleSensitiveSharing } from './sensitive-sharing.ts';
import type { SensitiveRoute } from '../sharing/sensitive.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import { randomBytes, createHash } from 'node:crypto';
import { AccountClosedError } from '../lifecycle/types.ts';
import { parseSharingRequest, type SharingRepository, type SharingRoute } from '../sharing/contracts.ts';
import type { AuthenticatedUser } from './match-case.ts';
export interface SharingDependencies { authenticate(token: string): Promise<AuthenticatedUser | null>;
  reauthenticate?(token: string): Promise<AuthenticatedUser | null>; sharing: SharingRepository; collaborationEnabled?: boolean; sensitiveEnabled?: boolean; simpleInvitationsEnabled?: boolean }
export async function handleSharing(input: { body: unknown; bearerToken: string | null }, deps: SharingDependencies, route: SharingRoute) {
  const fail = (status: number, code: string) => ({ status, body: { schemaVersion: '3', error: { code, message: 'Reopen sharing and check current access before trying again.' } }, headers: { 'Cache-Control': 'no-store' } });
  try {
    if (!input.bearerToken || input.bearerToken.length > 4096 || !/^[A-Za-z0-9._~+/-]+=*$/.test(input.bearerToken)) return fail(401, 'UNAUTHENTICATED');
    const user = await deps.authenticate(input.bearerToken);
    if (!user) return fail(401, 'UNAUTHENTICATED');
    if (!evidenceIdentifier(user.userId)) return fail(500, 'INTERNAL_ERROR');
    if (['create-email-invitation','list-email-sharing'].includes(route) && deps.simpleInvitationsEnabled !== true) return fail(404,'SHARING_NOT_FOUND');
    if ((SENSITIVE_ROUTES as readonly string[]).includes(route)) return await handleSensitiveSharing(input, deps, route as SensitiveRoute);
    if((COLLABORATION_ROUTES as readonly string[]).includes(route) && deps.collaborationEnabled!==true) return fail(404,'SHARING_NOT_FOUND');
    let request; try { request = parseSharingRequest(route, input.body); } catch { return fail(400, 'INVALID_REQUEST'); }
    if (route === 'create-email-invitation' && request.recipientEmail === user.verifiedEmail) return fail(400,'INVALID_REQUEST');
    const creating = ['create-invitation','create-email-invitation'].includes(route);
    const code = creating ? randomBytes(32).toString('base64url') : request.code;
    const tokenHash = code ? createHash('sha256').update(code).digest('hex') : undefined;
    const result = await deps.sharing.execute(user.userId, route, request, tokenHash,
      deps.simpleInvitationsEnabled === true ? user.verifiedEmail : undefined);
    if (result.status !== 'ok') return fail(result.status === 'not_found' ? 404 : result.status === 'conflict' ? 409 : result.status === 'quota_exceeded' ? 507 : 400,
      result.status === 'not_found' ? 'SHARING_NOT_FOUND' : result.status === 'conflict' ? 'SHARING_CONFLICT' : result.status === 'quota_exceeded' ? 'SHARING_LIMIT' : 'INVALID_REQUEST');
    return { status: 200, body: { schemaVersion: '3', ...result.data,
      ...(creating ? { invitationCode: result.data.created === true ? code : null } : {}) }, headers: { 'Cache-Control': 'no-store' } };
  } catch (error) { return fail(error instanceof AccountClosedError ? 409 : 503, error instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
}
