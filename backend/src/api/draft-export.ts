import { intakeDefinition, parseSavedProgramIntake, type ProgramIntakeAppendix } from '../programs/intake.ts';
import type { ProgramIntakeRepository } from './program-intake.ts';
import { emptyAnnotations, parseAnnotations, annotationsBound, annotationHash, type AnnotationRecord, type AnnotationRepository } from '../assessment/annotations.ts';
import { createHash, randomUUID } from 'node:crypto';
import { matchPrograms } from '../matcher.ts';
import { instantMicros } from '../packets.ts';
import { defineVerifiedFormTemplate, type VerifiedFormTemplate } from '../forms/field-mapping.ts';
import { createFormAnswerContext, formAnswersAreCurrent, parseSavedFormAnswers, validateAnswersForTemplate } from '../forms/form-answers.ts';
import { MAX_TEMPLATE_BYTES, verifyTemplateBytes } from '../forms/template-artifact.ts';
import { planPacketWithForm } from '../forms/prepare-form-packet.ts';
import { renderDraftExport, DraftExportRenderError } from '../exports/render-draft-export.ts';
import { REVIEWED_TEXT_RENDERING_VERSION } from '../pdf/reviewed-text-font.ts';
import type { ExportArtifactMetadata } from '../exports/types.ts';
import { EXPORT_LIFETIME_MS, MAX_EXPORT_BYTES, parseStoredExportArtifactMetadata as parseExportArtifactMetadata } from '../exports/validation.ts';
import type { EvidenceRepository, EvidenceRepositoryFailure, ExportReviewSnapshot } from '../evidence/repository.ts';
import type { EvidenceAsset, EvidenceCatalog, EvidenceSelection } from '../evidence/types.ts';
import { exportEvidenceFitsBudget } from '../evidence/export-budget.ts';
import { canonicalJson, evidenceIdentifier as id, evidenceRevision as revision, parseEvidenceAssetAsync, parseEvidenceAssetsAsync,
  parseEvidenceDescriptor, parseEvidenceSelections, formAnswersFingerprint } from '../evidence/validation.ts';
import type { Match, ProgramDefinition } from '../types.ts';
import type { AuthenticatedUser } from './match-case.ts';

export interface DraftExportDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: EvidenceRepository & Partial<AnnotationRepository & ProgramIntakeRepository>;
  loadRegistry(): Promise<ProgramDefinition[]>;
  loadFormTemplate(programId: string): Promise<{ template: VerifiedFormTemplate; bytes: Uint8Array } | null>;
  now(): Date;
  allowDemoPrograms?: boolean;
  newArtifactId?(): string;
}

