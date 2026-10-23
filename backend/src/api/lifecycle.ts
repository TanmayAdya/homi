import { createHash, randomBytes } from 'node:crypto';
import type { AuthenticatedUser } from './match-case.ts';
import { evidenceIdentifier, evidenceInstant, evidenceRevision } from '../evidence/validation.ts';
import { AccountClosedError, RecentAuthenticationRequiredError,
  type AccountDeletionState, type DeletionCounts, type LifecycleRepository } from '../lifecycle/types.ts';

export interface LifecycleDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  authenticateForDeletion(token: string): Promise<AuthenticatedUser | null>;
  lifecycle: LifecycleRepository;
}

export type LifecycleRoute = 'delete-case' | 'prepare-account-deletion'
  | 'confirm-account-deletion' | 'account-deletion-status';
export type LifecycleErrorCode = 'UNAUTHENTICATED' | 'INVALID_REQUEST' | 'CASE_NOT_FOUND'
  | 'CASE_REVISION_MISMATCH' | 'EVIDENCE_CONFLICT' | 'RECENT_AUTHENTICATION_REQUIRED'
  | 'ACCOUNT_CLOSED' | 'DELETION_NOT_FOUND' | 'DELETION_EXPIRED' | 'DELETION_CHANGED'
  | 'SERVICE_UNAVAILABLE' | 'INTERNAL_ERROR';

type LifecycleBody = { schemaVersion: '1'; caseId: string; deleted: true }
  | { schemaVersion: '1'; deletionToken: string; expiresAt: string; counts: DeletionCounts }
  | ({ schemaVersion: '1' } & AccountDeletionState)
  | { schemaVersion: '1'; error: { code: LifecycleErrorCode; message: string } };
export interface LifecycleResponse {
  status: number;
  body: LifecycleBody;
  headers: Record<string, string>;
}
interface LifecycleInput { body: unknown; bearerToken: string | null }
type DeletionRequest = { caseId: string; revision: number; expectedCatalogRevision: number }
  | { deletionToken: string } | { schemaVersion: '1' };

const errors: Record<LifecycleErrorCode, [number, string]> = {
  UNAUTHENTICATED: [401, 'Provide valid authentication for this request.'],
  INVALID_REQUEST: [400, 'Provide the exact v1 deletion request and required confirmation.'],
  CASE_NOT_FOUND: [404, 'The requested case is unavailable.'],
  CASE_REVISION_MISMATCH: [409, 'The case changed. Reload it and review deletion again.'],
  EVIDENCE_CONFLICT: [409, 'The evidence changed. Reload it and review deletion again.'],
  RECENT_AUTHENTICATION_REQUIRED: [403, 'Sign in again before preparing or confirming account deletion.'],
  ACCOUNT_CLOSED: [409, 'This application account is closed. Use the retained deletion receipt to check its status.'],
  DELETION_NOT_FOUND: [404, 'This deletion receipt is unavailable.'],
  DELETION_EXPIRED: [410, 'The deletion confirmation expired. Prepare and review a new confirmation.'],
  DELETION_CHANGED: [409, 'The account data changed. Prepare and review a new confirmation.'],
  SERVICE_UNAVAILABLE: [503, 'Deletion could not be confirmed. Check the retained receipt before deciding whether to retry.'],
  INTERNAL_ERROR: [500, 'The deletion result could not be confirmed. Check its status before deciding whether to retry.'],
};

function failure(code: LifecycleErrorCode): LifecycleResponse {
  const [status, message] = errors[code];
  return { status, body: { schemaVersion: '1', error: { code, message } }, headers: {
    'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}),
  } };
}

