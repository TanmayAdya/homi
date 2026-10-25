import type { AuthenticatedUser } from './match-case.ts';
import type { CaseSnapshot } from '../types.ts';
import type { CaseDraft } from '../cases/types.ts';
import { parseCaseDraft, parseCaseSaveRequest, parseWrittenCase } from '../cases/validation.ts';
import type { CaseWriteRepository, CaseWriteResult as RepositoryResult } from '../cases/repository.ts';
import { canonicalJson, evidenceIdentifier } from '../evidence/validation.ts';

export interface CaseWriteDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: CaseWriteRepository;
}

export type CaseWriteErrorCode = 'UNAUTHENTICATED' | 'INVALID_REQUEST' | 'CASE_NOT_FOUND'
  | 'CASE_REVISION_MISMATCH' | 'CASE_ID_UNAVAILABLE' | 'EVIDENCE_CONFLICT'
  | 'STORAGE_LIMIT_REACHED' | 'SERVICE_UNAVAILABLE' | 'INTERNAL_ERROR';
export interface CaseWriteResponse {
  status: number;
  body: CaseSnapshot | { schemaVersion: '1'; error: { code: CaseWriteErrorCode; message: string } };
  headers: Record<string, string>;
}

const errors: Record<CaseWriteErrorCode, [number, string]> = {
  UNAUTHENTICATED: [401, 'Sign in to save a case.'],
  INVALID_REQUEST: [400, 'Provide a valid bounded v1 case without owner or revision overrides.'],
  CASE_NOT_FOUND: [404, 'The requested case is unavailable.'],
  CASE_REVISION_MISMATCH: [409, 'The saved case changed. Reload it before saving again.'],
  CASE_ID_UNAVAILABLE: [409, 'This case ID is unavailable. Reload your case or choose a new ID for a new case.'],
  EVIDENCE_CONFLICT: [409, 'Delete uploaded evidence before removing its link; an evidence ID cannot move to another finding.'],
  STORAGE_LIMIT_REACHED: [507, 'Private storage has reached its limit. Contact the app operator before retrying.'],
  SERVICE_UNAVAILABLE: [503, 'Case saving is temporarily unavailable. Reload the case before deciding whether to retry.'],
  INTERNAL_ERROR: [500, 'The case save could not be confirmed. Reload the case before saving again.'],
};

function failure(code: CaseWriteErrorCode): CaseWriteResponse {
  const [status, message] = errors[code];
  return { status, body: { schemaVersion: '1', error: { code, message } }, headers: {
    'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}),
  } };
}

function request(body: unknown, create: boolean): { draft: CaseDraft; expectedRevision: number | null } {
  if (create) return { draft: parseCaseDraft(body, true), expectedRevision: null };
  return parseCaseSaveRequest(body);
}

async function processWrite(
  input: { body: unknown; bearerToken: string | null }, deps: CaseWriteDependencies, create: boolean,
): Promise<CaseWriteResponse> {
  const token = input.bearerToken;
  if (typeof token !== 'string' || token.length < 1 || token.length > 4096 || /\s/.test(token)) return failure('UNAUTHENTICATED');
  let parsed: ReturnType<typeof request> | null = null;
  try { parsed = request(input.body, create); } catch {   }
  let user: AuthenticatedUser | null;
  try { user = await deps.authenticate(token); } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (user === null) return failure('UNAUTHENTICATED');
  if (typeof user !== 'object' || Array.isArray(user) || !evidenceIdentifier(user.userId)) return failure('INTERNAL_ERROR');
  const userId = user.userId;
  if (parsed === null) return failure('INVALID_REQUEST');
  const expected: CaseSnapshot = { ...parsed.draft, revision: create ? 1 : parsed.expectedRevision! + 1 };
  let result: RepositoryResult;
  try {
    result = create
      ? await deps.cases.createForUser(userId, structuredClone(parsed.draft))
      : await deps.cases.replaceIfCurrent(userId, parsed.draft.caseId, parsed.expectedRevision!, structuredClone(parsed.draft));
  } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (result.status !== 'saved') {
    const mapped = { not_found: 'CASE_NOT_FOUND', conflict: 'CASE_REVISION_MISMATCH', id_unavailable: 'CASE_ID_UNAVAILABLE',
      evidence_conflict: 'EVIDENCE_CONFLICT', quota_exceeded: 'STORAGE_LIMIT_REACHED', invalid_input: 'INVALID_REQUEST' } as const;
    return failure(mapped[result.status] ?? 'INTERNAL_ERROR');
  }
  const snapshot = parseWrittenCase(result.snapshot);
  if (canonicalJson(snapshot) !== canonicalJson(expected)) return failure('INTERNAL_ERROR');
  return { status: 200, body: snapshot, headers: { 'Cache-Control': 'no-store' } };
}

export async function handleCreateCase(input: { body: unknown; bearerToken: string | null }, deps: CaseWriteDependencies): Promise<CaseWriteResponse> {
  try { return await processWrite(input, deps, true); } catch { return failure('INTERNAL_ERROR'); }
}
export async function handleSaveCase(input: { body: unknown; bearerToken: string | null }, deps: CaseWriteDependencies): Promise<CaseWriteResponse> {
  try { return await processWrite(input, deps, false); } catch { return failure('INTERNAL_ERROR'); }
}
