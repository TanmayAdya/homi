import type { AuthenticatedUser } from './match-case.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import { AccountClosedError } from '../lifecycle/types.ts';
import { parseCaseListPage, parseListCasesRequest,
  type CaseListPage, type CaseListQuery, type CaseListRepository } from '../cases/discovery.ts';

export interface ListCasesDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: CaseListRepository;
}
export type ListCasesErrorCode = 'UNAUTHENTICATED' | 'INVALID_REQUEST' | 'SERVICE_UNAVAILABLE' | 'INTERNAL_ERROR';
export interface ListCasesResult {
  status: number;
  body: ({ schemaVersion: '1' } & CaseListPage)
    | { schemaVersion: '1'; error: { code: ListCasesErrorCode; message: string } };
  headers: Record<string, string>;
}
const errors: Record<ListCasesErrorCode, { status: number; message: string }> = {
  UNAUTHENTICATED: { status: 401, message: 'Sign in to find saved cases.' },
  INVALID_REQUEST: { status: 400, message: 'Provide a v1 list limit and case boundary without additional fields.' },
  SERVICE_UNAVAILABLE: { status: 503, message: 'Case listing is temporarily unavailable. Try again later.' },
  INTERNAL_ERROR: { status: 500, message: 'The saved case list could not be loaded.' },
};
function failure(code: ListCasesErrorCode): ListCasesResult {
  return { status: errors[code].status, body: { schemaVersion: '1', error: { code, message: errors[code].message } },
    headers: { 'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}) } };
}
async function processListCases(input: { body: unknown; bearerToken: string | null }, deps: ListCasesDependencies): Promise<ListCasesResult> {
  const token = input.bearerToken;
  if (typeof token !== 'string' || token.length === 0 || /\s/.test(token)) return failure('UNAUTHENTICATED');
  let query: CaseListQuery | null = null;
  try { query = parseListCasesRequest(input.body); } catch {   }
  let user: AuthenticatedUser | null;
  try { user = await deps.authenticate(token); }
  catch (error) { return failure(error instanceof AccountClosedError ? 'UNAUTHENTICATED' : 'SERVICE_UNAVAILABLE'); }
  if (user === null) return failure('UNAUTHENTICATED');
  if (!user || !evidenceIdentifier(user.userId)) return failure('INTERNAL_ERROR');
  const userId = user.userId;
  if (query === null) return failure('INVALID_REQUEST');
  let loaded: CaseListPage;
  try { loaded = await deps.cases.listForUser(userId, { ...query }); }
  catch (error) { return failure(error instanceof AccountClosedError ? 'UNAUTHENTICATED' : 'SERVICE_UNAVAILABLE'); }
  const page = parseCaseListPage(structuredClone(loaded), query);
  return { status: 200, body: { schemaVersion: '1', ...page }, headers: { 'Cache-Control': 'no-store' } };
}

export async function handleListCases(
  input: { body: unknown; bearerToken: string | null }, deps: ListCasesDependencies,
): Promise<ListCasesResult> {
  try { return await processListCases(input, deps); } catch { return failure('INTERNAL_ERROR'); }
}
