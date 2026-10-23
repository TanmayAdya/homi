import { createHash } from 'node:crypto';
import { PDFDocument } from 'pdf-lib';
import { createSupabaseAuthenticator, type SupabaseAuthConfig } from './supabase-auth.ts';
import { validateRemoteApiOrigin, validateTestAccounts, type TestAccount } from './live-session-verifier.ts';
import { isNewCaseId, parseWrittenCase } from '../cases/validation.ts';
import { canonicalJson, evidenceIdentifier } from '../evidence/validation.ts';
import { matchPrograms } from '../matcher.ts';
import { createScfhpEaaResearchProgram } from '../programs/scfhp-eaa.ts';
import { createScfhpEaaFormTemplate } from '../forms/scfhp-eaa-template.ts';
import { createFormAnswerContext, parseFormAnswerInputs, parseSavedFormAnswers, type FormAnswerInput } from '../forms/form-answers.ts';
import { planPacketWithForm } from '../forms/prepare-form-packet.ts';
import { MAX_EXPORT_BYTES, parseExportArtifactMetadata } from '../exports/validation.ts';

export interface HostedDraftConfiguration {
  apiOrigin: string; auth: SupabaseAuthConfig; accounts: readonly [TestAccount, TestAccount];
  caseId: string; generationKey: string;
}
export type DraftCheckStage = 'configuration' | 'sign_in' | 'identity' | 'create_case' | 'match'
  | 'form_context' | 'save_answers' | 'prepare_packet' | 'catalog' | 'create_export' | 'owner_download'
  | 'cross_owner' | 'revise_answers' | 'stale_download' | 'sign_out' | 'complete';
export interface DraftJournalEvent {
  stage: DraftCheckStage; state: 'intent' | 'confirmed' | 'failed'; caseId: string;
  caseRevision?: number; answerRevision?: number; packetId?: string; artifactId?: string; sha256?: string;
  byteLength?: number; pageCount?: number; cleanupFailed?: boolean; mutationUncertain?: boolean;
}
export interface HostedDraftReport {
  status: 'passed'; caseId: string; retainedCase: true; caseRevision: 3; answerRevision: 2;
  artifactId: string; sha256: string; byteLength: number; pageCount: number;
  matchNeedsConfirmation: true; pinnedFormContext: true; checklistVerified: true; incompleteDraft: true;
  notSubmitted: true; policyCurrentnessUnknown: true; protectedFieldsUnresolved: true;
  ownerPdfVerified: true; crossOwnerDenied: true; changedAnswersInvalidateExport: true; localSignOuts: 2;
}
export class HostedDraftVerificationError extends Error {
  readonly stage: DraftCheckStage; readonly cleanupFailed: boolean; readonly mutationUncertain: boolean;
  constructor(stage: DraftCheckStage, cleanupFailed = false, mutationUncertain = false) {
    super(`Hosted draft verification failed at ${stage}.${mutationUncertain ? ' A write outcome is uncertain; inspect the retained journal before recovery.' : ''}${cleanupFailed ? ' Session cleanup could not be fully confirmed.' : ''}`);
    this.name = 'HostedDraftVerificationError'; this.stage = stage; this.cleanupFailed = cleanupFailed; this.mutationUncertain = mutationUncertain;
  }
}
const fail = (stage: DraftCheckStage): never => { throw new HostedDraftVerificationError(stage); };
const record = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === 'object' && !Array.isArray(value);
const exact = (value: unknown, keys: string[]): value is Record<string, unknown> => record(value)
  && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
const token = (value: unknown): value is string => typeof value === 'string' && value.length > 0 && value.length <= 4096
  && /^[A-Za-z0-9._~+/-]+=*$/.test(value) && !/\s/.test(value);

export function hostedDraftConfiguration(input: HostedDraftConfiguration): HostedDraftConfiguration {
  try {
    const apiOrigin = validateRemoteApiOrigin(input.apiOrigin);
    createSupabaseAuthenticator(input.auth);
    const accounts = validateTestAccounts(input.accounts);
    if (!isNewCaseId(input.caseId) || input.caseId.length !== 36 || typeof input.generationKey !== 'string'
      || input.generationKey.length < 8 || input.generationKey.length > 128 || /[^A-Za-z0-9_-]/.test(input.generationKey)) return fail('configuration');
    return { apiOrigin, auth: { ...input.auth }, accounts, caseId: input.caseId, generationKey: input.generationKey };
  } catch { return fail('configuration'); }
}

