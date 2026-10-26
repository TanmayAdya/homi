import { MAX_HOME_MODEL_BYTES } from '../assessment/home-model.ts';
import { handleScanModel, type ScanModelDependencies, type ScanModelRoute } from './scan-model.ts';
import { MAX_SCAN_MODEL_BYTES } from '../assessment/scan-model.ts';
import { SHARING_ROUTES, type SharingRoute } from '../sharing/contracts.ts';
import { handleSharing, type SharingDependencies } from './sharing.ts';
import { invitationLanding } from '../sharing/invitation-landing.ts';
import { invitationEmail } from '../auth/invitation-email.ts';
import { handleProgress, type ProgressDependencies, type ProgressRoute } from './progress.ts';
import { handleHomeSafety, type HomeSafetyDependencies, type HomeSafetyRoute } from './home-safety.ts';
import { handlePlanName, type PlanNameDependencies, type PlanNameRoute } from './plan-name.ts';
import { handleReadFormAnswersV2, handleSaveFormAnswersV2 } from './form-answers-v2.ts';
import { handleReadProgramIntake, handleSaveProgramIntake, type ProgramIntakeDependencies } from './program-intake.ts';
import { handleAssessment, type AssessmentDependencies, type AssessmentRoute } from './assessment.ts';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import type { Socket } from 'node:net';
import { handleMatchCase, type MatchCaseDependencies, type ApiErrorCode } from './match-case.ts';
import { handlePreparePacket, type PreparePacketDependencies } from './prepare-packet.ts';
import { handleReadFormAnswers, handleSaveFormAnswers, type FormAnswerDependencies } from './form-answers.ts';
import { handleReadCase } from './read-case.ts';
import { handleListCases, type ListCasesDependencies } from './list-cases.ts';
import { handleReadRequestHistory, handleAppendRequestUpdate, type RequestTrackingDependencies } from './request-tracking.ts';
import { handleDraftExport, type DraftExportDependencies, type ExportRoute } from './draft-export.ts';
import { handleCreateCase, handleSaveCase, type CaseWriteDependencies } from './write-case.ts';
import { handleUploadEvidence, handleDeleteEvidence, type WriteEvidenceDependencies } from './write-evidence.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import type { AuthenticatedUser } from './match-case.ts';
import { createHostedAdmission } from './request-admission.ts';
import { createAccountAdmission, type AccountAdmissionResult } from './account-admission.ts';
import { handleDeleteCase, handlePrepareAccountDeletion, handleConfirmAccountDeletion, handleAccountDeletionStatus,
  type LifecycleDependencies, type LifecycleRoute } from './lifecycle.ts';

export const MAX_REQUEST_BYTES = 16 * 1024;
export const MAX_UPLOAD_REQUEST_BYTES = Math.ceil(8 * 1024 * 1024 / 3) * 4 + MAX_REQUEST_BYTES;

interface UploadAdmission { active: boolean }
type AuthenticationStopped = { status: 'aborted' } | { status: 'unavailable' };

export interface HttpServerOptions {
  repositoryAvailable?: () => Promise<boolean>;
  hosted?: boolean;
  assessmentDependencies?: AssessmentDependencies;
  programIntakeDependencies?: ProgramIntakeDependencies;
  planNameDependencies?: PlanNameDependencies;
  progressDependencies?: ProgressDependencies;
  scanModelDependencies?: ScanModelDependencies;
  homeSafetyDependencies?: HomeSafetyDependencies;
  sharingDependencies?: SharingDependencies;
  admissionNow?: () => number;
  lifecycleDependencies?: LifecycleDependencies;
  caseListDependencies?: ListCasesDependencies;
  requestTrackingDependencies?: RequestTrackingDependencies;
}

const ACCOUNT_HEAVY_ROUTES = new Set(['/v3/read-scan-model', '/v3/save-scan-model', '/v3/read-home-model', '/v3/save-home-model', '/v1/upload-evidence', '/v1/download-evidence',
  '/v3/preview-sensitive-photo', '/v3/read-sensitive-photo', '/v3/preview-sensitive-report', '/v3/read-sensitive-report',
  '/v1/create-draft-export', '/v1/download-draft-export', '/v2/create-draft-export', '/v2/download-draft-export']);

interface RequestAccountGate { acquire(userId: string): boolean; receipt(): boolean }

