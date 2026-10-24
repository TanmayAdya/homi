import { createHash, randomUUID } from 'node:crypto';
import { matchPrograms } from '../matcher.ts';
import { instantMicros, isPacketCurrent, PACKET_PLANNER_VERSION } from '../packets.ts';
import { defineVerifiedFormTemplate, type VerifiedFormTemplate } from '../forms/field-mapping.ts';
import { planPacketWithForm, type VerifiedTemplateArtifact } from '../forms/prepare-form-packet.ts';
import { MAX_TEMPLATE_BYTES, verifyTemplateBytes } from '../forms/template-artifact.ts';
import { createFormAnswerContext, formAnswersAreCurrent, parseSavedFormAnswers, type SavedFormAnswerSet } from '../forms/form-answers.ts';
import type { CaseSnapshot, DraftPacket, ProgramDefinition } from '../types.ts';
import type { ApiErrorCode, AuthenticatedUser } from './match-case.ts';

export interface PreparePacketRequest {
  schemaVersion: '1';
  caseId: string;
  expectedCaseRevision: number;
  programId: string;
  generationKey: string;
}

export interface CreatePacketInput {
  userId: string;
  caseId: string;
  revision: number;
  generationKey: string;
  contextFingerprint: string;
  packet: DraftPacket;
  checkedAt: string;
}

export type CreatePacketResult =
  | { status: 'saved' | 'reused'; packet: DraftPacket }
  | { status: 'not_found' | 'conflict' | 'generation_conflict' | 'quota_exceeded' };

export interface PacketCaseRepository {
  loadForUser(userId: string, caseId: string): Promise<CaseSnapshot | null>;
  loadFormAnswersForUser?(userId: string, caseId: string, programId: string): Promise<SavedFormAnswerSet | null>;
  createPacketIfCurrent(input: CreatePacketInput): Promise<CreatePacketResult>;
}

export interface PreparePacketDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: PacketCaseRepository;
  loadRegistry(): Promise<ProgramDefinition[]>;
  loadFormTemplate?(programId: string): Promise<{ template: VerifiedFormTemplate; bytes: Uint8Array } | null>;
  now(): Date;
  allowDemoPrograms?: boolean;
  newPacketId?(): string;
}

export type PacketErrorCode = ApiErrorCode | 'PROGRAM_NOT_FOUND' | 'PACKET_GENERATION_CONFLICT' | 'FORM_ANSWERS_STALE' | 'STORAGE_LIMIT_REACHED';
export interface PreparePacketResult {
  status: number;
  body: DraftPacket | { schemaVersion: '1'; error: { code: PacketErrorCode; message: string } };
  headers?: Record<string, string>;
}

const errors: Record<PacketErrorCode, { status: number; message: string }> = {
  UNAUTHENTICATED: { status: 401, message: 'Sign in to prepare a draft packet.' },
  INVALID_REQUEST: { status: 400, message: 'Provide a v1 case, expected revision, program, and generation key.' },
  CASE_NOT_FOUND: { status: 404, message: 'The requested case is unavailable.' },
  PROGRAM_NOT_FOUND: { status: 404, message: 'The selected program is unavailable.' },
  CASE_REVISION_MISMATCH: { status: 409, message: 'The case changed. Reload it before preparing a draft.' },
  PACKET_GENERATION_CONFLICT: { status: 409, message: 'This draft request is no longer current. Review the latest case and program, then use a new generation key.' },
  FORM_ANSWERS_STALE: { status: 409, message: 'Review and save the form answers for the current case and form before preparing a draft.' },
  STORAGE_LIMIT_REACHED: { status: 507, message: 'This case has reached its draft storage limit. Contact the project operator for help.' },
  SERVICE_UNAVAILABLE: { status: 503, message: 'Draft preparation is temporarily unavailable. Try again later.' },
  INTERNAL_ERROR: { status: 500, message: 'The draft packet could not be prepared.' },
};

