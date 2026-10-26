import { evidenceIdentifier, evidenceRevision } from '../evidence/validation.ts';

export const MAX_CASE_LIST_LIMIT = 20;
export interface CaseListQuery { limit: number; afterCaseId: string | null }
export interface CaseListSummary { caseId: string; caseRevision: number }
export interface CaseListPage { cases: CaseListSummary[]; nextAfterCaseId: string | null }
export interface CaseListRepository {
  listForUser(userId: string, query: CaseListQuery): Promise<CaseListPage>;
}

function record(value: unknown, keys: string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
function check(value: unknown): asserts value {
  if (!value) throw new Error('Invalid case discovery data.');
}

export function compareCaseIds(a: string, b: string): number {
  return Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
}

export function parseCaseListQuery(value: unknown): CaseListQuery {
  check(record(value, ['limit', 'afterCaseId']));
  check(Number.isSafeInteger(value.limit) && Number(value.limit) >= 1 && Number(value.limit) <= MAX_CASE_LIST_LIMIT);
  check(value.afterCaseId === null || evidenceIdentifier(value.afterCaseId));
  return { limit: value.limit as number, afterCaseId: value.afterCaseId as string | null };
}

export function parseListCasesRequest(value: unknown): CaseListQuery {
  check(record(value, ['schemaVersion', 'limit', 'afterCaseId']) && value.schemaVersion === '1');
  return parseCaseListQuery({ limit: value.limit, afterCaseId: value.afterCaseId });
}

export function parseCaseListPage(value: unknown, input: CaseListQuery): CaseListPage {
  const query = parseCaseListQuery(input);
  check(record(value, ['cases', 'nextAfterCaseId']));
  check(Array.isArray(value.cases) && value.cases.length <= query.limit);
  let previous = query.afterCaseId;
  const cases = Array.from(value.cases, raw => {
    check(record(raw, ['caseId', 'caseRevision']));
    check(evidenceIdentifier(raw.caseId) && evidenceRevision(raw.caseRevision));
    check(previous === null || compareCaseIds(previous, raw.caseId) < 0);
    previous = raw.caseId;
    return { caseId: raw.caseId, caseRevision: raw.caseRevision as number };
  });
  check(value.nextAfterCaseId === null || (cases.length === query.limit
    && value.nextAfterCaseId === cases.at(-1)?.caseId));
  return { cases, nextAfterCaseId: value.nextAfterCaseId as string | null };
}