const HEAVY_ROUTES = new Set(['/v3/read-scan-model', '/v3/save-scan-model', '/v3/read-home-model', '/v3/save-home-model', '/v1/upload-evidence', '/v1/download-evidence',
  '/v3/preview-sensitive-photo', '/v3/read-sensitive-photo', '/v3/preview-sensitive-report', '/v3/read-sensitive-report',
  '/v1/create-draft-export', '/v1/download-draft-export', '/v2/create-draft-export', '/v2/download-draft-export', '/v1/delete-case', '/v1/confirm-account-deletion']);

async function authenticateBeforeUpload(
  request: IncomingMessage, response: ServerResponse, token: string, deps: Pick<WriteEvidenceDependencies,'authenticate'>,
): Promise<{ status: 'authenticated'; user: AuthenticatedUser | null } | AuthenticationStopped> {
  let stop: (value: AuthenticationStopped) => void = () => {};
  const stopped = new Promise<AuthenticationStopped>(resolve => { stop = resolve; });
  const onAbort = () => stop({ status: 'aborted' });
  request.once('aborted', onAbort);
  response.once('close', onAbort);
  const timer = setTimeout(() => stop({ status: 'unavailable' }), 10_000);
  timer.unref();
  try {
    if (request.destroyed || response.destroyed) return { status: 'aborted' };
    return await Promise.race([
      Promise.resolve().then(() => deps.authenticate(token))
        .then(user => ({ status: 'authenticated' as const, user }), () => ({ status: 'unavailable' as const })),
      stopped,
    ]);
  } finally {
    clearTimeout(timer);
    request.off('aborted', onAbort);
    response.off('close', onAbort);
  }
}

function sendJson(response: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...headers,
  });
  response.end(JSON.stringify(body));
}

function fail(response: ServerResponse, status: number, code: ApiErrorCode | 'NOT_FOUND' | 'METHOD_NOT_ALLOWED' | 'PAYLOAD_TOO_LARGE' | 'UNSUPPORTED_MEDIA_TYPE' | 'UPLOAD_BUSY' | 'RATE_LIMITED', message: string, headers: Record<string, string> = {}) {
  sendJson(response, status, { schemaVersion: '1', error: { code, message } }, headers);
}

async function captureAuthentication(authenticate: (token: string) => Promise<AuthenticatedUser | null>, token: string, allowVerifiedEmail = false) {
  let outcome: { user: AuthenticatedUser | null } | { error: unknown };
  let userId: string | null = null;
  let malformed = false;
  try {
    const user = await authenticate(token);
    const hasEmail = user !== null && typeof user === 'object' && Object.hasOwn(user, 'verifiedEmail');
    if (user !== null && typeof user === 'object' && !Array.isArray(user)
      && Object.keys(user).length === (hasEmail ? 2 : 1)
      && (!hasEmail || (allowVerifiedEmail && typeof user.verifiedEmail === 'string'
        && invitationEmail(user.verifiedEmail) === user.verifiedEmail))
      && Object.hasOwn(user, 'userId') && evidenceIdentifier(user.userId)) {
      userId = user.userId;
      outcome = { user: Object.freeze({ userId, ...(hasEmail ? { verifiedEmail: user.verifiedEmail } : {}) }) };
    } else { malformed = user !== null; outcome = { user }; }
  } catch (error) { outcome = { error }; }
  return { userId, malformed, authenticate: async (requestedToken: string) => {
    if (requestedToken !== token) throw new Error('Authentication context changed.');
    if ('error' in outcome) throw outcome.error;
    return outcome.user;
  } };
}

class BodyTooLarge extends Error {}

async function readJson(request: IncomingMessage, limit = MAX_REQUEST_BYTES): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const part of request.iterator({ destroyOnReturn: false })) {
    const bytes = Buffer.isBuffer(part) ? part : Buffer.from(part);
    size += bytes.length;
    if (size > limit) throw new BodyTooLarge();
    chunks.push(bytes);
  }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
}