function failure(code: PacketErrorCode): PreparePacketResult {
  return { status: errors[code].status, body: { schemaVersion: '1', error: { code, message: errors[code].message } },
    headers: { 'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}) } };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function validId(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0 && [...value].length <= 200
    && !/[\uD800-\uDFFF]/u.test(value);
}

function validRequest(value: unknown): value is PreparePacketRequest {
  if (!isRecord(value)) return false;
  const keys = ['schemaVersion', 'caseId', 'expectedCaseRevision', 'programId', 'generationKey'];
  return Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key))
    && value.schemaVersion === '1' && validId(value.caseId) && validId(value.programId)
    && Number.isSafeInteger(value.expectedCaseRevision) && Number(value.expectedCaseRevision) >= 1
    && typeof value.generationKey === 'string' && value.generationKey.length >= 8 && value.generationKey.length <= 128
    && !/[^A-Za-z0-9_-]/.test(value.generationKey);
}

function clock(deps: PreparePacketDependencies): string {
  const now = deps.now();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new Error('Invalid server clock.');
  const result = now.toISOString();
  instantMicros(result);
  return result;
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (isRecord(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

async function processPreparePacket(
  input: { body: unknown; bearerToken: string | null }, deps: PreparePacketDependencies,
): Promise<PreparePacketResult> {
  const token = input.bearerToken;
  if (typeof token !== 'string' || token.length === 0 || /\s/.test(token)) return failure('UNAUTHENTICATED');
  let user: AuthenticatedUser | null;
  try { user = await deps.authenticate(token); } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (user === null) return failure('UNAUTHENTICATED');
  if (!isRecord(user) || typeof user.userId !== 'string' || !user.userId.trim()) return failure('INTERNAL_ERROR');
  const userId = user.userId;
  if (!validRequest(input.body)) return failure('INVALID_REQUEST');
  const request = structuredClone(input.body);
  let loaded: CaseSnapshot | null;
  try { loaded = await deps.cases.loadForUser(userId, request.caseId); } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (loaded === null) return failure('CASE_NOT_FOUND');
  const snapshot = structuredClone(loaded);
  const validatedAt = clock(deps);
  matchPrograms(snapshot, [], { evaluatedAt: validatedAt, evaluationDate: validatedAt.slice(0, 10) });
  if (snapshot.caseId !== request.caseId) return failure('INTERNAL_ERROR');
  if (snapshot.revision !== request.expectedCaseRevision) return failure('CASE_REVISION_MISMATCH');

  let registry: ProgramDefinition[];
  try { registry = await deps.loadRegistry(); } catch { return failure('SERVICE_UNAVAILABLE'); }
  registry = structuredClone(registry);
  const registryCheckedAt = clock(deps);
  const selection = matchPrograms(snapshot, registry, { evaluatedAt: registryCheckedAt, evaluationDate: registryCheckedAt.slice(0, 10) });
  const selected = selection.matches.find(candidate => candidate.programId === request.programId);
  if (!selected) return failure('PROGRAM_NOT_FOUND');
  if (selected.isDemo && deps.allowDemoPrograms !== true) return failure('INTERNAL_ERROR');
  let artifact: VerifiedTemplateArtifact | null = null;
  if (deps.loadFormTemplate) {
    let loadedForm: { template: VerifiedFormTemplate; bytes: Uint8Array } | null;
    try { loadedForm = await deps.loadFormTemplate(request.programId); } catch { return failure('SERVICE_UNAVAILABLE'); }
    if (loadedForm !== null) {
      if (!(loadedForm.bytes instanceof Uint8Array) || loadedForm.bytes.byteLength < 8
        || loadedForm.bytes.byteLength > MAX_TEMPLATE_BYTES) return failure('INTERNAL_ERROR');
      const detached = structuredClone(loadedForm);
      const template = defineVerifiedFormTemplate(detached.template);
      if (template.programId !== request.programId) return failure('INTERNAL_ERROR');
      const templateSha256 = verifyTemplateBytes(detached.bytes, template.templateSha256);
      artifact = { template, templateSha256 };
    }
  }
  let formAnswers: SavedFormAnswerSet | null = null;
  if (artifact?.template.fields.some(field => field.binding.kind === 'reviewed_answer')) {
    if (!deps.cases.loadFormAnswersForUser) return failure('INTERNAL_ERROR');
    let loadedAnswers: SavedFormAnswerSet | null;
    try { loadedAnswers = await deps.cases.loadFormAnswersForUser(userId, request.caseId, request.programId); }
    catch { return failure('SERVICE_UNAVAILABLE'); }
    if (loadedAnswers !== null) {
      formAnswers = parseSavedFormAnswers(loadedAnswers);
      if (formAnswers.caseId !== request.caseId || formAnswers.programId !== request.programId
        || formAnswers.updatedBy !== userId
        || formAnswers.answers.some(answer => answer.reviewedBy !== null && answer.reviewedBy !== userId)) {
        return failure('INTERNAL_ERROR');
      }
      if (!formAnswersAreCurrent(formAnswers, snapshot, createFormAnswerContext(artifact.template))) {
        return failure('FORM_ANSWERS_STALE');
      }
    }
  }
  const generatedAt = clock(deps);
  const response = matchPrograms(snapshot, registry, { evaluatedAt: generatedAt, evaluationDate: generatedAt.slice(0, 10) });
  const match = response.matches.find(candidate => candidate.programId === request.programId);
  if (!match) return failure('PROGRAM_NOT_FOUND');
  if (match.isDemo && deps.allowDemoPrograms !== true) return failure('INTERNAL_ERROR');
  const program = registry.find(candidate => candidate.programId === request.programId)!;
  const contextFingerprint = createHash('sha256').update(canonicalJson({
    plannerVersion: PACKET_PLANNER_VERSION, snapshot, program, match, formTemplate: artifact?.template ?? null, formAnswers,
  })).digest('hex');
  const packet = planPacketWithForm(snapshot, match, { packetId: deps.newPacketId?.() ?? `packet-${randomUUID()}`, generatedAt }, artifact, formAnswers);
  const checkedAt = clock(deps);
  if (instantMicros(checkedAt) < instantMicros(generatedAt)) throw new Error('The server clock moved backwards.');
  if (packet.recheckAfter !== null && instantMicros(checkedAt) >= instantMicros(packet.recheckAfter)) {
    return failure('PACKET_GENERATION_CONFLICT');
  }
  let saved: CreatePacketResult;
  try {
    saved = await deps.cases.createPacketIfCurrent({ userId, caseId: request.caseId,
      revision: snapshot.revision, generationKey: request.generationKey, contextFingerprint, packet, checkedAt });
  } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (saved.status === 'not_found') return failure('CASE_NOT_FOUND');
  if (saved.status === 'conflict') return failure('CASE_REVISION_MISMATCH');
  if (saved.status === 'generation_conflict') return failure('PACKET_GENERATION_CONFLICT');
  if (saved.status === 'quota_exceeded') return failure('STORAGE_LIMIT_REACHED');
  if (saved.status !== 'saved' && saved.status !== 'reused') return failure('INTERNAL_ERROR');
  const result = saved.packet;
  const expected = planPacketWithForm(snapshot, match, { packetId: result.packetId, generatedAt: result.generatedAt }, artifact, formAnswers);
  if (canonicalJson(result) !== canonicalJson(expected)) return failure('INTERNAL_ERROR');
  const returnedAt = clock(deps);
  if (instantMicros(result.generatedAt) > instantMicros(returnedAt)) return failure('INTERNAL_ERROR');
  if ((saved.status === 'reused' || result.recheckAfter !== null) && !isPacketCurrent(result, returnedAt)) {
    return failure('PACKET_GENERATION_CONFLICT');
  }
  return { status: 200, body: structuredClone(result), headers: { 'Cache-Control': 'no-store' } };
}

export async function handlePreparePacket(
  input: { body: unknown; bearerToken: string | null }, deps: PreparePacketDependencies,
): Promise<PreparePacketResult> {
  try { return await processPreparePacket(input, deps); } catch { return failure('INTERNAL_ERROR'); }
}
