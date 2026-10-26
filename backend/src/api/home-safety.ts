import type { EvidenceRepository } from '../evidence/repository.ts';
import { check, exact } from '../assessment/metadata.ts';
import { evidenceRevision } from '../evidence/validation.ts';
import { reportLines, renderHomeSafetyReport } from '../assessment/home-safety-report.ts';
import type { AuthenticatedUser } from './match-case.ts';
import { AccountClosedError } from '../lifecycle/types.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import { parseHomeSafetyRequest, parseHomeSafetyState, safetyRequestHash, type HomeSafetyRepository, type HomeSafetySave } from '../assessment/home-safety.ts';

export interface HomeSafetyDependencies { authenticate(token: string): Promise<AuthenticatedUser | null>; cases: HomeSafetyRepository & Pick<EvidenceRepository, 'readEvidenceCatalogForUser'>; now(): Date }
export type HomeSafetyRoute = 'read-home-safety' | 'save-home-safety' | 'export-home-safety';
let reportBusy = false;
const errors = {
  not_found: [404, 'CASE_NOT_FOUND'], conflict: [409, 'CASE_REVISION_MISMATCH'], safety_conflict: [409, 'HOME_SAFETY_CONFLICT'],
  evidence_conflict: [409, 'EVIDENCE_REVISION_MISMATCH'],
  mutation_conflict: [409, 'HOME_SAFETY_MUTATION_CONFLICT'], history_limit: [507, 'HOME_SAFETY_HISTORY_LIMIT'], invalid_operation: [400, 'INVALID_REQUEST'],
} as const;
export async function handleHomeSafety(input: { body: unknown; bearerToken: string | null }, deps: HomeSafetyDependencies, route: HomeSafetyRoute) {
  const fail = (status: number, code: string) => ({ status, body: { schemaVersion: '3', error: { code,
    message: 'Open the current rooms and checklist, then review your changes before saving.' } }, headers: { 'Cache-Control': 'no-store' } });
  try {
    const token = input.bearerToken;
    if (!token || token.length > 4096 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(token)) return fail(401, 'UNAUTHENTICATED');
    if (route === 'export-home-safety') return await exportReport(input, deps, fail);
    let request;
    try { request = parseHomeSafetyRequest(input.body, route === 'save-home-safety'); } catch { request = null; }
    const user = await deps.authenticate(token);
    if (user === null) return fail(401, 'UNAUTHENTICATED');
    if (!user || !evidenceIdentifier(user.userId)) return fail(500, 'INTERNAL_ERROR');
    if (request === null) return fail(400, 'INVALID_REQUEST');
    const result = route === 'read-home-safety' ? await deps.cases.readHomeSafetyForUser(user.userId, request.caseId)
      : await deps.cases.saveHomeSafetyForUser(user.userId, request as HomeSafetySave, deps.now().toISOString());
    if (result.status === 'found') {
      try {
        const state = parseHomeSafetyState(result.state);
        if (state.case.caseId !== request.caseId) return fail(500, 'INTERNAL_ERROR');
        if (route === 'save-home-safety') {
          const saved = request as HomeSafetySave;
          if (state.acknowledgedMutationId !== saved.mutationId || !state.safety.history.some(e => e.mutationId === saved.mutationId
            && e.requestHash === safetyRequestHash(saved))) return fail(500, 'INTERNAL_ERROR');
        } else if (state.acknowledgedMutationId !== null) return fail(500, 'INTERNAL_ERROR');
        return { status: 200, body: state, headers: { 'Cache-Control': 'no-store' } };
      } catch { return fail(500, 'INTERNAL_ERROR'); }
    }
    const [status, code] = errors[result.status]; return fail(status, code);
  } catch (error) { return fail(error instanceof AccountClosedError ? 409 : 503, error instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
}

async function exportReport(input: {body:unknown;bearerToken:string|null}, deps: HomeSafetyDependencies, fail: (status:number,code:string)=>any) {
  const user = await deps.authenticate(input.bearerToken!);
  if (user === null) return fail(401,'UNAUTHENTICATED');
  if (!user || !evidenceIdentifier(user.userId)) return fail(500,'INTERNAL_ERROR');
  let q: any;
  try {
    q=input.body;
    check(exact(q,['schemaVersion','caseId','expectedCaseRevision','expectedSafetyRevision','expectedCatalogRevision','includeNotes','includeEvidenceReferences']) && q.schemaVersion === '3' && evidenceIdentifier(q.caseId) && evidenceRevision(q.expectedCaseRevision) && evidenceRevision(q.expectedSafetyRevision,true) && evidenceRevision(q.expectedCatalogRevision,true) && typeof q.includeNotes === 'boolean' && typeof q.includeEvidenceReferences === 'boolean');
  } catch { return fail(400,'INVALID_REQUEST'); }
  const load = async () => {
    const state = await deps.cases.readHomeSafetyForUser(user.userId,q.caseId);
    if (state.status !== 'found') return null;
    const evidence = await deps.cases.readEvidenceCatalogForUser(user.userId,q.caseId);
    if (evidence.status !== 'found') return null;
    return { state: parseHomeSafetyState(state.state), catalog: evidence.catalog };
  };
  const loaded = await load();
  if (!loaded) return fail(404,'CASE_NOT_FOUND');
  const bound = (v: NonNullable<typeof loaded>) => v.state.case.revision===q.expectedCaseRevision && v.state.safety.revision===q.expectedSafetyRevision && v.catalog.caseRevision===q.expectedCaseRevision && v.catalog.catalogRevision===q.expectedCatalogRevision;
  if (!bound(loaded)) return fail(409,'HOME_SAFETY_CONFLICT');
  if (reportBusy) return fail(503,'REPORT_BUSY');
  reportBusy=true;
  try {
    const generatedAt=deps.now().toISOString();
    const result=await renderHomeSafetyReport(reportLines(loaded.state,loaded.catalog,generatedAt,q.includeNotes,q.includeEvidenceReferences));
    const fresh=await load();
    if (!fresh) return fail(404,'CASE_NOT_FOUND');
    if (!bound(fresh) || safetyRequestHash(fresh)!==safetyRequestHash(loaded)) return fail(409,'HOME_SAFETY_CONFLICT');
    return {status:200,headers:{'Cache-Control':'no-store'},body:{schemaVersion:'3',caseId:q.caseId,caseRevision:q.expectedCaseRevision,safetyRevision:q.expectedSafetyRevision,catalogRevision:q.expectedCatalogRevision,includeNotes:q.includeNotes,includeEvidenceReferences:q.includeEvidenceReferences,generatedAt,pageCount:result.pageCount,sha256: (await import('node:crypto')).createHash('sha256').update(result.bytes).digest('hex'),pdfBase64:Buffer.from(result.bytes).toString('base64')}};
  } catch (error) {
    if (error instanceof AccountClosedError) return fail(404,'CASE_NOT_FOUND');
    return fail(422,error instanceof Error && ['REPORT_UNSUPPORTED_TEXT','REPORT_LIMIT'].includes(error.message) ? error.message : 'REPORT_FAILED');
  } finally { reportBusy=false; }
}