export function createMatchingServer(
  dependencies: MatchCaseDependencies, packetDependencies?: PreparePacketDependencies, formAnswerDependencies?: FormAnswerDependencies,
  exportDependencies?: DraftExportDependencies,
  caseWriteDependencies?: CaseWriteDependencies, evidenceWriteDependencies?: WriteEvidenceDependencies,
  options: HttpServerOptions = {},
) {
  const uploadAdmission: UploadAdmission = { active: false };
  const admission = options.hosted === true ? createHostedAdmission(options.admissionNow) : null;
  const accounts = options.hosted === true ? createAccountAdmission(options.admissionNow) : null;
  const server = createServer({ maxHeaderSize: 8192 }, (request, response) => {
    if (admission && request.url === '/healthz') {
      if (request.method === 'GET' || request.method === 'HEAD') {
        sendJson(response, 200, { status: 'ok' });
      } else {
        fail(response, 405, 'METHOD_NOT_ALLOWED', 'Use GET or HEAD for this endpoint.', { Allow: 'GET, HEAD' });
      }
      request.resume();
      return;
    }
    const permit = admission?.acquire(HEAVY_ROUTES.has(request.url ?? ''));
    if (permit && !permit.accepted) {
      fail(response, 503, 'SERVICE_UNAVAILABLE', 'The server is busy. Try again shortly.',
        { 'Retry-After': String(permit.retryAfter), Connection: 'close' });
      request.resume();
      return;
    }
    let accountPermit: AccountAdmissionResult | undefined;
    const rejectAccount = (result: Extract<AccountAdmissionResult, { accepted: false }>) => {
      fail(response, result.status, result.code, result.status === 429
        ? 'Too many requests. Wait before trying again.' : 'The server is busy. Try again shortly.',
        { 'Retry-After': String(result.retryAfter), Connection: 'close' });
      request.resume();
      return false;
    };
    const accountGate: RequestAccountGate | undefined = accounts ? {
      acquire(userId) {
        accountPermit = accounts.acquire(userId, ACCOUNT_HEAVY_ROUTES.has(request.url ?? ''));
        return accountPermit.accepted || rejectAccount(accountPermit);
      },
      receipt() { const result = accounts.acquireReceipt(); return result.accepted || rejectAccount(result); },
    } : undefined;
    let settled = false;
    let responseComplete = response.writableFinished || response.destroyed;
    const release = () => {
      if (!settled || !responseComplete) return;
      if (permit?.accepted) permit.release();
      if (accountPermit?.accepted) accountPermit.release();
      response.off('finish', complete);
      response.off('close', complete);
    };
    const complete = () => { responseComplete = true; release(); };
    response.once('finish', complete);
    response.once('close', complete);
    const authenticationWork: Promise<unknown>[] = [];
    const trackedEvidenceDependencies = permit?.accepted && evidenceWriteDependencies ? {
      ...evidenceWriteDependencies,
      authenticate: (token: string) => {
        const work = Promise.resolve().then(() => evidenceWriteDependencies.authenticate(token));
        authenticationWork.push(work);
        return work;
      },
    } : evidenceWriteDependencies;
    const trackedScanModelDependencies = permit?.accepted && options.scanModelDependencies ? {
      ...options.scanModelDependencies,
      authenticate: (token: string) => {
        const work = Promise.resolve().then(() => options.scanModelDependencies!.authenticate(token));
        authenticationWork.push(work);
        return work;
      },
    } : options.scanModelDependencies;
    const dispatch=async()=>{
      if(options.repositoryAvailable){
        let available=false;try{available=await options.repositoryAvailable();}catch{}
        if(!available){fail(response,503,'SERVICE_UNAVAILABLE','The service is unavailable for maintenance.',{'Retry-After':'60'});request.resume();return;}
      }
      await route(request, response, dependencies, uploadAdmission, packetDependencies, formAnswerDependencies,
        exportDependencies, caseWriteDependencies, trackedEvidenceDependencies, options.lifecycleDependencies, options.caseListDependencies, options.requestTrackingDependencies, accountGate, options.assessmentDependencies, options.programIntakeDependencies, options.planNameDependencies, options.homeSafetyDependencies, options.sharingDependencies, options.progressDependencies, trackedScanModelDependencies);
    };
    void dispatch().catch(() => {
      if (response.headersSent) response.destroy();
      else fail(response, 500, 'INTERNAL_ERROR', 'The request could not be completed.');
    }).finally(async () => {
      await Promise.allSettled(authenticationWork);
      settled = true;
      release();
    });
  });
  if (admission) {
    server.maxConnections = 64;
    server.maxRequestsPerSocket = 100;
  }
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.setTimeout(20_000);
  server.on('timeout', (socket: Socket) => socket.destroy());
  return server;
}

