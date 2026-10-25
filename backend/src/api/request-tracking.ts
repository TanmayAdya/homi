import type { AuthenticatedUser } from './match-case.ts';
import type { ProgramDefinition } from '../types.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import { AccountClosedError } from '../lifecycle/types.ts';
import { parseRequestTrackingRequest, parseRequestHistory, requestInstant, sameRequestUpdate,
  type AppendRequestUpdateRequest, type ReadRequestHistoryRequest, type RequestHistory,
  type RequestHistoryRepository, type RequestHistoryResult } from '../requests/tracking.ts';

export interface RequestTrackingDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: RequestHistoryRepository;
  loadRegistry(): Promise<ProgramDefinition[]>;
  now(): Date;
  allowDemoPrograms?: boolean;
}
export type RequestTrackingErrorCode = 'UNAUTHENTICATED' | 'INVALID_REQUEST' | 'CASE_NOT_FOUND'
  | 'CASE_REVISION_MISMATCH' | 'PROGRAM_NOT_FOUND' | 'REQUEST_REVISION_MISMATCH' | 'REQUEST_UPDATE_CONFLICT'
  | 'REQUEST_HISTORY_FULL' | 'SERVICE_UNAVAILABLE' | 'INTERNAL_ERROR';
export interface RequestTrackingResult {
  status: number; body: RequestHistory | { schemaVersion: '1'; error: { code: RequestTrackingErrorCode; message: string } };
  headers: Record<string, string>;
}
const errors: Record<RequestTrackingErrorCode, [number, string]> = {
  UNAUTHENTICATED: [401, 'Sign in to review reported application updates.'],
  INVALID_REQUEST: [400, 'Provide a valid request-history operation with only supported fields.'],
  CASE_NOT_FOUND: [404, 'The requested case is unavailable.'],
  CASE_REVISION_MISMATCH: [409, 'The case changed. Reload it before reviewing request history.'],
  PROGRAM_NOT_FOUND: [404, 'Updates are unavailable for this program.'],
  REQUEST_REVISION_MISMATCH: [409, 'Request history changed. Reload it and review your pending update.'],
  REQUEST_UPDATE_CONFLICT: [409, 'This update identifier was already used for a different request.'],
  REQUEST_HISTORY_FULL: [409, 'The development request-history limit has been reached. Existing history is retained.'],
  SERVICE_UNAVAILABLE: [503, 'Request history is temporarily unavailable. Try again later.'],
  INTERNAL_ERROR: [500, 'The request-history operation could not be completed.'],
};
function fail(code: RequestTrackingErrorCode): RequestTrackingResult {
  return { status: errors[code][0], body: { schemaVersion: '1', error: { code, message: errors[code][1] } },
    headers: { 'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}) } };
}
function unavailable(error: unknown): RequestTrackingResult { return fail(error instanceof AccountClosedError ? 'UNAUTHENTICATED' : 'SERVICE_UNAVAILABLE'); }
function resultHistory(result: RequestHistoryResult, request: ReadRequestHistoryRequest): RequestHistory | RequestTrackingResult {
  const codes = { not_found: 'CASE_NOT_FOUND', conflict: 'CASE_REVISION_MISMATCH', request_conflict: 'REQUEST_REVISION_MISMATCH',
    update_conflict: 'REQUEST_UPDATE_CONFLICT', quota_exceeded: 'REQUEST_HISTORY_FULL' } as const;
  if (result.status !== 'found') return fail(codes[result.status] ?? 'INTERNAL_ERROR');
  const history = parseRequestHistory(structuredClone(result.history));
  if (history.caseId !== request.caseId || history.caseRevision !== request.expectedCaseRevision || history.programId !== request.programId) {
    throw new Error('Mismatched request history.');
  }
  return history;
}
async function processRequest(input: { body: unknown; bearerToken: string | null }, deps: RequestTrackingDependencies, append: boolean): Promise<RequestTrackingResult> {
  const token = input.bearerToken;
  if (typeof token !== 'string' || token.length === 0 || token.length > 4096
    || !/^[A-Za-z0-9\-._~+/]+=*$/.test(token)) return fail('UNAUTHENTICATED');
  let request: ReadRequestHistoryRequest | AppendRequestUpdateRequest | null = null;
  try { request = parseRequestTrackingRequest(input.body, append); } catch {   }
  let user: AuthenticatedUser | null;
  try { user = await deps.authenticate(token); } catch (error) { return unavailable(error); }
  if (user === null) return fail('UNAUTHENTICATED');
  if (!user || !evidenceIdentifier(user.userId)) return fail('INTERNAL_ERROR');
  const userId = user.userId;
  if (!request) return fail('INVALID_REQUEST');
  const binding = { userId, caseId: request.caseId, revision: request.expectedCaseRevision, programId: request.programId };
  let read: RequestHistoryResult;
  try { read = await deps.cases.readRequestHistoryForUser({ ...binding }); } catch (error) { return unavailable(error); }
  const initial = resultHistory(read, request);
  if (!('events' in initial)) return initial;
  if (!append) return { status: 200, body: initial, headers: { 'Cache-Control': 'no-store' } };
  const pending = request as AppendRequestUpdateRequest;
  let registry: ProgramDefinition[];
  try { registry = structuredClone(await deps.loadRegistry()); } catch (error) { return unavailable(error); }
  if (!Array.isArray(registry) || registry.length > 64 || registry.some(program => !program || !evidenceIdentifier(program.programId)
    || typeof program.isDemo !== 'boolean') || new Set(registry.map(program => program.programId)).size !== registry.length) {
    return fail('INTERNAL_ERROR');
  }
  const program = registry.find(program => program.programId === request.programId);
  if (!program || (program.isDemo && deps.allowDemoPrograms !== true)) return fail('PROGRAM_NOT_FOUND');
  const now = deps.now();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) return fail('INTERNAL_ERROR');
  const recordedAt = now.toISOString();
  if (!requestInstant(recordedAt)) return fail('INTERNAL_ERROR');
  if (pending.update.occurredOn > recordedAt.slice(0, 10)) return fail('INVALID_REQUEST');
  let written: RequestHistoryResult;
  try { written = await deps.cases.appendRequestUpdateForUser({ ...binding,
    expectedRequestRevision: pending.expectedRequestRevision, update: structuredClone(pending.update), recordedAt }); }
  catch (error) { return unavailable(error); }
  const history = resultHistory(written, request);
  if (!('events' in history)) return history;
  const acknowledgement = history.events[pending.expectedRequestRevision];
  if (!acknowledgement || acknowledgement.caseRevision !== pending.expectedCaseRevision || !sameRequestUpdate(acknowledgement, pending.update)) {
    return fail('INTERNAL_ERROR');
  }
  return { status: 200, body: history, headers: { 'Cache-Control': 'no-store' } };
}
export async function handleReadRequestHistory(input: { body: unknown; bearerToken: string | null }, deps: RequestTrackingDependencies): Promise<RequestTrackingResult> {
  try { return await processRequest(input, deps, false); } catch { return fail('INTERNAL_ERROR'); }
}
export async function handleAppendRequestUpdate(input: { body: unknown; bearerToken: string | null }, deps: RequestTrackingDependencies): Promise<RequestTrackingResult> {
  try { return await processRequest(input, deps, true); } catch { return fail('INTERNAL_ERROR'); }
}