export type ExportRoute = 'list-evidence' | 'download-evidence' | 'create-draft-export' | 'download-draft-export';
export interface DraftExportResult {
  status: number;
  body: EvidenceCatalog | ExportArtifactMetadata | Uint8Array | { schemaVersion: '1'; error: { code: string; message: string } };
  headers: Record<string, string>;
}
const errors = {
  ANNOTATIONS_REQUIRE_V2: [409, 'Use the reviewed annotation-aware export workflow.'],
  INTAKE_REQUIRES_V2: [409, 'Use the current draft workflow to include saved program answers.'],
  ANNOTATION_CONFLICT: [409, 'Annotations changed. Reload and review them.'],
  ANNOTATION_REVIEW_REQUIRED: [422, 'Review the image and its annotations for the current case.'],
  UNAUTHENTICATED: [401, 'Sign in to access private evidence and drafts.'],
  INVALID_REQUEST: [400, 'Provide a valid evidence or draft export request.'],
  CASE_NOT_FOUND: [404, 'The requested case is unavailable.'],
  ARTIFACT_NOT_FOUND: [404, 'The requested private file is unavailable.'],
  PROGRAM_NOT_FOUND: [404, 'The selected program is unavailable.'],
  CASE_REVISION_MISMATCH: [409, 'The case changed. Reload it before continuing.'],
  EVIDENCE_CONFLICT: [409, 'The evidence changed or is not confirmed. Review the current evidence before exporting.'],
  FORM_NOT_AVAILABLE: [409, 'A reviewed form is unavailable for this program.'],
  FORM_CONTEXT_MISMATCH: [409, 'The form changed. Reload and review the current form.'],
  FORM_ANSWER_REVISION_MISMATCH: [409, 'The saved form answers changed. Reload them before exporting.'],
  FORM_ANSWERS_STALE: [409, 'Review and save the form answers for the current case and form.'],
  EXPORT_GENERATION_CONFLICT: [409, 'This export request is no longer current. Review the latest inputs and use a new generation key.'],
  EXPORT_EXPIRED: [410, 'This private draft expired. Review the latest inputs and generate a new draft.'],
  EXPORT_REVIEW_REQUIRED: [422, 'Review the form text, measurements, and images before exporting. Select fewer or smaller images if the evidence is too large.'],
  EXPORT_BUSY: [429, 'Another draft is being prepared. Try again shortly.'],
  STORAGE_LIMIT_REACHED: [507, 'Private storage has reached its limit. Contact the app operator before retrying.'],
  SERVICE_UNAVAILABLE: [503, 'Private draft preparation is temporarily unavailable. Try again later.'],
  INTERNAL_ERROR: [500, 'The private draft request could not be completed.'],
} as const;
type ErrorCode = keyof typeof errors;
class RequestFailure extends Error {
  readonly code: ErrorCode;
  constructor(code: ErrorCode) { super(code); this.code = code; }
}
function fail(code: ErrorCode): never { throw new RequestFailure(code); }
const activeRenders = new WeakSet<DraftExportDependencies>();
const hash = (value: unknown): string => createHash('sha256').update(canonicalJson(value)).digest('hex');
const bytesHash = (value: Uint8Array): string => createHash('sha256').update(value).digest('hex');

interface BaseRequest { schemaVersion: '1'; caseId: string; expectedCaseRevision: number }
interface CreateRequest extends BaseRequest {
  programId: string; expectedFormContextId: string; expectedAnswerRevision: number;
  expectedEvidenceCatalogRevision: number; generationKey: string; selectedEvidence: EvidenceSelection[];
  annotationRevisions?: number[];
}
type Request = BaseRequest & Partial<CreateRequest> & {
  expectedCatalogRevision?: number; evidenceId?: string; expectedEvidenceRevision?: number; artifactId?: string;
};

