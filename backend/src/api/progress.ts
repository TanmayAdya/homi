import type { AuthenticatedUser } from './match-case.ts';
import type { ProgramDefinition } from '../types.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import { AccountClosedError } from '../lifecycle/types.ts';
import { parseProgressRequest, progressPage, programReports, progressHistoryVersion, type ProgressRepository, type ProgressSave, type ProgressRead } from '../tracking/progress.ts';
export type ProgressRoute = 'read-progress' | 'save-progress' | 'read-progress-history';
export interface ProgressDependencies { authenticate(token: string): Promise<AuthenticatedUser | null>; cases: ProgressRepository; loadRegistry(): Promise<ProgramDefinition[]>; now(): Date; allowDemoPrograms?: boolean }
export async function handleProgress(input: { body: unknown; bearerToken: string | null }, deps: ProgressDependencies, route: ProgressRoute) {
  const fail = (status: number, code: string) => ({ status, body: { schemaVersion: '3', error: { code, message: 'Reload program progress and review your saved changes before trying again.' } }, headers: { 'Cache-Control': 'no-store' } });
  try {
    if (!input.bearerToken || input.bearerToken.length > 4096 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(input.bearerToken)) return fail(401, 'UNAUTHENTICATED');
    let historyProgram: string | null = null;
    let body = input.body;
    if (route === 'read-progress-history' && body && typeof body === 'object' && !Array.isArray(body) && Object.hasOwn(body, 'programId')) {
      const { programId, ...query } = body as Record<string, unknown>;
      if (evidenceIdentifier(programId)) historyProgram = programId;
      body = query;
    }
    let request; try { request = parseProgressRequest(body, route === 'save-progress'); } catch { request = null; }
    const user = await deps.authenticate(input.bearerToken);
    if (!user) return fail(401, 'UNAUTHENTICATED');
    if (!evidenceIdentifier(user.userId)) return fail(500, 'INTERNAL_ERROR');
    if (!request || route === 'read-progress-history' && historyProgram === null) return fail(400, 'INVALID_REQUEST');
    const registry = (await deps.loadRegistry()).filter(p => !p.isDemo || deps.allowDemoPrograms === true);
    const result = route !== 'save-progress' ? await deps.cases.readProgressForUser(user.userId, request.caseId)
      : await deps.cases.saveProgressForUser(user.userId, request as ProgressSave, deps.now().toISOString(), registry);
    if (result.status !== 'found') {
      const codes = { not_found: [404, 'CASE_NOT_FOUND'], conflict: [409, 'CASE_REVISION_MISMATCH'], progress_conflict: [409, 'PROGRESS_CONFLICT'],
        task_conflict: [409, 'TASK_CONFLICT'], mutation_conflict: [409, 'PROGRESS_MUTATION_CONFLICT'], limit: [507, 'PROGRESS_LIMIT'], invalid_operation: [400, 'INVALID_REQUEST'] } as const;
      const [status, code] = codes[result.status]; return fail(status, code);
    }
    const query: ProgressRead = route !== 'save-progress' ? request as ProgressRead : { schemaVersion: '3', caseId: request.caseId, offset: 0, limit: 20, expectedProgressRevision: null, expectedCaseRevision: null, expectedHistoryVersion: null, ...((request as ProgressSave).includeReferrals === true ? { includeReferrals: true as const } : {}) };
    if (query.expectedProgressRevision !== null && query.expectedProgressRevision !== result.context.record.revision) return fail(409, 'PROGRESS_CONFLICT');
    if (query.expectedHistoryVersion !== null && query.expectedHistoryVersion !== progressHistoryVersion(result.context)) return fail(409, 'PROGRESS_CONFLICT');
    if (query.expectedCaseRevision !== null && query.expectedCaseRevision !== result.context.snapshot.revision) return fail(409, 'CASE_REVISION_MISMATCH');
    if (route === 'read-progress-history') {
      const reports = programReports(result.context, historyProgram!);
      return { status: 200, body: { schemaVersion: '3', caseId: request.caseId, programId: historyProgram, revision: result.context.record.revision,
        caseRevision: result.context.snapshot.revision, historyVersion: progressHistoryVersion(result.context), reports: reports.slice(query.offset, query.offset + query.limit),
        nextOffset: query.offset + query.limit < reports.length ? query.offset + query.limit : null }, headers: { 'Cache-Control': 'no-store' } };
    }
    return { status: 200, body: progressPage(result.context, query, registry, result.acknowledgedMutationId ?? null, deps.now().toISOString()), headers: { 'Cache-Control': 'no-store' } };
  } catch (e) { return fail(e instanceof AccountClosedError ? 409 : 503, e instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
}