function object(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
function receipt(value: unknown): value is string {
  return typeof value === 'string' && value.length === 64 && !/[^a-f0-9]/.test(value);
}
function bearer(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 4096
    && !/\s/.test(value) && /^[A-Za-z0-9._~+\/-]+=*$/.test(value);
}
function hash(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

function parse(body: unknown, route: LifecycleRoute): DeletionRequest | null {
  if (route === 'delete-case') {
    if (!object(body, ['schemaVersion', 'caseId', 'expectedCaseRevision', 'expectedCatalogRevision', 'confirmation'])
      || body.schemaVersion !== '1' || !evidenceIdentifier(body.caseId)
      || !evidenceRevision(body.expectedCaseRevision) || !evidenceRevision(body.expectedCatalogRevision, true)
      || body.confirmation !== 'DELETE_CASE') return null;
    return { caseId: body.caseId, revision: body.expectedCaseRevision, expectedCatalogRevision: body.expectedCatalogRevision };
  }
  if (route === 'confirm-account-deletion') {
    if (!object(body, ['schemaVersion', 'deletionToken', 'confirmation']) || body.schemaVersion !== '1'
      || !receipt(body.deletionToken) || body.confirmation !== 'DELETE_ACCOUNT') return null;
    return { deletionToken: body.deletionToken };
  }
  return object(body, ['schemaVersion']) && body.schemaVersion === '1' ? { schemaVersion: '1' } : null;
}

function state(value: unknown): AccountDeletionState | null {
  if (!object(value, ['status', 'applicationDataDeleted', 'providerIdentityDeleted'])) return null;
  const expected = value.status === 'awaiting_confirmation' ? [false, false]
    : value.status === 'auth_pending' ? [true, false] : value.status === 'complete' ? [true, true] : null;
  if (expected === null || value.applicationDataDeleted !== expected[0] || value.providerIdentityDeleted !== expected[1]) return null;
  return { status: value.status as AccountDeletionState['status'], applicationDataDeleted: expected[0], providerIdentityDeleted: expected[1] };
}
function counts(value: unknown): DeletionCounts | null {
  if (!object(value, ['cases', 'evidence', 'exports', 'storedBytes'])
    || !Object.values(value).every(item => evidenceRevision(item, true))) return null;
  return { cases: value.cases as number, evidence: value.evidence as number,
    exports: value.exports as number, storedBytes: value.storedBytes as number };
}
function success(body: LifecycleBody, status = 200): LifecycleResponse {
  return { status, body, headers: { 'Cache-Control': 'no-store' } };
}
function operationalFailure(error: unknown): LifecycleResponse {
  return failure(error instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE');
}

async function processLifecycle(input: LifecycleInput, deps: LifecycleDependencies, route: LifecycleRoute): Promise<LifecycleResponse> {
  const token = input.bearerToken;
  if (typeof token !== 'string' || !(route === 'account-deletion-status' ? receipt(token) : bearer(token))) return failure('UNAUTHENTICATED');
  const parsed = parse(input.body, route);
  if (route === 'account-deletion-status') {
    if (parsed === null) return failure('INVALID_REQUEST');
    let saved: unknown;
    try { saved = await deps.lifecycle.readAccountDeletionReceipt(hash(token)); }
    catch (error) { return operationalFailure(error); }
    if (saved === null) return failure('DELETION_NOT_FOUND');
    const deletion = state(saved);
    return deletion === null ? failure('INTERNAL_ERROR') : success({ schemaVersion: '1', ...deletion });
  }

  let user: AuthenticatedUser | null;
  try {
    user = route === 'delete-case' ? await deps.authenticate(token) : await deps.authenticateForDeletion(token);
  } catch (error) {
    return error instanceof RecentAuthenticationRequiredError ? failure('RECENT_AUTHENTICATION_REQUIRED') : operationalFailure(error);
  }
  if (user === null) return failure('UNAUTHENTICATED');
  if (!object(user, ['userId']) || !evidenceIdentifier(user.userId)) return failure('INTERNAL_ERROR');
  const userId = user.userId;
  if (parsed === null) return failure('INVALID_REQUEST');

  if (route === 'delete-case') {
    if (!('caseId' in parsed)) return failure('INTERNAL_ERROR');
    let result: unknown;
    try { result = await deps.lifecycle.deleteCaseIfCurrent({ userId, ...parsed }); }
    catch (error) { return operationalFailure(error); }
    if (!object(result, ['status'])) return failure('INTERNAL_ERROR');
    if (result.status === 'deleted') return success({ schemaVersion: '1', caseId: parsed.caseId, deleted: true });
    return failure(result.status === 'not_found' ? 'CASE_NOT_FOUND' : result.status === 'conflict' ? 'CASE_REVISION_MISMATCH'
      : result.status === 'evidence_conflict' ? 'EVIDENCE_CONFLICT' : result.status === 'invalid_input' ? 'INVALID_REQUEST' : 'INTERNAL_ERROR');
  }

  if (route === 'prepare-account-deletion') {
    const deletionToken = randomBytes(32).toString('hex');
    let result: unknown;
    try { result = await deps.lifecycle.prepareAccountDeletion({ userId, tokenHash: hash(deletionToken) }); }
    catch (error) { return operationalFailure(error); }
    if (object(result, ['status'])) return failure(result.status === 'closed' ? 'ACCOUNT_CLOSED'
      : result.status === 'invalid_input' ? 'INVALID_REQUEST' : 'INTERNAL_ERROR');
    if (!object(result, ['status', 'counts', 'expiresAt']) || result.status !== 'ready' || !evidenceInstant(result.expiresAt)) {
      return failure('INTERNAL_ERROR');
    }
    const summary = counts(result.counts);
    return summary === null ? failure('INTERNAL_ERROR')
      : success({ schemaVersion: '1', deletionToken, expiresAt: result.expiresAt, counts: summary });
  }

  if (!('deletionToken' in parsed)) return failure('INTERNAL_ERROR');
  let result: unknown;
  try { result = await deps.lifecycle.confirmAccountDeletion({ userId, tokenHash: hash(parsed.deletionToken) }); }
  catch (error) { return operationalFailure(error); }
  if (object(result, ['status'])) return failure(result.status === 'not_found' ? 'DELETION_NOT_FOUND'
    : result.status === 'expired' ? 'DELETION_EXPIRED' : result.status === 'changed' ? 'DELETION_CHANGED'
      : result.status === 'invalid_input' ? 'INVALID_REQUEST' : 'INTERNAL_ERROR');
  if (!object(result, ['status', 'deletion']) || result.status !== 'confirmed') return failure('INTERNAL_ERROR');
  const deletion = state(result.deletion);
  if (deletion === null || deletion.status === 'awaiting_confirmation') return failure('INTERNAL_ERROR');
  return success({ schemaVersion: '1', ...deletion }, deletion.status === 'auth_pending' ? 202 : 200);
}

async function handle(input: LifecycleInput, deps: LifecycleDependencies, route: LifecycleRoute): Promise<LifecycleResponse> {
  try { return await processLifecycle(input, deps, route); } catch { return failure('INTERNAL_ERROR'); }
}
export function handleDeleteCase(input: LifecycleInput, deps: LifecycleDependencies): Promise<LifecycleResponse> {
  return handle(input, deps, 'delete-case');
}
export function handlePrepareAccountDeletion(input: LifecycleInput, deps: LifecycleDependencies): Promise<LifecycleResponse> {
  return handle(input, deps, 'prepare-account-deletion');
}
export function handleConfirmAccountDeletion(input: LifecycleInput, deps: LifecycleDependencies): Promise<LifecycleResponse> {
  return handle(input, deps, 'confirm-account-deletion');
}
export function handleAccountDeletionStatus(input: LifecycleInput, deps: LifecycleDependencies): Promise<LifecycleResponse> {
  return handle(input, deps, 'account-deletion-status');
}
