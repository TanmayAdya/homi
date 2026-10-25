import { matchPrograms } from '../matcher.ts';
import type { CaseSnapshot } from '../types.ts';
import type { AuthenticatedUser, MatchCaseRepository } from './match-case.ts';

export interface ReadCaseRequest { schemaVersion: '1'; caseId: string }

export interface ReadCaseDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: Pick<MatchCaseRepository, 'loadForUser'>;
  now(): Date;
}

export type ReadCaseErrorCode = 'UNAUTHENTICATED' | 'INVALID_REQUEST' | 'CASE_NOT_FOUND' | 'SERVICE_UNAVAILABLE' | 'INTERNAL_ERROR';
export interface ReadCaseResult {
  status: number;
  body: CaseSnapshot | { schemaVersion: '1'; error: { code: ReadCaseErrorCode; message: string } };
  headers: Record<string, string>;
}

const errors: Record<ReadCaseErrorCode, { status: number; message: string }> = {
  UNAUTHENTICATED: { status: 401, message: 'Sign in to reload the saved case.' },
  INVALID_REQUEST: { status: 400, message: 'Provide a v1 case ID without additional fields.' },
  CASE_NOT_FOUND: { status: 404, message: 'The requested case is unavailable.' },
  SERVICE_UNAVAILABLE: { status: 503, message: 'Case loading is temporarily unavailable. Try again later.' },
  INTERNAL_ERROR: { status: 500, message: 'The saved case could not be loaded.' },
};

function failure(code: ReadCaseErrorCode): ReadCaseResult {
  return { status: errors[code].status, body: { schemaVersion: '1', error: { code, message: errors[code].message } },
    headers: { 'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}) } };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function identifier(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value === value.trim() && [...value].length <= 200
    && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(value) && !/[\uD800-\uDFFF]/u.test(value);
}

async function processReadCase(input: { body: unknown; bearerToken: string | null }, deps: ReadCaseDependencies): Promise<ReadCaseResult> {
  const token = input.bearerToken;
  if (typeof token !== 'string' || token.length === 0 || /\s/.test(token)) return failure('UNAUTHENTICATED');
  let user: AuthenticatedUser | null;
  try { user = await deps.authenticate(token); } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (user === null) return failure('UNAUTHENTICATED');
  if (!isRecord(user) || !identifier(user.userId)) return failure('INTERNAL_ERROR');
  const userId = user.userId;
  const body = input.body;
  if (!isRecord(body) || Object.keys(body).length !== 2 || !Object.hasOwn(body, 'schemaVersion')
    || !Object.hasOwn(body, 'caseId') || body.schemaVersion !== '1' || !identifier(body.caseId)) {
    return failure('INVALID_REQUEST');
  }
  const caseId = body.caseId;
  let loaded: CaseSnapshot | null;
  try { loaded = await deps.cases.loadForUser(userId, caseId); } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (loaded === null) return failure('CASE_NOT_FOUND');
  const snapshot = structuredClone(loaded);
  const now = deps.now();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new Error('Invalid server clock.');
  const evaluatedAt = now.toISOString();
  matchPrograms(snapshot, [], { evaluatedAt, evaluationDate: evaluatedAt.slice(0, 10) });
  if (snapshot.caseId !== caseId) return failure('INTERNAL_ERROR');
  return { status: 200, body: snapshot, headers: { 'Cache-Control': 'no-store' } };
}

export async function handleReadCase(
  input: { body: unknown; bearerToken: string | null }, deps: ReadCaseDependencies,
): Promise<ReadCaseResult> {
  try { return await processReadCase(input, deps); } catch { return failure('INTERNAL_ERROR'); }
}
