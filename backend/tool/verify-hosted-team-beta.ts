import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';
import { PDFArray, PDFDocument, PDFRawStream, decodePDFRawStream } from 'pdf-lib';
import { hostedApiEnvironment } from './verify-hosted-api.ts';
import type { HostedApiConfiguration } from '../src/auth/hosted-api-verifier.ts';
import { createSupabaseAuthenticator } from '../src/auth/supabase-auth.ts';
import { validateRemoteApiOrigin, validateTestAccounts } from '../src/auth/live-session-verifier.ts';
import { isNewCaseId, parseWrittenCase } from '../src/cases/validation.ts';
import type { CaseDraft } from '../src/cases/types.ts';
import type { CaseSnapshot } from '../src/types.ts';
import { canonicalJson, caseFingerprint, parseEvidenceDescriptor } from '../src/evidence/validation.ts';
import { parseAssessmentRecord, parseAssessmentMetadata, hash, type AssessmentMetadata, type AssessmentState } from '../src/assessment/metadata.ts';
import { parseAnnotations, type AnnotationRecord } from '../src/assessment/annotations.ts';
import { intakeDefinition, parseSavedProgramIntake, type IntakeAnswer } from '../src/programs/intake.ts';
import { createFormAnswerContext, formAnswerFieldsForProgram, formArtifactKind, parseSavedFormAnswers } from '../src/forms/form-answers.ts';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import { MAX_EXPORT_BYTES, parseStoredExportArtifactMetadata } from '../src/exports/validation.ts';
import type { ExportArtifactMetadata } from '../src/exports/types.ts';
import { createDemoEvidenceImage } from '../fixtures/demo-evidence.ts';

const PROGRAMS = ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair'] as const;
const MAX_REQUESTS = 100, MAX_DURATION_MS = 240_000, PACE_MS = 1200;
const MAX_PDF_BYTES = Math.min(MAX_EXPORT_BYTES, 4 * 1024 * 1024);
const sha = (value: string | Uint8Array) => createHash('sha256').update(value).digest('hex');
const same = (a: unknown, b: unknown) => canonicalJson(a) === canonicalJson(b);
function requireValue(value: unknown): asserts value { if (!value) throw new Error('Unexpected acceptance result.'); }
function object(value: unknown): Record<string, any> {
  requireValue(value !== null && typeof value === 'object' && !Array.isArray(value)); return value as Record<string, any>;
}
export interface TeamBetaConfiguration extends HostedApiConfiguration { newCaseId: string; runId: string }
export interface TeamBetaEvent {
  stage: string; state: 'intent' | 'confirmed' | 'failed'; caseId: string;
  ownerHash?: string; caseRevision?: number; caseFingerprint?: string; catalogRevision?: number;
  mutationId?: string; requestHash?: string; artifactId?: string; cleanupPending?: boolean; mutationUncertain?: boolean;
  sessionCleanupFailed?: boolean;
}
export interface TeamBetaReport {
  status: 'passed'; programs: readonly string[]; requests: number; elapsedMs: number;
  pdfCount: 3; generatedPhotoCount: 1; metadataHistoryVerified: true; exactRetriesVerified: true;
  ownerIsolationVerified: true; staleDownloadsDenied: true; annotationsBakedIntoPdfs: true;
  intakeUnknownFalseZeroPreserved: true; protectedFieldsUnresolved: true;
  caseDeleted: true; localSignOuts: 2;
}
export class TeamBetaVerificationError extends Error {
  readonly stage: string; readonly mutationUncertain: boolean; readonly cleanupPending: boolean; readonly sessionCleanupFailed: boolean;
  constructor(stage: string, mutationUncertain = false, cleanupPending = false, sessionCleanupFailed = false) {
    super(`Hosted team beta check failed at ${stage}.${mutationUncertain ? ' A write may have completed; inspect the private journal before recovery.' : ''}${cleanupPending ? ' The new test case is retained for guarded recovery.' : ''}${sessionCleanupFailed ? ' Session cleanup was not fully confirmed.' : ''}`);
    this.name = 'TeamBetaVerificationError'; this.stage = stage; this.mutationUncertain = mutationUncertain;
    this.cleanupPending = cleanupPending; this.sessionCleanupFailed = sessionCleanupFailed;
  }
}
export function fictionalTeamDraft(caseId: string): CaseDraft {
  return { schemaVersion: '1', caseId, profile: { city: null, county: null, healthPlan: null, tenure: null,
    ageYears: null, householdSize: null, annualIncomeUsd: 0, ownerConsentReported: false }, unresolvedFields: [], findings: [] };
}