function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function parseRequest(value: unknown, route: ExportRoute, version: 1|2=1): Request {
  let annotationRevisions:number[]|undefined;
  if(version===2){
    if(!object(value)||value.schemaVersion!=='2')fail('INVALID_REQUEST');
    if(route==='create-draft-export'){
      if(!Array.isArray(value.selectedEvidence)||value.selectedEvidence.length>6)fail('INVALID_REQUEST');
      annotationRevisions=value.selectedEvidence.map(item=>{
        if(!object(item)||Object.keys(item).length!==4||!revision(item.expectedAnnotationRevision,true))fail('INVALID_REQUEST');
        return item.expectedAnnotationRevision as number;
      });
      value={...value,schemaVersion:'1',selectedEvidence:value.selectedEvidence.map(item=>{const {expectedAnnotationRevision,...v}=item;return v;})};
    }else value={...value,schemaVersion:'1'};
  }
  const extras = route === 'list-evidence' ? [] : route === 'download-evidence'
    ? ['expectedCatalogRevision', 'evidenceId', 'expectedEvidenceRevision'] : route === 'download-draft-export'
      ? ['artifactId'] : ['programId', 'expectedFormContextId', 'expectedAnswerRevision', 'expectedEvidenceCatalogRevision', 'generationKey', 'selectedEvidence'];
  const keys = ['schemaVersion', 'caseId', 'expectedCaseRevision', ...extras];
  if (!object(value) || Object.keys(value).length !== keys.length || !keys.every(key => Object.hasOwn(value, key))
    || value.schemaVersion !== '1' || !id(value.caseId) || !revision(value.expectedCaseRevision)) fail('INVALID_REQUEST');
  if (route === 'download-evidence' && (!revision(value.expectedCatalogRevision, true) || !id(value.evidenceId) || !revision(value.expectedEvidenceRevision))) fail('INVALID_REQUEST');
  if (route === 'download-draft-export' && !id(value.artifactId)) fail('INVALID_REQUEST');
  if (route === 'create-draft-export') {
    if (!id(value.programId) || typeof value.expectedFormContextId !== 'string' || !/^[a-f0-9]{64}$/.test(value.expectedFormContextId)
      || !revision(value.expectedAnswerRevision, true) || !revision(value.expectedEvidenceCatalogRevision, true)
      || typeof value.generationKey !== 'string' || !/^[A-Za-z0-9_-]{8,128}$/.test(value.generationKey)) fail('INVALID_REQUEST');
    try { parseEvidenceSelections(value.selectedEvidence); } catch { fail('INVALID_REQUEST'); }
  }
  return {...structuredClone(value),...(annotationRevisions?{annotationRevisions}:{})} as unknown as Request;
}
function clock(deps: DraftExportDependencies): string {
  const date = deps.now();
  if (!(date instanceof Date) || !Number.isFinite(date.getTime())) throw new Error('Invalid clock.');
  const value = date.toISOString(); instantMicros(value); return value;
}
async function storage<T>(operation: () => Promise<T>): Promise<T> {
  try { return await operation(); } catch { return fail('SERVICE_UNAVAILABLE'); }
}
function repositoryFailure(result: EvidenceRepositoryFailure, artifact = false): never {
  const codes = { not_found: artifact ? 'ARTIFACT_NOT_FOUND' : 'CASE_NOT_FOUND', conflict: 'CASE_REVISION_MISMATCH',
    evidence_conflict: 'EVIDENCE_CONFLICT', answers_conflict: 'FORM_ANSWER_REVISION_MISMATCH',
    generation_conflict: 'EXPORT_GENERATION_CONFLICT', expired: 'EXPORT_EXPIRED', quota_exceeded: 'STORAGE_LIMIT_REACHED',
    selection_too_large: 'EXPORT_REVIEW_REQUIRED' } as const;
  return fail(codes[result.status] ?? 'INTERNAL_ERROR');
}
function json(body: EvidenceCatalog | ExportArtifactMetadata): DraftExportResult {
  return { status: 200, body, headers: { 'Cache-Control': 'no-store' } };
}
function binary(bytes: Uint8Array, mediaType: 'image/png' | 'application/pdf', sha256: string): DraftExportResult {
  return { status: 200, body: bytes, headers: { 'Cache-Control': 'no-store', 'Content-Type': mediaType,
    'X-Content-Type-Options': 'nosniff', 'Content-Length': String(bytes.length), 'X-Content-SHA256': sha256,
    'Content-Disposition': mediaType === 'image/png' ? 'inline; filename="evidence.png"' : 'attachment; filename="safe-at-home-draft.pdf"' } };
}

interface Context {
  source: ExportReviewSnapshot; assets: EvidenceAsset[]; template: VerifiedFormTemplate; templateBytes: Uint8Array;
  intake?: ProgramIntakeAppendix; program: ProgramDefinition; match: Match; annotations:AnnotationRecord[]; annotationVersion:boolean; fingerprint: string; evaluatedAt: string; formContextId: string;
}

