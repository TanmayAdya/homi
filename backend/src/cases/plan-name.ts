import { evidenceIdentifier, evidenceRevision } from '../evidence/validation.ts';
import { compareCaseIds, parseCaseListQuery, type CaseListQuery } from './discovery.ts';

export interface PlanNameState {
  schemaVersion: '2'; caseId: string; name: string | null;
  nameRevision: number; lastMutationId: string | null;
}
export interface ReadPlanNameRequest { schemaVersion: '2'; caseId: string }
export interface SavePlanNameRequest extends ReadPlanNameRequest {
  expectedNameRevision: number; mutationId: string; name: string | null;
}
export interface NamedCaseSummary {
  caseId: string; caseRevision: number; name: string | null;
  nameRevision: number; lastMutationId: string | null;
}
export interface NamedCaseListPage { cases: NamedCaseSummary[]; nextAfterCaseId: string | null }
export type SavePlanNameResult = { status: 'saved'; state: PlanNameState } | { status: 'not_found' | 'conflict' };
export interface PlanNameRepository {
  readPlanNameForUser(userId: string, caseId: string): Promise<PlanNameState | null>;
  savePlanNameForUser(userId: string, request: SavePlanNameRequest): Promise<SavePlanNameResult>;
  listNamedForUser(userId: string, query: CaseListQuery): Promise<NamedCaseListPage>;
}
function check(value: unknown): asserts value { if (!value) throw new Error('Invalid plan name metadata.'); }
function object(value: unknown, keys: string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
export function validPlanName(value: unknown): value is string | null {
  return value === null || typeof value === 'string' && value.length > 0 && value.trim() === value
    && Array.from(value).length <= 80
    && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069\ud800-\udfff]/u.test(value);
}
export function parsePlanNameState(value: unknown, options: { allowDefault?: boolean } = {}): PlanNameState {
  check(object(value, ['schemaVersion', 'caseId', 'name', 'nameRevision', 'lastMutationId']));
  check(value.schemaVersion === '2' && evidenceIdentifier(value.caseId) && validPlanName(value.name)
    && evidenceRevision(value.nameRevision, options.allowDefault !== false));
  check(value.nameRevision === 0 ? value.name === null && value.lastMutationId === null : evidenceIdentifier(value.lastMutationId));
  return { schemaVersion: '2', caseId: value.caseId, name: value.name,
    nameRevision: value.nameRevision, lastMutationId: value.lastMutationId as string | null };
}
export const parseStoredPlanName = (value: unknown): PlanNameState => parsePlanNameState(value, { allowDefault: false });
export function emptyPlanName(caseId: string): PlanNameState {
  return parsePlanNameState({ schemaVersion: '2', caseId, name: null, nameRevision: 0, lastMutationId: null });
}
export function parseReadPlanNameRequest(value: unknown): ReadPlanNameRequest {
  check(object(value, ['schemaVersion', 'caseId']) && value.schemaVersion === '2' && evidenceIdentifier(value.caseId));
  return { schemaVersion: '2', caseId: value.caseId };
}
export function parseSavePlanNameRequest(value: unknown): SavePlanNameRequest {
  check(object(value, ['schemaVersion', 'caseId', 'expectedNameRevision', 'mutationId', 'name']));
  check(value.schemaVersion === '2' && evidenceIdentifier(value.caseId) && evidenceIdentifier(value.mutationId)
    && evidenceRevision(value.expectedNameRevision, true) && Number.isSafeInteger(value.expectedNameRevision + 1)
    && validPlanName(value.name));
  return { schemaVersion: '2', caseId: value.caseId, expectedNameRevision: value.expectedNameRevision,
    mutationId: value.mutationId, name: value.name };
}
export function changePlanName(previous: PlanNameState, request: SavePlanNameRequest): PlanNameState | null {
  const state = parsePlanNameState(previous), input = parseSavePlanNameRequest(request);
  check(state.caseId === input.caseId);
  if (state.lastMutationId === input.mutationId) {
    return input.expectedNameRevision === state.nameRevision - 1 && input.name === state.name ? state : null;
  }
  if (input.expectedNameRevision !== state.nameRevision) return null;
  return parseStoredPlanName({ schemaVersion: '2', caseId: input.caseId, name: input.name,
    nameRevision: state.nameRevision + 1, lastMutationId: input.mutationId });
}
export function parseNamedCaseListRequest(value: unknown): CaseListQuery {
  check(object(value, ['schemaVersion', 'limit', 'afterCaseId']) && value.schemaVersion === '2');
  return parseCaseListQuery({ limit: value.limit, afterCaseId: value.afterCaseId });
}
export function parseNamedCaseListPage(value: unknown, input: CaseListQuery): NamedCaseListPage {
  const query = parseCaseListQuery(input);
  check(object(value, ['cases', 'nextAfterCaseId']) && Array.isArray(value.cases) && value.cases.length <= query.limit);
  let previous = query.afterCaseId;
  const cases = Array.from(value.cases, raw => {
    check(object(raw, ['caseId', 'caseRevision', 'name', 'nameRevision', 'lastMutationId']));
    const state = parsePlanNameState({ schemaVersion: '2', caseId: raw.caseId, name: raw.name,
      nameRevision: raw.nameRevision, lastMutationId: raw.lastMutationId });
    check(evidenceRevision(raw.caseRevision) && (previous === null || compareCaseIds(previous, state.caseId) < 0));
    previous = state.caseId;
    return { caseId: state.caseId, caseRevision: raw.caseRevision, name: state.name,
      nameRevision: state.nameRevision, lastMutationId: state.lastMutationId };
  });
  check(value.nextAfterCaseId === null || cases.length === query.limit && value.nextAfterCaseId === cases.at(-1)?.caseId);
  return { cases, nextAfterCaseId: value.nextAfterCaseId as string | null };
}