export async function createTeamBetaJournal(directory: string, initial: {
  apiOrigin: string; projectOrigin: string; caseId: string; runId: string;
}) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await lstat(directory); requireValue(stat.isDirectory() && !stat.isSymbolicLink() && (stat.mode & 0o077) === 0);
  const handle = await open(join(directory, 'hosted-team-beta-check.jsonl'), 'ax', 0o600);
  try {
    await handle.writeFile(`${JSON.stringify({ schemaVersion: '1', kind: 'retained-identifiers', ...initial })}\n`); await handle.sync();
    const parent = await open(directory, constants.O_RDONLY | constants.O_NOFOLLOW);
    try { await parent.sync(); } finally { await parent.close(); }
  } catch (error) { await handle.close(); throw error; }
  return {
    async journal(event: Readonly<TeamBetaEvent>) { await handle.writeFile(`${JSON.stringify(event)}\n`); await handle.sync(); },
    async report(report: TeamBetaReport) { await handle.writeFile(`${JSON.stringify({ kind: 'report', ...report })}\n`); await handle.sync(); },
    close: () => handle.close(),
  };
}

interface Wire { status: number; headers: Headers; body: unknown; bytes: Uint8Array | null }
async function wire(fetcher: typeof fetch, url: string, headers: Record<string, string>, body: unknown, timeout: number, pdf = false,
  onParsedJson?: (body: unknown, status: number) => void): Promise<Wire> {
  const controller = new AbortController(); let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let stream: ReadableStream<Uint8Array> | null = null, active = true;
  const cancel = () => { try { void (reader ? reader.cancel() : stream?.cancel())?.catch(() => {}); } catch {   } };
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<never>((_, reject) => { timer = setTimeout(() => { active = false; controller.abort(); cancel(); reject(new Error()); }, timeout); });
  try {
    return await Promise.race([deadline, (async () => {
      const response = await fetcher(url, { method: 'POST', headers: { 'Content-Type': 'application/json',
        Accept: pdf ? 'application/pdf' : 'application/json', ...headers }, body: JSON.stringify(body), redirect: 'error', cache: 'no-store', signal: controller.signal });
      stream = response.body; requireValue(active && !response.redirected && (response.url === '' || response.url === url));
      if (response.status === 204) return { status: 204, headers: response.headers, body: null, bytes: null };
      const binary = pdf && response.status === 200, maximum = binary ? MAX_PDF_BYTES : 320 * 1024;
      requireValue(stream && response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() === (binary ? 'application/pdf' : 'application/json'));
      const length = response.headers.get('content-length'); requireValue(length === null || /^\d{1,10}$/.test(length) && Number(length) <= maximum);
      reader = stream.getReader(); const parts: Uint8Array[] = []; let size = 0;
      while (true) { const part = await reader.read(); requireValue(active); if (part.done) break;
        requireValue(part.value instanceof Uint8Array && part.value.length <= maximum - size); parts.push(part.value); size += part.value.length; }
      const bytes = Buffer.concat(parts, size);
      const parsed: unknown = binary ? null : JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      if (!binary) onParsedJson?.(parsed, response.status);
      const encoding = response.headers.get('content-encoding')?.trim().toLowerCase();
      const encoded = encoding !== undefined && encoding !== '' && encoding !== 'identity';
      requireValue(encoded || length === null || Number(length) === size);
      return { status: response.status, headers: response.headers, body: parsed, bytes: binary ? bytes : null };
    })()]);
  } finally { active = false; clearTimeout(timer!); controller.abort(); cancel(); }
}
function errorIs(r: Wire, status: number, code: string) {
  const body = object(r.body), error = object(body.error);
  requireValue(r.status === status && ['1', '2'].includes(body.schemaVersion) && error.code === code && typeof error.message === 'string');
}
function assessment(value: unknown, caseId: string): AssessmentState {
  const v = object(value), snapshot = parseWrittenCase(v.case), record = parseAssessmentRecord(v.assessment);
  requireValue(v.schemaVersion === '2' && snapshot.caseId === caseId && record.caseId === caseId && record.caseRevision <= snapshot.revision
    && v.caseFingerprint === caseFingerprint(snapshot) && Number.isSafeInteger(v.catalogRevision) && v.catalogRevision >= 0
    && (v.acknowledgedMutationId === null || typeof v.acknowledgedMutationId === 'string'));
  return { schemaVersion: '2', case: snapshot, caseFingerprint: v.caseFingerprint, catalogRevision: v.catalogRevision,
    assessment: record, acknowledgedMutationId: v.acknowledgedMutationId };
}
async function verifyPdf(bytes: Uint8Array, program: string, basePages: number) {
  requireValue(Buffer.from(bytes.subarray(0, 5)).toString('ascii') === '%PDF-');
  const pdf = await PDFDocument.load(bytes); requireValue(pdf.getPageCount() >= basePages + 2 && pdf.getPageCount() <= basePages + 8 && pdf.getForm().getFields().length === 0);
  const content = (index: number) => { const page = pdf.getPage(index), refs = page.node.Contents(); requireValue((page.node.Annots()?.size() ?? 0) === 0);
    return (refs instanceof PDFArray ? refs.asArray() : [refs]).map(ref => { const stream = pdf.context.lookup(ref); requireValue(stream instanceof PDFRawStream);
      return Buffer.from(decodePDFRawStream(stream).decode()).toString('latin1'); }).join('\n'); };
  for (let i = 0; i < basePages; i++) content(i);
  const contains = (operators: string, text: string) => operators.includes(Buffer.from(text).toString('hex').toUpperCase());
  const image = content(basePages); requireValue(contains(image, '1: Fictional step marker') && /0\.7 0\.08 0\.08 RG/.test(image) && /1\.5 w/.test(image));
  const appendix = Array.from({ length: pdf.getPageCount() - basePages - 1 }, (_, i) => content(basePages + 1 + i)).join('\n');
  for (const text of ['PROGRAM PREPARATION - REPORTED FACTS ONLY', 'Reported No', 'Unknown / not provided', 'The case changed after these answers were saved.']) requireValue(contains(appendix, text));
  if (program === 'rtp-home-repair') requireValue(contains(appendix, 'App-generated worksheet; not an official RTP application.') && contains(appendix, 'Reported: Fictional repair discussion only.'));
  else requireValue(contains(appendix, 'Reported USD 0.00'));
}