async function loadContext(userId: string, request: CreateRequest, deps: DraftExportDependencies, images = true): Promise<Context> {
  const input = { userId, caseId: request.caseId, revision: request.expectedCaseRevision,
    expectedCatalogRevision: request.expectedEvidenceCatalogRevision,
    programId: request.programId, selections: structuredClone(request.selectedEvidence) };
  let source: ExportReviewSnapshot;
  let assets: EvidenceAsset[] = [];
  if (images) {
    const loaded = await storage(() => deps.cases.loadExportSnapshotForUser(input));
    if (loaded.status !== 'found') return repositoryFailure(loaded);
    if (!Array.isArray(loaded.snapshot.assets) || loaded.snapshot.assets.length !== request.selectedEvidence.length) fail('INTERNAL_ERROR');
    const evidence = loaded.snapshot.assets.map(asset => {
      const descriptor = parseEvidenceDescriptor(asset.descriptor);
      if (!(asset.bytes instanceof Uint8Array) || asset.bytes.byteLength !== descriptor.byteLength) fail('INTERNAL_ERROR');
      return descriptor;
    });
    if (!exportEvidenceFitsBudget(evidence)) fail('EXPORT_REVIEW_REQUIRED');
    const { assets: supplied, ...review } = loaded.snapshot;
    source = structuredClone({ ...review, evidence });
    assets = await parseEvidenceAssetsAsync(supplied);
    source.evidence = assets.map(asset => asset.descriptor);
  } else {
    const loaded = await storage(() => deps.cases.loadExportReviewForUser(input));
    if (loaded.status !== 'found') return repositoryFailure(loaded);
    source = structuredClone(loaded.snapshot);
    if (!Array.isArray(source.evidence) || source.evidence.length !== request.selectedEvidence.length) fail('INTERNAL_ERROR');
    source.evidence = source.evidence.map(parseEvidenceDescriptor);
    if (!exportEvidenceFitsBudget(source.evidence)) fail('EXPORT_REVIEW_REQUIRED');
  }
  const annotations:AnnotationRecord[]=[];
  for(const [index,d] of source.evidence.entries()) {
    let annotation=emptyAnnotations(d);
    if(deps.cases.readAnnotationsForUser){
      const result=await storage(()=>deps.cases.readAnnotationsForUser!(userId,{schemaVersion:'2',caseId:request.caseId,
        expectedCaseRevision:request.expectedCaseRevision,expectedCatalogRevision:request.expectedEvidenceCatalogRevision,evidenceId:d.evidenceId,expectedEvidenceRevision:d.evidenceRevision}));
      if(result.status!=='found')fail('ANNOTATION_CONFLICT');annotation=parseAnnotations(result.state.annotation);
      if(!annotationsBound(annotation,d))fail('ANNOTATION_CONFLICT');
    }else if(request.annotationRevisions)fail('SERVICE_UNAVAILABLE');
    if(request.annotationRevisions){
      if(annotation.annotationRevision!==request.annotationRevisions[index])fail('ANNOTATION_CONFLICT');
      if(annotation.marks.length&&(annotation.reviewState!=='reviewed'||annotation.reviewedCaseRevision!==request.expectedCaseRevision||annotation.reviewedBy!==userId))fail('ANNOTATION_REVIEW_REQUIRED');
    }else if(annotation.marks.length)fail('ANNOTATIONS_REQUIRE_V2');
    annotations.push(annotation);
  }
  const { snapshot } = source;
  const validatedAt = clock(deps);
  matchPrograms(snapshot, [], { evaluatedAt: validatedAt, evaluationDate: validatedAt.slice(0, 10) });
  if (snapshot.caseId !== request.caseId || snapshot.revision !== request.expectedCaseRevision
    || source.catalogRevision !== request.expectedEvidenceCatalogRevision || source.caseFingerprint !== hash(snapshot)) fail('INTERNAL_ERROR');
  source.evidence.forEach((d, index) => {
    const selected = request.selectedEvidence[index];
    const finding = snapshot.findings.find(finding => finding.id === d.findingId);
    if (d.caseId !== snapshot.caseId || d.evidenceId !== selected.evidenceId || d.evidenceRevision !== selected.expectedEvidenceRevision
      || !finding || finding.reviewState !== 'confirmed' || !finding.evidenceIds.includes(d.evidenceId)
      || instantMicros(d.preparedAt) > instantMicros(validatedAt)) fail('INTERNAL_ERROR');
  });
  const registry = structuredClone(await storage(() => deps.loadRegistry()));
  matchPrograms(snapshot, registry, { evaluatedAt: validatedAt, evaluationDate: validatedAt.slice(0, 10) });
  const program = registry.find(program => program.programId === request.programId);
  if (!program) return fail('PROGRAM_NOT_FOUND');
  if (program.isDemo && deps.allowDemoPrograms !== true) fail('INTERNAL_ERROR');
  const form = await storage(() => deps.loadFormTemplate(request.programId));
  if (form === null) return fail('FORM_NOT_AVAILABLE');
  if (!(form.bytes instanceof Uint8Array) || form.bytes.length < 8 || form.bytes.length > MAX_TEMPLATE_BYTES) fail('INTERNAL_ERROR');
  const detachedForm = structuredClone(form), template = defineVerifiedFormTemplate(detachedForm.template);
  if (template.programId !== program.programId || template.reviewedOn > validatedAt.slice(0, 10)) fail('INTERNAL_ERROR');
  verifyTemplateBytes(detachedForm.bytes, template.templateSha256);
  const formContext = createFormAnswerContext(template);
  if (request.expectedFormContextId !== formContext.formContextId) fail('FORM_CONTEXT_MISMATCH');
  if (source.answers !== null) {
    source.answers = parseSavedFormAnswers(source.answers);
    if (source.answers.updatedBy !== userId || source.answers.answers.some(answer => answer.reviewedBy !== null && answer.reviewedBy !== userId)
      || source.answers.caseId !== snapshot.caseId || source.answers.programId !== program.programId
      || instantMicros(source.answers.updatedAt) > instantMicros(validatedAt)) fail('INTERNAL_ERROR');
    if (!formAnswersAreCurrent(source.answers, snapshot, formContext)) fail('FORM_ANSWERS_STALE');
    validateAnswersForTemplate(source.answers.answers, template);
  }
  if (source.answersFingerprint !== formAnswersFingerprint(source.answers)) fail('INTERNAL_ERROR');
  if ((source.answers?.answerRevision ?? 0) !== request.expectedAnswerRevision) fail('FORM_ANSWER_REVISION_MISMATCH');
  let intake: ProgramIntakeAppendix | undefined;
  const definition = intakeDefinition(program.programId);
  if (definition !== null) {
    if (deps.cases.readProgramIntakeIfCurrent) {
      const loaded = await storage(() => deps.cases.readProgramIntakeIfCurrent!({ userId, caseId: snapshot.caseId,
        revision: snapshot.revision, programId: program.programId }));
      if (loaded.status !== 'found') fail(loaded.status === 'not_found' ? 'CASE_NOT_FOUND' : 'CASE_REVISION_MISMATCH');
      const saved = loaded.saved === null ? null : parseSavedProgramIntake(loaded.saved);
      if (saved && (saved.caseId !== snapshot.caseId || saved.caseRevision > snapshot.revision ||
        saved.programId !== program.programId || saved.updatedBy !== userId || instantMicros(saved.updatedAt) > instantMicros(validatedAt))) fail('INTERNAL_ERROR');
      if (!request.annotationRevisions && saved !== null) fail('INTAKE_REQUIRES_V2');
      if (request.annotationRevisions) intake = { definition, saved };
    } else if (request.annotationRevisions) fail('SERVICE_UNAVAILABLE');
  }
  const evaluatedAt = clock(deps);
  if (instantMicros(evaluatedAt) < instantMicros(validatedAt)) fail('INTERNAL_ERROR');
  const match = matchPrograms(snapshot, [program], { evaluatedAt, evaluationDate: evaluatedAt.slice(0, 10) }).matches[0];
  const fingerprint = hash({ renderingVersion: request.annotationRevisions?'draft-export-annotations-v2':'draft-export-v1', textRenderingVersion: REVIEWED_TEXT_RENDERING_VERSION, ...(request.annotationRevisions?{annotations, intake:intake??null, intakeRenderingVersion:'reported-intake-v1'}:{}), snapshot, program, match, template,
    formAnswers: source.answers, catalogRevision: source.catalogRevision,
    evidence: source.evidence, evaluationDate: evaluatedAt.slice(0, 10) });
  return { source, assets, intake, annotations, annotationVersion:request.annotationRevisions!==undefined, template, templateBytes: detachedForm.bytes, program, match, fingerprint, evaluatedAt, formContextId: formContext.formContextId };
}