async function route(
  request: IncomingMessage, response: ServerResponse, dependencies: MatchCaseDependencies,
  uploadAdmission: UploadAdmission,
  packetDependencies?: PreparePacketDependencies, formAnswerDependencies?: FormAnswerDependencies,
  exportDependencies?: DraftExportDependencies,
  caseWriteDependencies?: CaseWriteDependencies, evidenceWriteDependencies?: WriteEvidenceDependencies,
  lifecycleDependencies?: LifecycleDependencies,
  caseListDependencies?: ListCasesDependencies,
  requestTrackingDependencies?: RequestTrackingDependencies,
  accountGate?: RequestAccountGate,
  assessmentDependencies?: AssessmentDependencies,
  programIntakeDependencies?: ProgramIntakeDependencies,
  planNameDependencies?: PlanNameDependencies,
  homeSafetyDependencies?: HomeSafetyDependencies,
  sharingDependencies?: SharingDependencies,
  progressDependencies?: ProgressDependencies,
  scanModelDependencies?: ScanModelDependencies,
) {
  if (sharingDependencies?.simpleInvitationsEnabled === true && invitationLanding(request,response)) return;
  const scanModelRoute = scanModelDependencies ? (['read-scan-model','save-scan-model','read-home-model','save-home-model'] as ScanModelRoute[]).find(r=>request.url===`/v3/${r}`) : undefined;
  const scanSave = scanModelRoute==='save-scan-model' || scanModelRoute==='save-home-model';
  const progressRoute = progressDependencies ? (['read-progress', 'save-progress', 'read-progress-history'] as ProgressRoute[]).find(r => request.url === `/v3/${r}`) : undefined;
  const sharingRoute = sharingDependencies ? SHARING_ROUTES.find(r => request.url === `/v3/${r}`) : undefined;
  const homeSafetyRoute = homeSafetyDependencies ? (['read-home-safety', 'save-home-safety', 'export-home-safety'] as HomeSafetyRoute[]).find(r => request.url === `/v3/${r}`) : undefined;
  const planNameRoute = planNameDependencies ? (['read-plan-name', 'save-plan-name', 'list-cases'] as PlanNameRoute[]).find(r => request.url === `/v2/${r}`) : undefined;
  const programIntakeRoute=programIntakeDependencies ? (['read-program-intake','save-program-intake'] as const).find(r=>request.url===`/v2/${r}`):undefined;
  const assessmentRoute=assessmentDependencies ? (['read-assessment','save-assessment','read-evidence-annotations','save-evidence-annotations'] as AssessmentRoute[]).find(r=>request.url===`/v2/${r}`):undefined;
  const exportRoutes: ExportRoute[] = ['list-evidence', 'download-evidence', 'create-draft-export', 'download-draft-export'];
  const exportVersion:1|2=request.url?.startsWith('/v2/')?2:1;
  const exportRoute = exportDependencies === undefined ? undefined : exportRoutes.find(route => request.url === `/v1/${route}` || (['create-draft-export','download-draft-export'].includes(route)&&request.url===`/v2/${route}`));
  const isPacketRequest = request.url === '/v1/prepare-packet' && packetDependencies !== undefined;
  const isFormRead = ['/v1/read-form-answers','/v2/read-form-answers'].includes(request.url ?? '') && formAnswerDependencies !== undefined;
  const isFormSave = ['/v1/save-form-answers','/v2/save-form-answers'].includes(request.url ?? '') && formAnswerDependencies !== undefined;
  const isCapabilities = request.url === '/v1/capabilities';
  const isCaseRead = request.url === '/v1/read-case';
  const isCaseList = request.url === '/v1/list-cases' && caseListDependencies !== undefined;
  const requestTrackingRoute = requestTrackingDependencies === undefined ? undefined
    : (['read-request-history', 'append-request-update'] as const).find(route => request.url === `/v1/${route}`);
  const isCaseCreate = request.url === '/v1/create-case' && caseWriteDependencies !== undefined;
  const isCaseSave = request.url === '/v1/save-case' && caseWriteDependencies !== undefined;
  const isUpload = request.url === '/v1/upload-evidence' && evidenceWriteDependencies !== undefined;
  const isDelete = request.url === '/v1/delete-evidence' && evidenceWriteDependencies !== undefined;
  const lifecycleRoutes: LifecycleRoute[] = ['delete-case', 'prepare-account-deletion', 'confirm-account-deletion', 'account-deletion-status'];
  const lifecycleRoute = lifecycleDependencies === undefined ? undefined : lifecycleRoutes.find(route => request.url === `/v1/${route}`);
  if (request.url !== '/v1/match-case' && !isCapabilities && !isPacketRequest && !isFormRead && !isFormSave && !isCaseRead && !exportRoute
    && !isCaseCreate && !isCaseSave && !isUpload && !isDelete && !lifecycleRoute && !isCaseList && !requestTrackingRoute && !assessmentRoute && !programIntakeRoute && !planNameRoute && !homeSafetyRoute && !progressRoute && !sharingRoute && !scanModelRoute) {
    fail(response, 404, 'NOT_FOUND', 'This endpoint does not exist.');
    request.resume();
    return;
  }
  if (request.method !== 'POST') {
    fail(response, 405, 'METHOD_NOT_ALLOWED', 'Use POST for this endpoint.', { Allow: 'POST' });
    request.resume();
    return;
  }
  const authorizationCount = request.rawHeaders.filter((_, index) => index % 2 === 0 && request.rawHeaders[index].toLowerCase() === 'authorization').length;
  const authorization = request.headers.authorization;
  const bearer = typeof authorization === 'string' && /^Bearer ([A-Za-z0-9._~+\/-]+=*)$/i.exec(authorization);
  if (authorizationCount !== 1 || !bearer || bearer[1].length > 4096) {
    fail(response, 401, 'UNAUTHENTICATED', 'Sign in to make this request.', { 'WWW-Authenticate': 'Bearer' });
    request.resume();
    return;
  }
  if (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity') {
    fail(response, 415, 'UNSUPPORTED_MEDIA_TYPE', 'Send uncompressed JSON.');
    request.resume();
    return;
  }
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers['content-type'] ?? '')) {
    fail(response, 415, 'UNSUPPORTED_MEDIA_TYPE', 'Send application/json with UTF-8 encoding.');
    request.resume();
    return;
  }
  if ((isUpload || scanSave) && uploadAdmission.active) {
    fail(response, 429, scanSave ? 'RATE_LIMITED' : 'UPLOAD_BUSY', 'Another private upload is being processed. Wait before trying again.',
      { 'Retry-After': '1', Connection: 'close' });
    request.resume();
    return;
  }
  if (isUpload || scanSave) uploadAdmission.active = true;
  try {
    if (isUpload) {
      const auth = await authenticateBeforeUpload(request, response, bearer[1], evidenceWriteDependencies!);
      if (auth.status === 'aborted') return;
      if (auth.status === 'unavailable') {
        fail(response, 503, 'SERVICE_UNAVAILABLE', 'Photo uploads are temporarily unavailable.', { Connection: 'close' });
        request.resume();
        return;
      }
      const user = auth.user;
      if (user === null) {
        fail(response, 401, 'UNAUTHENTICATED', 'Sign in to upload a photo.',
          { 'WWW-Authenticate': 'Bearer', Connection: 'close' });
        request.resume();
        return;
      }
      if (!user || typeof user !== 'object' || Array.isArray(user)
        || Object.keys(user).length !== 1 || !Object.hasOwn(user, 'userId') || !evidenceIdentifier(user.userId)) {
        fail(response, 500, 'INTERNAL_ERROR', 'The request could not be completed.', { Connection: 'close' });
        request.resume();
        return;
      }
      if (request.destroyed || response.destroyed) return;
      if (accountGate && !accountGate.acquire(user.userId)) return;
      if (accountGate) {
        const admittedOwner = user.userId;
        const original = evidenceWriteDependencies!;
        evidenceWriteDependencies = { ...original, authenticate: async token => {
          const current = await original.authenticate(token);
          if (current !== null && (typeof current !== 'object' || Array.isArray(current)
            || Object.keys(current).length !== 1 || !Object.hasOwn(current, 'userId') || !evidenceIdentifier(current?.userId) || current.userId !== admittedOwner)) {
            throw new Error('Upload authentication changed.');
          }
          return current;
        } };
      }
    }
    if (scanSave) {
      const auth=await authenticateBeforeUpload(request,response,bearer[1],scanModelDependencies!);
      if(auth.status==='aborted')return;
      if(auth.status==='unavailable'){fail(response,503,'SERVICE_UNAVAILABLE','Private uploads are temporarily unavailable.',{Connection:'close'});request.resume();return;}
      if(auth.user===null){fail(response,401,'UNAUTHENTICATED','Sign in to save a model.',{Connection:'close'});request.resume();return;}
      if(!auth.user || typeof auth.user!=='object' || Object.keys(auth.user).length!==1 || !evidenceIdentifier(auth.user.userId)){
        fail(response,500,'INTERNAL_ERROR','The request could not be completed.',{Connection:'close'});request.resume();return;
      }
      if(request.destroyed || response.destroyed)return;
      if(accountGate && !accountGate.acquire(auth.user.userId))return;
      const owner=auth.user.userId,original=scanModelDependencies!;
      scanModelDependencies={...original,authenticate:async token=>{
        const user=await original.authenticate(token);
        if(user!==null && (typeof user!=='object' || Array.isArray(user) || Object.keys(user).length!==1 || !Object.hasOwn(user,'userId') || !evidenceIdentifier(user?.userId) || user.userId!==owner))throw new Error('Upload authentication changed.');
        return user;
      }};
    }
    await readAndDispatch(request, response, bearer[1], dependencies, {
      isCapabilities, isCaseRead, isCaseList, isCaseCreate, isCaseSave, isFormRead, isFormSave, isPacketRequest, isUpload, isDelete, exportRoute, exportVersion, lifecycleRoute, requestTrackingRoute, assessmentRoute, programIntakeRoute, planNameRoute, homeSafetyRoute, sharingRoute, progressRoute, scanModelRoute,
    }, packetDependencies, formAnswerDependencies, exportDependencies, caseWriteDependencies, evidenceWriteDependencies, lifecycleDependencies, caseListDependencies, requestTrackingDependencies, accountGate, assessmentDependencies, programIntakeDependencies, planNameDependencies, homeSafetyDependencies, sharingDependencies, progressDependencies, scanModelDependencies);
  } finally {
    if (isUpload || scanSave) uploadAdmission.active = false;
  }
}

