import { matchPrograms } from '../matcher.ts';
import type { CaseSnapshot, MatchResponse, ProgramDefinition } from '../types.ts';

export interface MatchCaseRequest {
  schemaVersion: '1';
  caseId: string;
  expectedCaseRevision: number;
}

export interface MatchCaseInput {
  body: unknown;
  bearerToken: string | null;
}

export interface AuthenticatedUser {
  userId: string;
}

export interface MatchCaseRepository {
  loadForUser(userId: string, caseId: string): Promise<CaseSnapshot | null>;
  saveMatchIfCurrent(
    userId: string,
    caseId: string,
    revision: number,
    response: MatchResponse,
  ): Promise<'saved' | 'not_found' | 'conflict'>;
}

export interface MatchCaseDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: MatchCaseRepository;
  loadRegistry(): Promise<ProgramDefinition[]>;
  now(): Date;
  allowDemoPrograms?: boolean;
}

export type ApiErrorCode =
  | 'UNAUTHENTICATED'
  | 'INVALID_REQUEST'
  | 'CASE_NOT_FOUND'
  | 'CASE_REVISION_MISMATCH'
  | 'SERVICE_UNAVAILABLE'
  | 'INTERNAL_ERROR';

export interface ApiErrorResponse {
  schemaVersion: '1';
  error: { code: ApiErrorCode; message: string };
}

export interface MatchCaseResult {
  status: number;
  body: MatchResponse | ApiErrorResponse;
  headers?: Record<string, string>;
}

const errors: Record<ApiErrorCode, { status: number; message: string }> = {
  UNAUTHENTICATED: { status: 401, message: 'Sign in to request program matches.' },
  INVALID_REQUEST: { status: 400, message: 'Provide a v1 case ID and expected case revision.' },
  CASE_NOT_FOUND: { status: 404, message: 'The requested case is unavailable.' },
  CASE_REVISION_MISMATCH: { status: 409, message: 'The case changed. Reload it before requesting matches.' },
  SERVICE_UNAVAILABLE: { status: 503, message: 'Matching is temporarily unavailable. Try again later.' },
  INTERNAL_ERROR: { status: 500, message: 'Matching could not be completed.' },
};

function failure(code: ApiErrorCode): MatchCaseResult {
  return {
    status: errors[code].status,
    body: { schemaVersion: '1', error: { code, message: errors[code].message } },
    headers: {
      'Cache-Control': 'no-store',
      ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}),
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function validRequest(value: unknown): value is MatchCaseRequest {
  if (!isRecord(value)) return false;
  const allowed = ['schemaVersion', 'caseId', 'expectedCaseRevision'];
  return Object.keys(value).length === allowed.length
    && allowed.every(key => Object.hasOwn(value, key))
    && value.schemaVersion === '1'
    && typeof value.caseId === 'string' && value.caseId.trim().length > 0 && [...value.caseId].length <= 200
    && Number.isSafeInteger(value.expectedCaseRevision) && Number(value.expectedCaseRevision) >= 1;
}

function serverContext(deps: MatchCaseDependencies) {
  const now = deps.now();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new Error('Invalid server clock.');
  const evaluatedAt = now.toISOString();
  return { evaluatedAt, evaluationDate: evaluatedAt.slice(0, 10) };
}

async function processMatchCase(input: MatchCaseInput, deps: MatchCaseDependencies): Promise<MatchCaseResult> {
  const token = input.bearerToken;
  if (typeof token !== 'string' || token.length === 0 || /\s/.test(token)) return failure('UNAUTHENTICATED');

  let user: AuthenticatedUser | null;
  try {
    user = await deps.authenticate(token);
  } catch {
    return failure('SERVICE_UNAVAILABLE');
  }
  if (user === null) return failure('UNAUTHENTICATED');
  if (!isRecord(user) || typeof user.userId !== 'string' || user.userId.trim().length === 0) return failure('INTERNAL_ERROR');
  const userId = user.userId;
  if (!validRequest(input.body)) return failure('INVALID_REQUEST');
  const request = structuredClone(input.body);

  let loaded: CaseSnapshot | null;
  try {
    loaded = await deps.cases.loadForUser(userId, request.caseId);
  } catch {
    return failure('SERVICE_UNAVAILABLE');
  }
  if (loaded === null) return failure('CASE_NOT_FOUND');

  const snapshot = structuredClone(loaded);
  matchPrograms(snapshot, [], serverContext(deps));
  if (snapshot.caseId !== request.caseId) return failure('INTERNAL_ERROR');
  if (snapshot.revision !== request.expectedCaseRevision) return failure('CASE_REVISION_MISMATCH');

  let registry: ProgramDefinition[];
  try {
    registry = await deps.loadRegistry();
  } catch {
    return failure('SERVICE_UNAVAILABLE');
  }
  const response = matchPrograms(snapshot, registry, serverContext(deps));
  if (deps.allowDemoPrograms !== true && response.matches.some(match => match.isDemo)) return failure('INTERNAL_ERROR');

  let saved: 'saved' | 'not_found' | 'conflict';
  try {
    saved = await deps.cases.saveMatchIfCurrent(userId, request.caseId, snapshot.revision, response);
  } catch {
    return failure('SERVICE_UNAVAILABLE');
  }
  if (saved === 'not_found') return failure('CASE_NOT_FOUND');
  if (saved === 'conflict') return failure('CASE_REVISION_MISMATCH');
  if (saved !== 'saved') return failure('INTERNAL_ERROR');
  return { status: 200, body: response, headers: { 'Cache-Control': 'no-store' } };
}

export async function handleMatchCase(input: MatchCaseInput, deps: MatchCaseDependencies): Promise<MatchCaseResult> {
  try {
    return await processMatchCase(input, deps);
  } catch {
    return failure('INTERNAL_ERROR');
  }
}