function metadata(context: Context, userId: string, artifactId: string, generatedAt: string,
  file: { byteLength: number; sha256: string; pageCount: number }): ExportArtifactMetadata {
  const { source, template, match } = context;
  const packet = planPacketWithForm(source.snapshot, match, { packetId: artifactId, generatedAt },
    { template, templateSha256: template.templateSha256 }, source.answers);
  if (packet.recheckAfter !== null && instantMicros(packet.recheckAfter) <= instantMicros(generatedAt)) fail('EXPORT_EXPIRED');
  let deadline = new Date(Date.parse(generatedAt) + EXPORT_LIFETIME_MS).toISOString();
  if (packet.recheckAfter !== null && instantMicros(packet.recheckAfter) < instantMicros(deadline)) deadline = packet.recheckAfter;
  return parseExportArtifactMetadata({ schemaVersion: context.annotationVersion?'2':'1', artifactId, caseId: source.snapshot.caseId,
    caseRevision: source.snapshot.revision, programId: match.programId, ruleVersion: match.ruleVersion,
    formVersion: template.formVersion, mappingVersion: template.mappingVersion, formContextId: context.formContextId,
    answerRevision: source.answers?.answerRevision ?? 0, evidenceCatalogRevision: source.catalogRevision,
    exportContextId: context.fingerprint, generatedAt, expiresAt: deadline, recheckAfter: packet.recheckAfter,
    status: 'draft', isDemo: match.isDemo, mediaType: 'application/pdf', byteLength: file.byteLength,
    sha256: file.sha256, pageCount: file.pageCount, renderingVersion: context.annotationVersion?'draft-export-annotations-v2':'draft-export-v1',
    selectedEvidence: source.evidence.map((d,index) => ({ evidenceId: d.evidenceId, evidenceRevision: d.evidenceRevision,
      findingId: d.findingId, sha256: d.sha256, reviewedAt: generatedAt, reviewedBy: userId, ...(context.annotationVersion?{annotationRevision:context.annotations[index].annotationRevision,annotationSha256:annotationHash(context.annotations[index])}:{}) })),
    missingItems: packet.missingItems.map(item => item.id === 'form-rendering'
      ? { ...item, description: 'Inspect every populated field and evidence page in this incomplete draft. Complete all outstanding reviews before any submission.' } : item),
    warnings: ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', ...(!context.program.rulesVerified || match.availability === 'unverified'
      || packet.recheckAfter === null ? ['POLICY_CURRENTNESS_UNKNOWN'] : [])] });
}