async function readAndDispatch(
  request: IncomingMessage, response: ServerResponse, token: string, dependencies: MatchCaseDependencies,
  routes: { isCapabilities: boolean; isCaseRead: boolean; isCaseList: boolean; isCaseCreate: boolean; isCaseSave: boolean; isFormRead: boolean; isFormSave: boolean;
    exportVersion:1|2; isPacketRequest: boolean; isUpload: boolean; isDelete: boolean; exportRoute: ExportRoute | undefined;
    scanModelRoute: ScanModelRoute | undefined; sharingRoute: SharingRoute | undefined; progressRoute: ProgressRoute | undefined; homeSafetyRoute: HomeSafetyRoute | undefined; planNameRoute: PlanNameRoute | undefined; programIntakeRoute:'read-program-intake'|'save-program-intake'|undefined; assessmentRoute: AssessmentRoute | undefined; lifecycleRoute: LifecycleRoute | undefined; requestTrackingRoute: 'read-request-history' | 'append-request-update' | undefined },
  packetDependencies?: PreparePacketDependencies, formAnswerDependencies?: FormAnswerDependencies,
  exportDependencies?: DraftExportDependencies, caseWriteDependencies?: CaseWriteDependencies,
  evidenceWriteDependencies?: WriteEvidenceDependencies,
  lifecycleDependencies?: LifecycleDependencies,
  caseListDependencies?: ListCasesDependencies,
  requestTrackingDependencies?: RequestTrackingDependencies,
  accountGate?: RequestAccountGate,
  assessmentDependencies?: AssessmentDependencies,
  programIntakeDependencies?: ProgramIntakeDependencies,
  planNameDependencies?: PlanNameDependencies,
  homeSafetyDependencies?: HomeSafetyDependencies,
  sharingDependencies?: SharingDependencies,
  progressDependencies?: ProgressDependencies,
  scanModelDependencies?: ScanModelDependencies,
) {
  const { isCaseRead, isCaseList, isCaseCreate, isCaseSave, isFormRead, isFormSave, isPacketRequest, isUpload, isDelete, exportRoute, exportVersion, lifecycleRoute, requestTrackingRoute, assessmentRoute, programIntakeRoute, planNameRoute, homeSafetyRoute, sharingRoute, progressRoute, scanModelRoute } = routes;
  const limit = scanModelRoute==='save-home-model' ? MAX_HOME_MODEL_BYTES : scanModelRoute==='save-scan-model' ? MAX_SCAN_MODEL_BYTES : isUpload ? MAX_UPLOAD_REQUEST_BYTES : assessmentRoute==='save-assessment' ? 32*1024 : MAX_REQUEST_BYTES;
  if (request.headers['content-length'] && Number(request.headers['content-length']) > limit) {
    fail(response, 413, 'PAYLOAD_TOO_LARGE', 'The request is too large.', { Connection: 'close' });
    request.resume();
    return;
  }
  let body: unknown;
  try {
    body = await readJson(request, limit);
  } catch (error) {
    if (error instanceof BodyTooLarge) {
      fail(response, 413, 'PAYLOAD_TOO_LARGE', 'The request is too large.', { Connection: 'close' });
      request.resume();
    } else {
      fail(response, 400, 'INVALID_REQUEST', 'Send a valid JSON request.');
    }
    return;
  }
  if (routes.isCapabilities) {
    if (!body || typeof body !== 'object' || Array.isArray(body) ||
        Object.keys(body).length !== 1 || (body as Record<string, unknown>).schemaVersion !== '1') {
      fail(response, 400, 'INVALID_REQUEST', 'Send a versioned capability request.'); return;
    }
    const auth = await captureAuthentication(dependencies.authenticate, token);
    if (auth.malformed) { fail(response, 500, 'INTERNAL_ERROR', 'The request could not be completed.'); return; }
    let user: AuthenticatedUser | null;
    try { user = await auth.authenticate(token); }
    catch { fail(response, 503, 'SERVICE_UNAVAILABLE', 'Availability could not be checked.'); return; }
    if (!user) { fail(response, 401, 'UNAUTHENTICATED', 'Sign in to check availability.'); return; }
    if (accountGate && !accountGate.acquire(user.userId)) return;
    sendJson(response, 200, { schemaVersion: '1', features: {
      structuredRooms: homeSafetyDependencies !== undefined,
      tracking: progressDependencies !== undefined,
      scanSync: scanModelDependencies !== undefined,
      permissionSharing: sharingDependencies !== undefined,
      sensitiveSharing: sharingDependencies?.sensitiveEnabled === true,
      simpleInvitations: sharingDependencies?.simpleInvitationsEnabled === true,
    } });
    return;
  }
  if (response.destroyed || response.writableEnded) return;
  if (accountGate && !isUpload && scanModelRoute!=='save-scan-model' && scanModelRoute!=='save-home-model') {
    if (lifecycleRoute === 'account-deletion-status') {
      if (!accountGate.receipt()) return;
    } else {
      const selected = scanModelRoute ? scanModelDependencies! : sharingRoute ? sharingDependencies! : progressRoute ? progressDependencies! : homeSafetyRoute ? homeSafetyDependencies! : planNameRoute ? planNameDependencies! : programIntakeRoute ? programIntakeDependencies! : assessmentRoute ? assessmentDependencies! : requestTrackingRoute ? requestTrackingDependencies!
        : isCaseList ? caseListDependencies! : lifecycleRoute ? lifecycleDependencies!
          : isCaseCreate || isCaseSave ? caseWriteDependencies! : isDelete ? evidenceWriteDependencies!
            : exportRoute ? exportDependencies! : isFormRead || isFormSave ? formAnswerDependencies!
              : isPacketRequest ? packetDependencies! : dependencies;
      const recent = lifecycleRoute === 'prepare-account-deletion' || lifecycleRoute === 'confirm-account-deletion';
      const authenticate = recent ? lifecycleDependencies!.authenticateForDeletion.bind(lifecycleDependencies)
        : selected.authenticate.bind(selected);
      const outcome = await captureAuthentication(authenticate, token, sharingRoute !== undefined);
      if (response.destroyed || response.writableEnded) return;
      if (outcome.malformed) { fail(response, 500, 'INTERNAL_ERROR', 'The request could not be completed.'); return; }
      if (outcome.userId !== null && !accountGate.acquire(outcome.userId)) return;
      if (scanModelRoute) scanModelDependencies = { ...scanModelDependencies!, authenticate: outcome.authenticate };
      else if (sharingRoute) sharingDependencies = { ...sharingDependencies!, authenticate: outcome.authenticate };
      else if (progressRoute) progressDependencies = { ...progressDependencies!, authenticate: outcome.authenticate };
      else if (homeSafetyRoute) homeSafetyDependencies = { ...homeSafetyDependencies!, authenticate: outcome.authenticate };
      else if (planNameRoute) planNameDependencies = { ...planNameDependencies!, authenticate: outcome.authenticate };
      else if(programIntakeRoute) programIntakeDependencies={...programIntakeDependencies!,authenticate:outcome.authenticate};
      else if (assessmentRoute) assessmentDependencies = {...assessmentDependencies!,authenticate:outcome.authenticate};
      else if (requestTrackingRoute) requestTrackingDependencies = { ...requestTrackingDependencies!, authenticate: outcome.authenticate };
      else if (isCaseList) caseListDependencies = { ...caseListDependencies!, authenticate: outcome.authenticate };
      else if (lifecycleRoute) lifecycleDependencies = recent
        ? { ...lifecycleDependencies!, authenticateForDeletion: outcome.authenticate }
        : { ...lifecycleDependencies!, authenticate: outcome.authenticate };
      else if (isCaseCreate || isCaseSave) caseWriteDependencies = { ...caseWriteDependencies!, authenticate: outcome.authenticate };
      else if (isDelete) evidenceWriteDependencies = { ...evidenceWriteDependencies!, authenticate: outcome.authenticate };
      else if (exportRoute) exportDependencies = { ...exportDependencies!, authenticate: outcome.authenticate };
      else if (isFormRead || isFormSave) formAnswerDependencies = { ...formAnswerDependencies!, authenticate: outcome.authenticate };
      else if (isPacketRequest) packetDependencies = { ...packetDependencies!, authenticate: outcome.authenticate };
      else dependencies = { ...dependencies, authenticate: outcome.authenticate };
    }
  }
  const input = { body, bearerToken: token };
  if (scanModelRoute) {
    const result=await handleScanModel(input,scanModelDependencies!,scanModelRoute);
    sendJson(response,result.status,result.body,result.headers);return;
  }
  if (progressRoute) {
    const result = await handleProgress(input, progressDependencies!, progressRoute);
    sendJson(response, result.status, result.body, result.headers); return;
  }
  if (sharingRoute) {
    const result = await handleSharing({ body, bearerToken: token }, sharingDependencies!, sharingRoute);
    sendJson(response, result.status, result.body, result.headers); return;
  }
  if (homeSafetyRoute) {
    const result = await handleHomeSafety(input, homeSafetyDependencies!, homeSafetyRoute);
    sendJson(response, result.status, result.body, result.headers); return;
  }
  if (planNameRoute) {
    const result = await handlePlanName(input, planNameDependencies!, planNameRoute);
    sendJson(response, result.status, result.body, result.headers); return;
  }
  if(programIntakeRoute){const result=await (programIntakeRoute==='read-program-intake'?handleReadProgramIntake:handleSaveProgramIntake)(input,programIntakeDependencies!);sendJson(response,result.status,result.body,result.headers);return;}
  if(assessmentRoute){const result=await handleAssessment(input,assessmentDependencies!,assessmentRoute);sendJson(response,result.status,result.body,result.headers);return;}
  if (requestTrackingRoute) {
    const result = requestTrackingRoute === 'read-request-history'
      ? await handleReadRequestHistory(input, requestTrackingDependencies!)
      : await handleAppendRequestUpdate(input, requestTrackingDependencies!);
    sendJson(response, result.status, result.body, result.headers);
    return;
  }
  if (isCaseList) {
    const result = await handleListCases(input, caseListDependencies!);
    sendJson(response, result.status, result.body, result.headers);
    return;
  }
  if (lifecycleRoute) {
    const result = lifecycleRoute === 'delete-case' ? await handleDeleteCase(input, lifecycleDependencies!)
      : lifecycleRoute === 'prepare-account-deletion' ? await handlePrepareAccountDeletion(input, lifecycleDependencies!)
        : lifecycleRoute === 'confirm-account-deletion' ? await handleConfirmAccountDeletion(input, lifecycleDependencies!)
          : await handleAccountDeletionStatus(input, lifecycleDependencies!);
    sendJson(response, result.status, result.body, result.headers);
    return;
  }
  if (isCaseCreate || isCaseSave || isUpload || isDelete) {
    const controller = new AbortController();
    const onClose = () => controller.abort();
    response.once('close', onClose);
    try {
      const result = isCaseCreate ? await handleCreateCase(input, caseWriteDependencies!)
        : isCaseSave ? await handleSaveCase(input, caseWriteDependencies!)
          : isUpload ? await handleUploadEvidence({ ...input, signal: controller.signal }, evidenceWriteDependencies!)
            : await handleDeleteEvidence({ ...input, signal: controller.signal }, evidenceWriteDependencies!);
      sendJson(response, result.status, result.body, result.headers);
    } finally {
      response.off('close', onClose);
    }
    return;
  }
  if (exportRoute) {
    const result = await handleDraftExport(input, exportDependencies!, exportRoute, exportVersion);
    if (result.body instanceof Uint8Array) {
      if (!response.destroyed && !response.writableEnded) {
        response.writeHead(result.status, result.headers);
        response.end(result.body);
      }
    } else sendJson(response, result.status, result.body, result.headers);
    return;
  }
  const result = isCaseRead ? await handleReadCase(input, dependencies)
    : isFormRead ? await (request.url?.startsWith('/v2/') ? handleReadFormAnswersV2 : handleReadFormAnswers)(input, formAnswerDependencies!)
      : isFormSave ? await (request.url?.startsWith('/v2/') ? handleSaveFormAnswersV2 : handleSaveFormAnswers)(input, formAnswerDependencies!)
        : isPacketRequest ? await handlePreparePacket(input, packetDependencies!)
          : await handleMatchCase(input, dependencies);
  sendJson(response, result.status, result.body, result.headers);
}
