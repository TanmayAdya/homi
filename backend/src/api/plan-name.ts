import type { AuthenticatedUser } from './match-case.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import { AccountClosedError } from '../lifecycle/types.ts';
import type { CaseListQuery } from '../cases/discovery.ts';
import { parseReadPlanNameRequest, parseSavePlanNameRequest, parsePlanNameState, parseNamedCaseListRequest,
  parseNamedCaseListPage, type PlanNameRepository, type PlanNameState, type NamedCaseListPage,
  type ReadPlanNameRequest, type SavePlanNameRequest } from '../cases/plan-name.ts';

export interface PlanNameDependencies { authenticate(token: string): Promise<AuthenticatedUser | null>; cases: PlanNameRepository }
export type PlanNameRoute = 'read-plan-name' | 'save-plan-name' | 'list-cases';
export type PlanNameResult = { status: number; headers: Record<string, string>; body: PlanNameState
  | ({ schemaVersion: '2' } & NamedCaseListPage) | { schemaVersion: '2'; error: { code: string; message: string } } };
const errors: Record<string, [number, string]> = {
  UNAUTHENTICATED: [401, 'Sign in to find or name saved plans.'],
  INVALID_REQUEST: [400, 'Provide a valid plan name request without additional fields.'],
  ACCOUNT_CLOSED: [409, 'This account is closed.'], CASE_NOT_FOUND: [404, 'The requested plan is unavailable.'],
  PLAN_NAME_CONFLICT: [409, 'The plan name changed. Reload and reconcile before saving.'],
  SERVICE_UNAVAILABLE: [503, 'Plan names are temporarily unavailable. Try again later.'],
  INTERNAL_ERROR: [500, 'The plan name result could not be confirmed.'],
};
function failure(code: string): PlanNameResult {
  const [status, message] = errors[code];
  return { status, body: { schemaVersion: '2', error: { code, message } },
    headers: { 'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}) } };
}
const success = (body: PlanNameResult['body']): PlanNameResult => ({ status: 200, body, headers: { 'Cache-Control': 'no-store' } });

export async function handlePlanName(input: { body: unknown; bearerToken: string | null },
  deps: PlanNameDependencies, route: PlanNameRoute): Promise<PlanNameResult> {
  try {
    const token = input.bearerToken;
    if (typeof token !== 'string' || token.length > 4096 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(token)) return failure('UNAUTHENTICATED');
    let request: ReadPlanNameRequest | SavePlanNameRequest | CaseListQuery | null = null;
    try { request = route === 'list-cases' ? parseNamedCaseListRequest(input.body)
      : route === 'save-plan-name' ? parseSavePlanNameRequest(input.body) : parseReadPlanNameRequest(input.body); } catch {   }
    let user: AuthenticatedUser | null;
    try { user = await deps.authenticate(token); }
    catch (e) { return failure(e instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
    if (user === null) return failure('UNAUTHENTICATED');
    if (!user || !evidenceIdentifier(user.userId)) return failure('INTERNAL_ERROR');
    const userId = user.userId;
    if (request === null) return failure('INVALID_REQUEST');
    if (route === 'list-cases') {
      const query = request as CaseListQuery;
      let loaded: NamedCaseListPage;
      try { loaded = await deps.cases.listNamedForUser(userId, { ...query }); }
      catch (e) { return failure(e instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
      return success({ schemaVersion: '2', ...parseNamedCaseListPage(loaded, query) });
    }
    const caseId = (request as ReadPlanNameRequest).caseId;
    let loaded: PlanNameState | null;
    if (route === 'save-plan-name') {
      const savedRequest = request as SavePlanNameRequest;
      let result;
      try { result = await deps.cases.savePlanNameForUser(userId, { ...savedRequest }); }
      catch (e) { return failure(e instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
      if (result.status === 'not_found') return failure('CASE_NOT_FOUND');
      if (result.status === 'conflict') return failure('PLAN_NAME_CONFLICT');
      if (result.status !== 'saved') return failure('INTERNAL_ERROR');
      loaded = parsePlanNameState(result.state, { allowDefault: false });
      if (loaded.name !== savedRequest.name || loaded.nameRevision !== savedRequest.expectedNameRevision + 1
        || loaded.lastMutationId !== savedRequest.mutationId) return failure('INTERNAL_ERROR');
    } else {
      try { loaded = await deps.cases.readPlanNameForUser(userId, caseId); }
      catch (e) { return failure(e instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
      if (loaded === null) return failure('CASE_NOT_FOUND');
      loaded = parsePlanNameState(loaded);
    }
    if (loaded.caseId !== caseId) return failure('INTERNAL_ERROR');
    return success(loaded);
  } catch { return failure('INTERNAL_ERROR'); }
}