async function createExport(userId: string, request: CreateRequest, deps: DraftExportDependencies): Promise<DraftExportResult> {
  if (activeRenders.has(deps)) fail('EXPORT_BUSY');
  activeRenders.add(deps);
  try {
    const context = await loadContext(userId, request, deps), { source, template } = context;
    const generatedAt = context.evaluatedAt;
    if (context.match.recheckAfter !== null && instantMicros(context.match.recheckAfter) <= instantMicros(generatedAt)) fail('EXPORT_EXPIRED');
    const rendering = renderDraftExport(source.snapshot, template, context.templateBytes,
      { programId: request.programId, templateSha256: template.templateSha256, plannedAt: generatedAt }, source.answers, context.assets, context.annotationVersion?context.annotations:undefined, context.intake);
    context.assets = [];
    const rendered = await rendering;
    const current = await loadContext(userId, request, deps, false);
    if (current.fingerprint !== context.fingerprint) fail('EXPORT_GENERATION_CONFLICT');
    const artifactId = deps.newArtifactId?.() ?? `export-${randomUUID()}`;
    const expected = metadata(context, userId, artifactId, generatedAt, rendered);
    const checkedAt = clock(deps);
    if (instantMicros(checkedAt) < instantMicros(generatedAt)) fail('INTERNAL_ERROR');
    if (instantMicros(checkedAt) >= instantMicros(expected.expiresAt)) fail('EXPORT_EXPIRED');
    const saved = await storage(() => deps.cases.publishExportIfCurrent({ userId, caseId: request.caseId,
      revision: request.expectedCaseRevision, expectedCatalogRevision: request.expectedEvidenceCatalogRevision,
      programId: request.programId, expectedCaseFingerprint: source.caseFingerprint,
      expectedAnswersFingerprint: source.answersFingerprint, selections: structuredClone(request.selectedEvidence),
      contextFingerprint: context.fingerprint, generationKey: request.generationKey,
      artifact: { metadata: structuredClone(expected), bytes: rendered.bytes }, checkedAt }));
    if (!('artifact' in saved)) return repositoryFailure(saved);
    const result = parseExportArtifactMetadata(saved.artifact);
    const reconstructed = metadata(context, userId, result.artifactId, result.generatedAt,
      { sha256: result.sha256, byteLength: result.byteLength, pageCount: rendered.pageCount });
    if (canonicalJson(result) !== canonicalJson(reconstructed)) fail('INTERNAL_ERROR');
    if (saved.status === 'saved' && canonicalJson(result) !== canonicalJson(expected)) fail('INTERNAL_ERROR');
    await reviewCurrentArtifact(userId, result, context.fingerprint, deps);
    return json(result);
  } finally { activeRenders.delete(deps); }
}