export async function verifyHostedTeamBeta(input: TeamBetaConfiguration, options: {
  journal(event: Readonly<TeamBetaEvent>): Promise<void>; fetchImpl?: typeof fetch;
  testNoPacing?: boolean;
}): Promise<TeamBetaReport> {
  let config: TeamBetaConfiguration;
  try {
    requireValue(typeof options.journal === 'function' && (!options.testNoPacing || options.fetchImpl !== undefined));
    requireValue(isNewCaseId(input.newCaseId) && isNewCaseId(input.runId) && input.caseIds.length === 2
      && input.caseIds.every(id => typeof id === 'string' && id.length > 0 && id !== input.newCaseId) && input.caseIds[0] !== input.caseIds[1]);
    config = { ...input, apiOrigin: validateRemoteApiOrigin(input.apiOrigin), accounts: validateTestAccounts(input.accounts), auth: { ...input.auth }, caseIds: [...input.caseIds] };
    createSupabaseAuthenticator(config.auth);
  } catch { throw new TeamBetaVerificationError('configuration'); }
  const started = performance.now(), fetchImpl = options.fetchImpl ?? fetch;
  let requests = 0, nextApiAt = 0, stage = 'configuration', cleanupMode = false;
  let uncertain = false, created = false, deleted = false, signOutFailed = false, unknownSignIn = false;
  let snapshot: CaseSnapshot | null = null, catalog = 0, ownerHash = '', failureStage: string | null = null;
  const tokens: string[] = [], artifacts: ExportArtifactMetadata[] = [];
  const journal = (state: TeamBetaEvent['state'], extra: Partial<TeamBetaEvent> = {}) => options.journal(Object.freeze({ stage, state, caseId: config.newCaseId, ...extra }));
  const remaining = () => MAX_DURATION_MS - (performance.now() - started);
  const transport: typeof fetch = async (url, init) => {
    requireValue(requests < MAX_REQUESTS && remaining() > 0); requests++;
    return fetchImpl(url, init);
  };
  const provider = (path: string, body: unknown, access?: string, onParsedJson?: (body: unknown, status: number) => void) => wire(transport,
    `${new URL(config.auth.projectUrl).origin}/auth/v1/${path}`, { apikey: config.auth.publishableKey,
      ...(access ? { Authorization: `Bearer ${access}` } : {}) }, body, Math.min(5000, Math.max(1, remaining())), false, onParsedJson);
  const api = async (path: string, body: unknown, who = 0, pdf = false) => {
    requireValue(remaining() > (cleanupMode ? 0 : 30_000));
    const delay = nextApiAt - performance.now(); if (delay > 0) await pause(delay);
    requireValue(remaining() > (cleanupMode ? 0 : 30_000));
    nextApiAt = performance.now() + (options.testNoPacing ? 0 : PACE_MS);
    const result = await wire(transport, `${config.apiOrigin}/${path}`, { Authorization: `Bearer ${tokens[who]}` }, body,
      Math.min(30_000, Math.max(1, remaining() - (cleanupMode ? 0 : 30_000))), pdf);
    requireValue(result.headers.get('cache-control')?.split(',').some(x => x.trim().toLowerCase() === 'no-store'));
    return result;
  };
  const read = async (path: string, body: unknown, who = 0) => { const r = await api(path, body, who); requireValue(r.status === 200); return object(r.body); };
  const base = (version = '2') => ({ schemaVersion: version, caseId: config.newCaseId, expectedCaseRevision: snapshot!.revision });
  const confirmedSnapshot = async (expectedRevision: number) => {
    const next = parseWrittenCase(await read('v1/read-case', { schemaVersion: '1', caseId: config.newCaseId }));
    requireValue(next.caseId === config.newCaseId && next.revision === expectedRevision && snapshot !== null
      && same(next.profile, snapshot.profile) && same(next.findings, snapshot.findings) && same(next.unresolvedFields, snapshot.unresolvedFields)); snapshot = next;
  };
  const mutation = async <T>(request: unknown, work: () => Promise<T>): Promise<T> => {
    await journal('intent', { requestHash: hash(request), ...(snapshot ? { caseRevision: snapshot.revision, caseFingerprint: caseFingerprint(snapshot), catalogRevision: catalog } : {}) });
    uncertain = true; const result = await work();
    await journal('confirmed', { ...(snapshot ? { caseRevision: snapshot.revision, caseFingerprint: caseFingerprint(snapshot), catalogRevision: catalog } : {}) });
    uncertain = false; return result;
  };
  try {
    const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
    const registry = await bundle.loadRegistry();
    const image = await createDemoEvidenceImage(); requireValue(image.bytes.length <= 64 * 1024 && image.width === 320 && image.height === 200);
    await journal('confirmed'); stage = 'sign_in';
    for (const account of config.accounts) {
      let retainedAccess: string | null = null;
      unknownSignIn = true; const response = await provider('token?grant_type=password', account, undefined, (body, status) => {
        if (status !== 200 || body === null || typeof body !== 'object' || Array.isArray(body)) return;
        const access = (body as Record<string, unknown>).access_token;
        if (typeof access === 'string' && access.length <= 4096 && /^[A-Za-z0-9._~+/-]+=*$/.test(access)) {
          tokens.push(access); retainedAccess = access; unknownSignIn = false;
        }
      });
      if (response.status >= 400 && response.status < 500) unknownSignIn = false;
      const value = object(response.body); requireValue(response.status === 200 && value.token_type === 'bearer'
        && retainedAccess !== null && value.access_token === retainedAccess);
    }
    stage = 'identity'; const authenticate = createSupabaseAuthenticator(config.auth, transport);
    const alice = await authenticate(tokens[0]), bob = await authenticate(tokens[1]); requireValue(alice && bob && alice.userId !== bob.userId);
    ownerHash = sha(alice.userId); await journal('confirmed', { ownerHash });
    stage = 'existing_fixture_guards';
    for (let i = 0; i < 2; i++) {
      const retained = { schemaVersion: '1', caseId: config.caseIds[i] };
      requireValue(parseWrittenCase(await read('v1/read-case', retained, i)).caseId === config.caseIds[i]);
      errorIs(await api('v1/read-case', retained, 1 - i), 404, 'CASE_NOT_FOUND');
    }
    errorIs(await api('v1/read-case', { schemaVersion: '1', caseId: config.newCaseId }), 404, 'CASE_NOT_FOUND');
    stage = 'create_case'; const draft = fictionalTeamDraft(config.newCaseId);
    await mutation(draft, async () => { const v = parseWrittenCase(await read('v1/create-case', draft));
      requireValue(same(v, { ...draft, revision: 1 })); snapshot = v; created = true; });
    stage = 'assessment'; const initial = assessment(await read('v2/read-assessment', { schemaVersion: '2', caseId: config.newCaseId }), config.newCaseId);
    requireValue(initial.assessment.assessmentRevision === 0 && initial.catalogRevision === 0 && same(initial.case, snapshot));
    const evidenceId = `${config.runId}-photo`, findingId = `${config.runId}-finding`;
    const assessed: CaseDraft = { ...draft, findings: [{ id: findingId, room: 'entrance', observation: 'Fictional generated step for hosted acceptance.', reviewState: 'confirmed', evidenceIds: [evidenceId],
      measurements: [{ type: 'thresholdHeight', value: 12.7, unit: 'mm', method: 'manual', confirmed: true }, { type: 'clearOpening', value: 25, unit: 'mm', method: 'manual', confirmed: true }] }] };
    const metadata: AssessmentMetadata = { measurements: [
      { findingId, type: 'thresholdHeight', originalText: ' .5 ', originalUnit: 'in', decimalSeparator: 'point', source: 'manual', recorder: 'self', recordedAt: null },
      { findingId, type: 'clearOpening', originalText: ' 0002,5 ', originalUnit: 'cm', decimalSeparator: 'comma', source: 'manual', recorder: 'helper', recordedAt: null }],
      reviews: [{ findingId, state: 'confirmed', note: 'Fictional review only.' }] };
    const save = { schemaVersion: '2', caseId: config.newCaseId, expectedCaseRevision: 1, expectedCaseFingerprint: initial.caseFingerprint,
      expectedCatalogRevision: 0, expectedAssessmentRevision: 0, mutationId: config.runId, draft: assessed, metadata };
    let saved!: AssessmentState;
    await mutation(save, async () => { saved = assessment(await read('v2/save-assessment', save), config.newCaseId);
      requireValue(same(saved.case, { ...assessed, revision: 2 }) && saved.acknowledgedMutationId === config.runId
        && saved.assessment.assessmentRevision === 1 && same(saved.assessment.metadata, metadata) && saved.assessment.history[0].recordedBy === alice.userId
        && saved.assessment.history[0].requestHash === hash(save)); parseAssessmentMetadata(saved.assessment.metadata, saved.case); snapshot = saved.case; });
    stage = 'assessment_exact_retry';
    await mutation(save, async () => { requireValue(same(assessment(await read('v2/save-assessment', save), config.newCaseId), saved)); });
    const conflicting = { ...save, metadata: { ...metadata, reviews: [{ findingId, state: 'confirmed', note: 'Different fictional text.' }] } };
    await mutation(conflicting, async () => errorIs(await api('v2/save-assessment', conflicting), 409, 'ASSESSMENT_MUTATION_CONFLICT'));
    errorIs(await api('v2/read-assessment', { schemaVersion: '2', caseId: config.newCaseId }, 1), 404, 'CASE_NOT_FOUND');
    stage = 'photo'; const upload = { ...base('1'), expectedCatalogRevision: 0, evidenceId, expectedEvidenceRevision: 0, findingId, capturedAt: null, imageBase64: Buffer.from(image.bytes).toString('base64') };
    let descriptor!: ReturnType<typeof parseEvidenceDescriptor>;
    await mutation(upload, async () => { const v = await read('v1/upload-evidence', upload); descriptor = parseEvidenceDescriptor(v.evidence);
      requireValue(v.caseId === config.newCaseId && v.caseRevision === snapshot!.revision && v.catalogRevision === 1 && descriptor.caseId === config.newCaseId
        && descriptor.evidenceId === evidenceId && descriptor.findingId === findingId && descriptor.evidenceRevision === 1 && descriptor.width === 320 && descriptor.height === 200); catalog = v.catalogRevision; });
    let annotation!: AnnotationRecord;
    const marks = [{ id: 'fictional-box', rect: [100000, 200000, 400000, 300000], label: 'Fictional step marker' }];
    const annotationRead = () => ({ ...base(), expectedCatalogRevision: catalog, evidenceId, expectedEvidenceRevision: descriptor.evidenceRevision });
    const readAnnotation = async () => { const v = await read('v2/read-evidence-annotations', annotationRead()); const a = parseAnnotations(v.annotation);
      requireValue(v.caseId === config.newCaseId && v.caseRevision === snapshot!.revision && v.catalogRevision === catalog && a.caseId === config.newCaseId && a.evidenceId === evidenceId
        && a.evidenceRevision === descriptor.evidenceRevision && a.imageSha256 === descriptor.sha256 && a.imageWidth === descriptor.width && a.imageHeight === descriptor.height); annotation = a; };
    const saveAnnotation = async (reviewed: boolean) => { const request = { ...annotationRead(), expectedAnnotationRevision: annotation.annotationRevision,
      expectedImageSha256: descriptor.sha256, expectedImageWidth: descriptor.width, expectedImageHeight: descriptor.height, marks, reviewedForExport: reviewed };
      await mutation(request, async () => { const v = await read('v2/save-evidence-annotations', request), a = parseAnnotations(v.annotation);
        requireValue(v.caseId === config.newCaseId && v.caseRevision === snapshot!.revision && v.catalogRevision === catalog + 1 && a.caseId === config.newCaseId && a.evidenceId === evidenceId
          && a.annotationRevision === annotation.annotationRevision + 1 && same(a.marks, marks) && a.imageSha256 === descriptor.sha256
          && a.reviewState === (reviewed ? 'reviewed' : 'needs_review') && a.reviewedBy === (reviewed ? alice.userId : null)
          && a.reviewedCaseRevision === (reviewed ? snapshot!.revision : null)); annotation = a; catalog = v.catalogRevision; }); };
    stage = 'annotations'; await readAnnotation(); requireValue(annotation.annotationRevision === 0); await saveAnnotation(false);
    errorIs(await api('v2/read-evidence-annotations', annotationRead(), 1), 404, 'CASE_NOT_FOUND');
    for (const program of PROGRAMS) {
      const pinnedProgram = registry.find(p => p.programId === program); requireValue(pinnedProgram);
      stage = `${program}_intake`; const definition = intakeDefinition(program)!;
      const input = { ...base(), programId: program }, intake = await read('v2/read-program-intake', input);
      requireValue(intake.schemaVersion === '2' && intake.caseId === config.newCaseId && same(intake.definition, definition)
        && intake.saved === null && intake.isCurrent === false && intake.caseRevision === snapshot!.revision);
      errorIs(await api('v2/read-program-intake', input, 1), 404, 'CASE_NOT_FOUND');
      let firstBoolean = true, firstMoney = true;
      const answers: IntakeAnswer[] = definition.questions.map(q => { let value: IntakeAnswer['value'] = null;
        if (q.kind === 'boolean' && firstBoolean) { value = false; firstBoolean = false; }
        if (q.kind === 'money' && firstMoney) { value = 0; firstMoney = false; }
        if (q.kind === 'text') value = 'Fictional repair discussion only.';
        return { key: q.key, value, reviewState: value === null ? 'unknown' : 'reported' }; });
      const intakeRequest = { ...input, expectedIntakeRevision: 0, expectedQuestionnaireVersion: definition.questionnaireVersion, answers };
      await mutation(intakeRequest, async () => { const v = await read('v2/save-program-intake', intakeRequest), s = parseSavedProgramIntake(v.saved);
        requireValue(v.schemaVersion === '2' && v.caseId === config.newCaseId && v.caseRevision === snapshot!.revision + 1 && v.isCurrent === true && same(v.definition, definition)
          && s.caseId === config.newCaseId && s.caseRevision === v.caseRevision && s.programId === program && s.updatedBy === alice.userId && s.intakeRevision === 1 && same(s.answers, answers)); await confirmedSnapshot(v.caseRevision); });
      stage = `${program}_form`; const pinned = await bundle.loadFormTemplate(program); requireValue(pinned);
      const context = createFormAnswerContext(pinned.template), formRead = { ...base(), programId: program };
      const form = await read('v2/read-form-answers', formRead);
      requireValue(form.schemaVersion === '2' && form.caseId === config.newCaseId && form.caseRevision === snapshot!.revision && same(form.context, context) && form.saved === null
        && form.artifactKind === formArtifactKind(program) && same(object(form).fieldDefinitions.map((f: any) => ({ key: f.key, kind: f.kind, maxLength: f.maxLength })),
          formAnswerFieldsForProgram(program).map(f => ({ key: f.key, kind: f.kind, maxLength: f.maxLength }))));
      errorIs(await api('v2/read-form-answers', formRead, 1), 404, 'CASE_NOT_FOUND');
      const formRequest = { ...formRead, expectedFormContextId: context.formContextId, expectedAnswerRevision: 0, answers: [{ key: 'memberFirstName', value: 'Alex', reviewState: 'reviewed' }] };
      await mutation(formRequest, async () => { const v = await read('v2/save-form-answers', formRequest), s = parseSavedFormAnswers(v.saved);
        requireValue(v.caseId === config.newCaseId && v.caseRevision === snapshot!.revision + 1 && v.isCurrent === true && same(v.context, context)
          && s.caseId === config.newCaseId && s.caseRevision === v.caseRevision && s.programId === program && s.answerRevision === 1 && s.updatedBy === alice.userId
          && s.answers.length === 1 && s.answers[0].value === 'Alex' && s.answers[0].reviewedBy === alice.userId && s.formContextId === context.formContextId); await confirmedSnapshot(v.caseRevision); });
      const staleIntake = await read('v2/read-program-intake', { ...base(), programId: program });
      requireValue(staleIntake.isCurrent === false && same(parseSavedProgramIntake(staleIntake.saved).answers, answers));
      stage = `${program}_export`;
      const exportRequest = () => ({ ...base(), programId: program, expectedFormContextId: context.formContextId, expectedAnswerRevision: 1,
        expectedEvidenceCatalogRevision: catalog, generationKey: `${config.runId}-${program}`, selectedEvidence: [{ evidenceId, expectedEvidenceRevision: descriptor.evidenceRevision,
          expectedAnnotationRevision: annotation.annotationRevision, reviewedForExport: true }] });
      if (program === PROGRAMS[0]) { const blocked = exportRequest(); await mutation(blocked, async () => errorIs(await api('v2/create-draft-export', blocked), 422, 'ANNOTATION_REVIEW_REQUIRED')); }
      await readAnnotation(); await saveAnnotation(true);
      const request = exportRequest(); let artifact!: ExportArtifactMetadata;
      await mutation(request, async () => { artifact = parseStoredExportArtifactMetadata(await read('v2/create-draft-export', request));
        const protectedIndices = pinned.template.fields.flatMap((field, index) => ['clinical', 'consent', 'signature'].includes(field.semantic)
          && !(field.binding.kind === 'manual' && field.binding.reason === 'out_of_scope') ? [index] : []);
        requireValue(artifact.schemaVersion === '2' && artifact.caseId === config.newCaseId && artifact.caseRevision === snapshot!.revision && artifact.programId === program
          && artifact.ruleVersion === pinnedProgram.ruleVersion && artifact.formContextId === context.formContextId && artifact.formVersion === context.formVersion && artifact.mappingVersion === context.mappingVersion
          && artifact.answerRevision === 1 && artifact.evidenceCatalogRevision === catalog && artifact.status === 'draft' && artifact.isDemo === false
          && artifact.renderingVersion === 'draft-export-annotations-v2' && artifact.selectedEvidence.length === 1 && artifact.selectedEvidence[0].annotationRevision === annotation.annotationRevision
          && artifact.selectedEvidence[0].reviewedBy === alice.userId && artifact.selectedEvidence[0].evidenceId === evidenceId && artifact.selectedEvidence[0].sha256 === descriptor.sha256
          && ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', 'POLICY_CURRENTNESS_UNKNOWN'].every(w => artifact.warnings.includes(w as any))
          && protectedIndices.every(i => artifact.missingItems.some(item => item.id === `form-field:${i}`))); });
      stage = `${program}_export_exact_retry`;
      await mutation(request, async () => requireValue(same(parseStoredExportArtifactMetadata(await read('v2/create-draft-export', request)), artifact)));
      stage = `${program}_download`; const download = { ...base(), artifactId: artifact.artifactId };
      const pdf = await api('v2/download-draft-export', download, 0, true);
      requireValue(pdf.status === 200 && pdf.bytes && pdf.bytes.length === artifact.byteLength && sha(pdf.bytes) === artifact.sha256
        && pdf.headers.get('x-content-sha256') === artifact.sha256 && pdf.headers.get('x-content-type-options') === 'nosniff');
      await verifyPdf(pdf.bytes, program, pinned.template.pageCount);
      errorIs(await api('v2/download-draft-export', download, 1, true), 404, 'ARTIFACT_NOT_FOUND'); artifacts.push(artifact);
    }
    stage = 'cross_device_metadata'; const resumed = assessment(await read('v2/read-assessment', { schemaVersion: '2', caseId: config.newCaseId }), config.newCaseId);
    requireValue(same(resumed.case, snapshot) && same(resumed.assessment.metadata, metadata) && resumed.assessment.caseRevision === 2 && resumed.assessment.history.length === 1);
    const corrected = { ...metadata, reviews: [{ findingId, state: 'confirmed' as const, note: 'Fictional correction review.' }] };
    const correction = { ...save, expectedCaseRevision: snapshot!.revision, expectedCaseFingerprint: caseFingerprint(snapshot!), expectedCatalogRevision: catalog,
      expectedAssessmentRevision: 1, mutationId: `${config.runId}-correction`, metadata: corrected };
    await mutation(correction, async () => { const state = assessment(await read('v2/save-assessment', correction), config.newCaseId);
      requireValue(same(state.case, { ...assessed, revision: snapshot!.revision + 1 }) && state.catalogRevision === catalog && state.acknowledgedMutationId === correction.mutationId
        && state.assessment.assessmentRevision === 2 && state.assessment.history[1].recordedBy === alice.userId && state.assessment.history[1].requestHash === hash(correction)
        && same(state.assessment.metadata, corrected) && same(state.assessment.history[0], saved.assessment.history[0])); snapshot = state.case; });
    stage = 'stale_downloads'; for (const artifact of artifacts) errorIs(await api('v2/download-draft-export', {
      schemaVersion: '2', caseId: config.newCaseId, expectedCaseRevision: artifact.caseRevision, artifactId: artifact.artifactId }, 0, true), 409, 'CASE_REVISION_MISMATCH');
    stage = 'cleanup_guards'; cleanupMode = true;
    const current = parseWrittenCase(await read('v1/read-case', { schemaVersion: '1', caseId: config.newCaseId }));
    const currentCatalog = await read('v1/list-evidence', base('1'));
    const known = snapshot as CaseSnapshot | null;
    requireValue(created && !uncertain && known && sha(alice.userId) === ownerHash && current.caseId === config.newCaseId
      && caseFingerprint(current) === caseFingerprint(known) && currentCatalog.catalogRevision === catalog
      && currentCatalog.caseRevision === known.revision && currentCatalog.caseId === config.newCaseId && !config.caseIds.includes(config.newCaseId));
    stage = 'delete_test_case'; const remove = { ...base('1'), expectedCatalogRevision: catalog, confirmation: 'DELETE_CASE' };
    await mutation(remove, async () => { const v = await read('v1/delete-case', remove); requireValue(v.schemaVersion === '1' && v.caseId === config.newCaseId && v.deleted === true); deleted = true; });
    errorIs(await api('v1/read-case', { schemaVersion: '1', caseId: config.newCaseId }), 404, 'CASE_NOT_FOUND');
  } catch { failureStage = stage; }
  finally {
    cleanupMode = true;
    for (const token of tokens) { try { requireValue((await provider('logout?scope=local', {}, token)).status === 204); } catch { signOutFailed = true; } }
    if (unknownSignIn) signOutFailed = true;
    if (failureStage || signOutFailed) {
      stage = failureStage ?? 'sign_out';
      try { await journal('failed', { mutationUncertain: uncertain, cleanupPending: !deleted && (created || uncertain), sessionCleanupFailed: signOutFailed }); } catch {   }
    }
  }
  if (failureStage || signOutFailed) throw new TeamBetaVerificationError(failureStage ?? 'sign_out', uncertain, !deleted && (created || uncertain), signOutFailed);
  stage = 'complete'; await journal('confirmed');
  return { status: 'passed', programs: PROGRAMS, requests, elapsedMs: Math.round(performance.now() - started), pdfCount: 3, generatedPhotoCount: 1,
    metadataHistoryVerified: true, exactRetriesVerified: true, ownerIsolationVerified: true, staleDownloadsDenied: true, annotationsBakedIntoPdfs: true,
    intakeUnknownFalseZeroPreserved: true, protectedFieldsUnresolved: true, caseDeleted: true, localSignOuts: 2 };
}

async function main() {
  if (process.argv.length !== 3 || process.argv[2] !== '--create-fictional-case') throw new TeamBetaVerificationError('configuration');
  const config: TeamBetaConfiguration = { ...await hostedApiEnvironment(process.env), newCaseId: randomUUID(), runId: randomUUID() };
  const local = await createTeamBetaJournal(fileURLToPath(new URL('../local-artifacts/hosted-team-beta/', import.meta.url)), {
    apiOrigin: config.apiOrigin, projectOrigin: new URL(config.auth.projectUrl).origin, caseId: config.newCaseId, runId: config.runId });
  try { const report = await verifyHostedTeamBeta(config, local); await local.report(report); console.log(JSON.stringify(report)); }
  finally { await local.close(); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) main().catch(error => {
  console.error(error instanceof TeamBetaVerificationError ? error.message : 'Hosted team beta check could not finish. Inspect the private journal before recovery; no sensitive details logged.'); process.exitCode = 1;
});