interface WireResponse { status: number; headers: Headers; body: unknown; bytes: Uint8Array | null }
async function wire(fetchImpl: typeof fetch, url: string, headers: Record<string, string>, body: unknown,
  stage: DraftCheckStage, timeoutMs: number, pdf = false): Promise<WireResponse> {
  const controller = new AbortController();
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let stream: ReadableStream<Uint8Array> | null = null;
  let active = true;
  const deadlineAt = performance.now() + timeoutMs;
  const cancel = () => { try { void (reader ? reader.cancel() : stream?.cancel())?.catch(() => {}); } catch {   } };
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { active = false; controller.abort(); cancel(); reject(new HostedDraftVerificationError(stage)); }, timeoutMs);
  });
  const work = async () => {
    const response = await fetchImpl(url, { method: 'POST', headers: { Accept: pdf ? 'application/pdf' : 'application/json',
      'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body), redirect: 'error', cache: 'no-store', signal: controller.signal });
    stream = response.body;
    if (!active || performance.now() >= deadlineAt) { cancel(); return fail(stage); }
    if (response.redirected || (response.url !== '' && response.url !== url)) return fail(stage);
    if (response.status === 204) return { status: 204, headers: response.headers, body: null, bytes: null };
    const isPdf = pdf && response.status === 200;
    const maximum = isPdf ? MAX_EXPORT_BYTES : 64 * 1024;
    if (response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() !== (isPdf ? 'application/pdf' : 'application/json')
      || stream === null) return fail(stage);
    const length = response.headers.get('content-length');
    if (length !== null && (!/^[0-9]+$/.test(length) || length.length > 10 || Number(length) > maximum)) return fail(stage);
    const chunks: Uint8Array[] = []; let size = 0;
    reader = stream.getReader();
    while (true) {
      const part = await reader.read();
      if (!active || performance.now() >= deadlineAt) return fail(stage);
      if (part.done) break;
      if (!(part.value instanceof Uint8Array) || part.value.length > maximum - size) return fail(stage);
      chunks.push(part.value); size += part.value.length;
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return { status: response.status, headers: response.headers, bytes: isPdf ? bytes : null,
      body: isPdf ? null : JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)) as unknown };
  };
  try { return await Promise.race([work(), deadline]); }
  catch { return fail(stage); }
  finally { active = false; clearTimeout(timer!); controller.abort(); cancel(); }
}
function errorIs(response: WireResponse, status: number, code: string): boolean {
  return response.status === status && exact(response.body, ['schemaVersion', 'error']) && response.body.schemaVersion === '1'
    && exact(response.body.error, ['code', 'message']) && response.body.error.code === code && typeof response.body.error.message === 'string';
}
function noStore(headers: Headers): boolean { return headers.get('cache-control')?.split(',').some(value => value.trim().toLowerCase() === 'no-store') ?? false; }

export async function verifyHostedDraft(input: HostedDraftConfiguration, options: {
  journal(event: Readonly<DraftJournalEvent>): Promise<void>;
  onPdf?: (bytes: Uint8Array) => Promise<void>;
  fetchImpl?: typeof fetch;
  requestTimeoutMs?: number;
}): Promise<HostedDraftReport> {
  const config = hostedDraftConfiguration(input);
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  const timeout = options.requestTimeoutMs ?? 30_000;
  if (typeof options.journal !== 'function' || typeof fetchImpl !== 'function'
    || (options.onPdf !== undefined && typeof options.onPdf !== 'function')
    || !Number.isInteger(timeout) || timeout < 1 || timeout > 30_000) return fail('configuration');
  const journalCallback = options.journal, onPdf = options.onPdf;
  const journal = (event: Omit<DraftJournalEvent, 'caseId'>) => journalCallback(Object.freeze({ ...event, caseId: config.caseId }));
  const authenticate = createSupabaseAuthenticator(config.auth, fetchImpl);
  const provider = (path: string, body: unknown, access?: string) => wire(fetchImpl,
    `${new URL(config.auth.projectUrl).origin}/auth/v1/${path}`, { apikey: config.auth.publishableKey,
      ...(access ? { Authorization: `Bearer ${access}` } : {}) }, body, stage, config.auth.timeoutMs ?? 5000);
  const api = async (path: string, access: string, body: unknown, pdf = false) => {
    const response = await wire(fetchImpl, `${config.apiOrigin}/v1/${path}`, { Authorization: `Bearer ${access}` }, body, stage, timeout, pdf);
    if (!noStore(response.headers)) return fail(stage);
    return response;
  };
  const template = createScfhpEaaFormTemplate(), context = createFormAnswerContext(template);
  const program = createScfhpEaaResearchProgram();
  const draft = { schemaVersion: '1' as const, caseId: config.caseId, profile: { city: null, county: null, healthPlan: null,
    tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [], findings: [] };
  const answers: FormAnswerInput[] = [
    { key: 'memberFirstName', value: 'Fixture', reviewState: 'reviewed' },
    { key: 'memberLastName', value: 'Resident', reviewState: 'reviewed' },
    { key: 'memberPhone', value: '202-555-0142', reviewState: 'reviewed' },
    { key: 'memberPreferredSpokenLanguage', value: 'English', reviewState: 'reviewed' },
  ];
  const accessTokens: string[] = [];
  let stage: DraftCheckStage = 'sign_in', failed: DraftCheckStage | null = null;
  let unknownSignIn = false, mutationUncertain = false, cleanupFailed = false;
  let result: Omit<HostedDraftReport, 'localSignOuts'> | null = null;
  try {
    await journal({ stage: 'configuration', state: 'confirmed' });
    for (const account of config.accounts) {
      unknownSignIn = true;
      const response = await provider('token?grant_type=password', account);
      if (response.status >= 400 && response.status < 500) unknownSignIn = false;
      if (response.status !== 200 || !record(response.body) || !token(response.body.access_token)
        || response.body.token_type !== 'bearer') return fail(stage);
      accessTokens.push(response.body.access_token as string); unknownSignIn = false;
    }
    stage = 'identity';
    const alice = await authenticate(accessTokens[0]), bob = await authenticate(accessTokens[1]);
    if (!alice || !bob || alice.userId === bob.userId) return fail(stage);
    const base = (revision: number) => ({ schemaVersion: '1', caseId: config.caseId, expectedCaseRevision: revision });
    stage = 'create_case';
    await journal({ stage, state: 'intent' }); mutationUncertain = true;
    const created = await api('create-case', accessTokens[0], draft);
    if (created.status !== 200 || canonicalJson(parseWrittenCase(created.body)) !== canonicalJson({ ...draft, revision: 1 })) fail(stage);
    mutationUncertain = false; await journal({ stage, state: 'confirmed', caseRevision: 1 });
    stage = 'match';
    const matched = await api('match-case', accessTokens[0], base(1));
    if (matched.status !== 200 || !record(matched.body) || typeof matched.body.evaluatedAt !== 'string' || typeof matched.body.evaluationDate !== 'string') return fail(stage);
    const expectedMatch = matchPrograms({ ...draft, revision: 1 }, [program], { evaluatedAt: matched.body.evaluatedAt as string, evaluationDate: matched.body.evaluationDate as string });
    if (canonicalJson(matched.body) !== canonicalJson(expectedMatch) || expectedMatch.matches[0].status !== 'needs_confirmation') fail(stage);
    await journal({ stage, state: 'confirmed', caseRevision: 1 });
    stage = 'form_context';
    const initial = await api('read-form-answers', accessTokens[0], { ...base(1), programId: program.programId });
    if (!exact(initial.body, ['schemaVersion', 'caseId', 'caseRevision', 'context', 'saved', 'isCurrent']) || initial.status !== 200
      || initial.body.schemaVersion !== '1' || initial.body.caseId !== config.caseId || initial.body.caseRevision !== 1
      || initial.body.saved !== null || initial.body.isCurrent !== false || canonicalJson(initial.body.context) !== canonicalJson(context)) fail(stage);
    const save = async (revision: number, answerRevision: number, replacement: FormAnswerInput[]) => {
      await journal({ stage, state: 'intent', caseRevision: revision, answerRevision }); mutationUncertain = true;
      const response = await api('save-form-answers', accessTokens[0], { ...base(revision), programId: program.programId,
        expectedFormContextId: context.formContextId, expectedAnswerRevision: answerRevision, answers: replacement });
      if (response.status !== 200 || !exact(response.body, ['schemaVersion', 'caseId', 'caseRevision', 'context', 'saved', 'isCurrent'])
        || response.body.schemaVersion !== '1' || response.body.caseId !== config.caseId || response.body.caseRevision !== revision + 1
        || response.body.isCurrent !== true || canonicalJson(response.body.context) !== canonicalJson(context)) return fail(stage);
      const saved = parseSavedFormAnswers(response.body.saved);
      if (saved.caseId !== config.caseId || saved.caseRevision !== revision + 1 || saved.answerRevision !== answerRevision + 1
        || saved.updatedBy !== alice.userId || canonicalJson({ programId: saved.programId, formVersion: saved.formVersion,
          mappingVersion: saved.mappingVersion, formContextId: saved.formContextId }) !== canonicalJson(context)
        || saved.answers.some(answer => answer.reviewedBy !== alice.userId || answer.reviewedAt !== saved.updatedAt)
        || canonicalJson(saved.answers.map(({ key, value, reviewState }) => ({ key, value, reviewState }))) !== canonicalJson(parseFormAnswerInputs(replacement))) fail(stage);
      mutationUncertain = false; await journal({ stage, state: 'confirmed', caseRevision: revision + 1, answerRevision: answerRevision + 1 });
      return saved;
    };
    stage = 'save_answers'; const savedAnswers = await save(1, 0, answers);
    stage = 'prepare_packet';
    await journal({ stage, state: 'intent', caseRevision: 2 }); mutationUncertain = true;
    const packetResponse = await api('prepare-packet', accessTokens[0], { ...base(2), programId: program.programId,
      generationKey: `checklist_${createHash('sha256').update(config.generationKey).digest('hex')}` });
    const packet = packetResponse.body;
    if (packetResponse.status !== 200 || !exact(packet, ['schemaVersion', 'packetId', 'caseId', 'caseRevision', 'programId', 'ruleVersion',
      'formVersion', 'mappingVersion', 'status', 'isDemo', 'generatedAt', 'recheckAfter', 'storageReference', 'attachments', 'missingItems'])
      || packet.schemaVersion !== '1' || !evidenceIdentifier(packet.packetId) || typeof packet.generatedAt !== 'string'
      || packet.caseId !== config.caseId || packet.caseRevision !== 2 || packet.programId !== program.programId || packet.ruleVersion !== program.ruleVersion
      || packet.formVersion !== context.formVersion || packet.mappingVersion !== context.mappingVersion || packet.status !== 'draft'
      || packet.isDemo !== false || packet.recheckAfter !== null || packet.storageReference !== null
      || !Array.isArray(packet.attachments) || packet.attachments.length !== 0 || !Array.isArray(packet.missingItems)
      || !program.criteria.every(criterion => (packet.missingItems as unknown[]).some(item => record(item) && item.id === `check:${criterion.id}`))) return fail(stage);
    const expectedPacket = planPacketWithForm({ ...draft, revision: 2 }, expectedMatch.matches[0],
      { packetId: packet.packetId, generatedAt: packet.generatedAt }, { template, templateSha256: template.templateSha256 }, savedAnswers);
    if (canonicalJson(packet) !== canonicalJson(expectedPacket)) return fail(stage);
    mutationUncertain = false; await journal({ stage, state: 'confirmed', caseRevision: 2, packetId: packet.packetId });
    stage = 'catalog';
    const catalog = await api('list-evidence', accessTokens[0], base(2));
    if (catalog.status !== 200 || canonicalJson(catalog.body) !== canonicalJson({ schemaVersion: '1', caseId: config.caseId,
      caseRevision: 2, catalogRevision: 0, evidence: [] })) fail(stage);
    stage = 'create_export';
    await journal({ stage, state: 'intent', caseRevision: 2, answerRevision: 1 }); mutationUncertain = true;
    const exported = await api('create-draft-export', accessTokens[0], { ...base(2), programId: program.programId,
      expectedFormContextId: context.formContextId, expectedAnswerRevision: 1, expectedEvidenceCatalogRevision: 0,
      generationKey: config.generationKey, selectedEvidence: [] });
    if (exported.status !== 200) fail(stage);
    const artifact = parseExportArtifactMetadata(exported.body);
    const protectedIndices = template.fields.flatMap((field, index) => ['clinical', 'consent', 'signature'].includes(field.semantic)
      && !(field.binding.kind === 'manual' && field.binding.reason === 'out_of_scope') ? [index] : []);
    if (artifact.caseId !== config.caseId || artifact.caseRevision !== 2 || artifact.programId !== program.programId || artifact.ruleVersion !== program.ruleVersion
      || artifact.formVersion !== context.formVersion || artifact.mappingVersion !== context.mappingVersion || artifact.formContextId !== context.formContextId
      || artifact.answerRevision !== 1 || artifact.evidenceCatalogRevision !== 0 || artifact.isDemo || artifact.selectedEvidence.length !== 0
      || artifact.pageCount !== template.pageCount || artifact.recheckAfter !== null
      || canonicalJson(artifact.warnings) !== canonicalJson(['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', 'POLICY_CURRENTNESS_UNKNOWN'])
      || !protectedIndices.every(index => artifact.missingItems.some(item => item.id === `form-field:${index}`))
      || Date.now() >= Date.parse(artifact.expiresAt)) fail(stage);
    mutationUncertain = false;
    await journal({ stage, state: 'confirmed', caseRevision: 2, answerRevision: 1, artifactId: artifact.artifactId,
      sha256: artifact.sha256, byteLength: artifact.byteLength, pageCount: artifact.pageCount });
    const downloadBody = { ...base(2), artifactId: artifact.artifactId };
    stage = 'owner_download';
    const downloaded = await api('download-draft-export', accessTokens[0], downloadBody, true);
    const bytes = downloaded.bytes;
    if (downloaded.status !== 200 || !bytes || bytes.length !== artifact.byteLength
      || downloaded.headers.get('content-length') !== String(bytes.length) || downloaded.headers.get('x-content-type-options') !== 'nosniff'
      || downloaded.headers.get('x-content-sha256') !== artifact.sha256 || createHash('sha256').update(bytes).digest('hex') !== artifact.sha256
      || new TextDecoder().decode(bytes.subarray(0, 5)) !== '%PDF-' || Date.now() >= Date.parse(artifact.expiresAt)) fail(stage);
    const document = await PDFDocument.load(bytes!, { updateMetadata: false });
    if (document.getPageCount() !== artifact.pageCount || document.getForm().getFields().length !== 0) fail(stage);
    if (onPdf) await onPdf(Uint8Array.from(bytes!));
    await journal({ stage, state: 'confirmed', artifactId: artifact.artifactId, sha256: artifact.sha256 });
    stage = 'cross_owner';
    if (!errorIs(await api('download-draft-export', accessTokens[1], downloadBody, true), 404, 'ARTIFACT_NOT_FOUND')) fail(stage);
    await journal({ stage, state: 'confirmed' });
    stage = 'revise_answers';
    await save(2, 1, answers.map(answer => answer.key === 'memberPhone' ? { ...answer, value: '202-555-0143' } : { ...answer }));
    stage = 'stale_download';
    if (!errorIs(await api('download-draft-export', accessTokens[0], downloadBody, true), 409, 'CASE_REVISION_MISMATCH')) fail(stage);
    await journal({ stage, state: 'confirmed', caseRevision: 3, answerRevision: 2 });
    result = { status: 'passed', caseId: config.caseId, retainedCase: true, caseRevision: 3, answerRevision: 2,
      artifactId: artifact.artifactId, sha256: artifact.sha256, byteLength: artifact.byteLength, pageCount: artifact.pageCount,
      matchNeedsConfirmation: true, pinnedFormContext: true, checklistVerified: true, incompleteDraft: true, notSubmitted: true, policyCurrentnessUnknown: true,
      protectedFieldsUnresolved: true, ownerPdfVerified: true, crossOwnerDenied: true, changedAnswersInvalidateExport: true };
  } catch { failed = stage; }
  finally {
    cleanupFailed = unknownSignIn; stage = 'sign_out';
    for (const access of new Set(accessTokens)) {
      try { if ((await provider('logout?scope=local', {}, access)).status !== 204) cleanupFailed = true; }
      catch { cleanupFailed = true; }
    }
  }
  if (failed || cleanupFailed || result === null) {
    const failureStage = failed ?? 'sign_out';
    try { await journal({ stage: failureStage, state: 'failed', cleanupFailed, mutationUncertain }); }
    catch {   }
    throw new HostedDraftVerificationError(failureStage, cleanupFailed, mutationUncertain);
  }
  try { await journal({ stage: 'complete', state: 'confirmed', caseRevision: 3, answerRevision: 2, artifactId: result.artifactId }); }
  catch { throw new HostedDraftVerificationError('complete'); }
  return Object.freeze({ ...result, localSignOuts: 2 });
}