async function reviewCurrentArtifact(userId: string, expected: ExportArtifactMetadata,
  contextFingerprint: string, deps: DraftExportDependencies): Promise<void> {
  const loaded = await storage(() => deps.cases.reviewExportForUserIfCurrent({ userId, caseId: expected.caseId,
    artifactId: expected.artifactId, contextFingerprint, checkedAt: clock(deps) }));
  if (loaded.status !== 'found') return repositoryFailure(loaded, true);
  const metadata = parseExportArtifactMetadata(loaded.artifact);
  if (canonicalJson(metadata) !== canonicalJson(expected)) fail('INTERNAL_ERROR');
  returnedArtifactIsFresh(metadata, deps);
}

function returnedArtifactIsFresh(metadata: ExportArtifactMetadata, deps: DraftExportDependencies): void {
  const returnedAt = instantMicros(clock(deps));
  if (returnedAt < instantMicros(metadata.generatedAt)) fail('INTERNAL_ERROR');
  if (returnedAt >= instantMicros(metadata.expiresAt)) fail('EXPORT_EXPIRED');
}

async function currentArtifact(userId: string, expected: ExportArtifactMetadata, contextFingerprint: string, deps: DraftExportDependencies) {
  const loaded = await storage(() => deps.cases.readExportForUserIfCurrent({ userId, caseId: expected.caseId,
    artifactId: expected.artifactId, contextFingerprint, checkedAt: clock(deps) }));
  if (loaded.status !== 'found') return repositoryFailure(loaded, true);
  if (!(loaded.artifact.bytes instanceof Uint8Array) || loaded.artifact.bytes.length > MAX_EXPORT_BYTES) fail('INTERNAL_ERROR');
  const metadata = parseExportArtifactMetadata(loaded.artifact.metadata), bytes = Uint8Array.from(loaded.artifact.bytes);
  if (canonicalJson(metadata) !== canonicalJson(expected) || !(bytes instanceof Uint8Array)
    || bytes.length !== metadata.byteLength || bytesHash(bytes) !== metadata.sha256
    || Buffer.from(bytes.subarray(0, 5)).toString('ascii') !== '%PDF-') fail('INTERNAL_ERROR');
  returnedArtifactIsFresh(metadata, deps);
  return { metadata, bytes };
}

async function processRequest(input: { body: unknown; bearerToken: string | null }, deps: DraftExportDependencies, route: ExportRoute, version:1|2=1): Promise<DraftExportResult> {
  const body = structuredClone(input.body), token = input.bearerToken;
  if (typeof token !== 'string' || token.length < 1 || token.length > 4096 || /\s/.test(token)) fail('UNAUTHENTICATED');
  const user = await storage(() => deps.authenticate(token));
  if (user === null) return fail('UNAUTHENTICATED');
  if (!id(user.userId)) fail('INTERNAL_ERROR');
  const userId = user.userId, request = parseRequest(body, route,version);
  if (route === 'list-evidence') {
    const loaded = await storage(() => deps.cases.readEvidenceCatalogForUser(userId, request.caseId));
    if (loaded.status !== 'found') return repositoryFailure(loaded);
    const catalog = loaded.catalog;
    if (!object(catalog) || Object.keys(catalog).sort().join(',') !== 'caseId,caseRevision,catalogRevision,evidence,schemaVersion'
      || catalog.schemaVersion !== '1' || catalog.caseId !== request.caseId || !revision(catalog.caseRevision)
      || !revision(catalog.catalogRevision, true) || !Array.isArray(catalog.evidence) || catalog.evidence.length > 64) fail('INTERNAL_ERROR');
    if (catalog.caseRevision !== request.expectedCaseRevision) fail('CASE_REVISION_MISMATCH');
    const evidence = catalog.evidence.map(parseEvidenceDescriptor);
    if (new Set(evidence.map(item => item.evidenceId)).size !== evidence.length || evidence.some(item => item.caseId !== request.caseId)) fail('INTERNAL_ERROR');
    return json({ ...catalog, evidence });
  }
  if (route === 'download-evidence') {
    const loaded = await storage(() => deps.cases.readEvidenceForUser({ userId, caseId: request.caseId,
      revision: request.expectedCaseRevision, expectedCatalogRevision: request.expectedCatalogRevision!,
      evidenceId: request.evidenceId!, expectedEvidenceRevision: request.expectedEvidenceRevision! }));
    if (loaded.status !== 'found') return repositoryFailure(loaded, true);
    const asset = await parseEvidenceAssetAsync(loaded.asset), d = asset.descriptor;
    if (d.caseId !== request.caseId || d.evidenceId !== request.evidenceId || d.evidenceRevision !== request.expectedEvidenceRevision) fail('INTERNAL_ERROR');
    return binary(asset.bytes, 'image/png', d.sha256);
  }
  if (route === 'create-draft-export') return createExport(userId, request as CreateRequest, deps);
  const loaded = await storage(() => deps.cases.readExportForUser({ userId, caseId: request.caseId, artifactId: request.artifactId! }));
  if (loaded.status !== 'found') return repositoryFailure(loaded, true);
  const expected = parseExportArtifactMetadata(loaded.artifact);
  if(expected.schemaVersion!==String(version))fail('ANNOTATIONS_REQUIRE_V2');
  if (expected.caseId !== request.caseId || expected.artifactId !== request.artifactId) fail('INTERNAL_ERROR');
  if (expected.caseRevision !== request.expectedCaseRevision) fail('CASE_REVISION_MISMATCH');
  if (instantMicros(clock(deps)) >= instantMicros(expected.expiresAt)) fail('EXPORT_EXPIRED');
  const context = await loadContext(userId, { schemaVersion: '1', caseId: request.caseId, expectedCaseRevision: request.expectedCaseRevision,
    programId: expected.programId, expectedFormContextId: expected.formContextId, expectedAnswerRevision: expected.answerRevision,
    expectedEvidenceCatalogRevision: expected.evidenceCatalogRevision, generationKey: 'download-context',
    ...(version===2?{annotationRevisions:expected.selectedEvidence.map(item=>item.annotationRevision!)}:{}),
    selectedEvidence: expected.selectedEvidence.map(item => ({ evidenceId: item.evidenceId, expectedEvidenceRevision: item.evidenceRevision, reviewedForExport: true })) }, deps, false);
  if (context.fingerprint !== expected.exportContextId) fail('EXPORT_GENERATION_CONFLICT');
  if (canonicalJson(metadata(context, userId, expected.artifactId, expected.generatedAt,
    { byteLength: expected.byteLength, sha256: expected.sha256, pageCount: expected.pageCount })) !== canonicalJson(expected)) fail('INTERNAL_ERROR');
  const artifact = await currentArtifact(userId, expected, context.fingerprint, deps);
  return binary(artifact.bytes, 'application/pdf', artifact.metadata.sha256);
}

export async function handleDraftExport(input: { body: unknown; bearerToken: string | null }, deps: DraftExportDependencies, route: ExportRoute, version:1|2=1): Promise<DraftExportResult> {
  try { return await processRequest(input, deps, route,version); }
  catch (error) {
    const code = error instanceof RequestFailure ? error.code : error instanceof DraftExportRenderError ? 'EXPORT_REVIEW_REQUIRED' : 'INTERNAL_ERROR';
    const [status, message] = errors[code];
    return { status, body: { schemaVersion: '1', error: { code, message } },
      headers: { 'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}) } };
  }
}
