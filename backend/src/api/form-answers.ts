import { matchPrograms } from '../matcher.ts';
import { instantMicros } from '../packets.ts';
import { defineVerifiedFormTemplate, type VerifiedFormTemplate } from '../forms/field-mapping.ts';
import { MAX_TEMPLATE_BYTES, verifyTemplateBytes } from '../forms/template-artifact.ts';
import {
  createFormAnswerContext, createSavedFormAnswers, parseFormAnswerInputs, parseSavedFormAnswers, validateAnswersForTemplate,
  type FormAnswerContext, type FormAnswerInput, type SavedFormAnswerSet,
} from '../forms/form-answers.ts';
import type { CaseSnapshot } from '../types.ts';
import type { ApiErrorCode, AuthenticatedUser } from './match-case.ts';

export interface FormAnswerReadInput {
  userId: string;
  caseId: string;
  revision: number;
  programId: string;
}

export type FormAnswerReadResult =
  | { status: 'found'; saved: SavedFormAnswerSet | null }
  | { status: 'not_found' | 'conflict' };

export interface FormAnswerSaveInput extends FormAnswerReadInput {
  expectedAnswerRevision: number;
  answers: SavedFormAnswerSet;
}

export type FormAnswerSaveResult =
  | { status: 'saved'; saved: SavedFormAnswerSet; caseRevision: number }
  | { status: 'not_found' | 'conflict' | 'answers_conflict' };

export interface FormAnswerCaseRepository {
  loadForUser(userId: string, caseId: string): Promise<CaseSnapshot | null>;
  loadFormAnswersForUser(userId: string, caseId: string, programId: string): Promise<SavedFormAnswerSet | null>;
  readFormAnswersIfCurrent(input: FormAnswerReadInput): Promise<FormAnswerReadResult>;
  saveFormAnswersIfCurrent(input: FormAnswerSaveInput): Promise<FormAnswerSaveResult>;
}

export interface FormAnswerDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: FormAnswerCaseRepository;
  loadFormTemplate(programId: string): Promise<{ template: VerifiedFormTemplate; bytes: Uint8Array } | null>;
  now(): Date;
}

export interface ReadFormAnswersRequest {
  schemaVersion: '1';
  caseId: string;
  expectedCaseRevision: number;
  programId: string;
}

export interface SaveFormAnswersRequest extends ReadFormAnswersRequest {
  expectedFormContextId: string;
  expectedAnswerRevision: number;
  answers: FormAnswerInput[];
}

export interface FormAnswersResponse {
  schemaVersion: '1';
  caseId: string;
  caseRevision: number;
  context: FormAnswerContext;
  saved: SavedFormAnswerSet | null;
  isCurrent: boolean;
}

export type FormAnswerErrorCode = ApiErrorCode | 'FORM_NOT_AVAILABLE' | 'FORM_CONTEXT_MISMATCH' | 'FORM_ANSWERS_CONFLICT';
export interface FormAnswerResult {
  status: number;
  body: FormAnswersResponse | { schemaVersion: '1'; error: { code: FormAnswerErrorCode; message: string } };
  headers: Record<string, string>;
}

const errors: Record<FormAnswerErrorCode, { status: number; message: string }> = {
  UNAUTHENTICATED: { status: 401, message: 'Sign in to review form answers.' },
  INVALID_REQUEST: { status: 400, message: 'Provide a valid form-answer request with only supported fields.' },
  CASE_NOT_FOUND: { status: 404, message: 'The requested case is unavailable.' },
  CASE_REVISION_MISMATCH: { status: 409, message: 'The case changed. Reload it before reviewing form answers.' },
  FORM_NOT_AVAILABLE: { status: 404, message: 'Reviewed form answers are unavailable for this program.' },
  FORM_CONTEXT_MISMATCH: { status: 409, message: 'The reviewed form changed. Reload it before saving answers.' },
  FORM_ANSWERS_CONFLICT: { status: 409, message: 'The saved answers changed. Reload them before saving.' },
  SERVICE_UNAVAILABLE: { status: 503, message: 'Form answers are temporarily unavailable. Try again later.' },
  INTERNAL_ERROR: { status: 500, message: 'The form-answer request could not be completed.' },
};

function failure(code: FormAnswerErrorCode): FormAnswerResult {
  return { status: errors[code].status, body: { schemaVersion: '1', error: { code, message: errors[code].message } },
    headers: { 'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}) } };
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function identifier(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value === value.trim() && [...value].length <= 200
    && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(value) && !/[\uD800-\uDFFF]/u.test(value);
}

function parseRequest(value: unknown, save: boolean): ReadFormAnswersRequest | SaveFormAnswersRequest | null {
  if (!record(value)) return null;
  const keys = ['schemaVersion', 'caseId', 'expectedCaseRevision', 'programId',
    ...(save ? ['expectedFormContextId', 'expectedAnswerRevision', 'answers'] : [])];
  if (Object.keys(value).length !== keys.length || !keys.every(key => Object.hasOwn(value, key))
    || value.schemaVersion !== '1' || !identifier(value.caseId) || !identifier(value.programId)
    || !Number.isSafeInteger(value.expectedCaseRevision) || Number(value.expectedCaseRevision) < 1) return null;
  const common: ReadFormAnswersRequest = { schemaVersion: '1', caseId: value.caseId,
    expectedCaseRevision: Number(value.expectedCaseRevision), programId: value.programId };
  if (!save) return common;
  if (typeof value.expectedFormContextId !== 'string' || value.expectedFormContextId.length !== 64
    || /[^a-f0-9]/.test(value.expectedFormContextId)
    || !Number.isSafeInteger(value.expectedAnswerRevision) || Number(value.expectedAnswerRevision) < 0) return null;
  try {
    return { ...common, expectedFormContextId: value.expectedFormContextId,
      expectedAnswerRevision: Number(value.expectedAnswerRevision), answers: parseFormAnswerInputs(value.answers) };
  } catch { return null; }
}

function clock(deps: FormAnswerDependencies): string {
  const now = deps.now();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new Error('Invalid server clock.');
  const timestamp = now.toISOString();
  instantMicros(timestamp);
  return timestamp;
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (record(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

class Unavailable extends Error {}
class InvalidAnswers extends Error {}

interface LoadedFormContext { context: FormAnswerContext; template: VerifiedFormTemplate }

async function contextFor(programId: string, deps: FormAnswerDependencies): Promise<LoadedFormContext | null> {
  let loaded: { template: VerifiedFormTemplate; bytes: Uint8Array } | null;
  try { loaded = await deps.loadFormTemplate(programId); } catch { throw new Unavailable(); }
  if (loaded === null) return null;
  if (!record(loaded) || !(loaded.bytes instanceof Uint8Array)
    || loaded.bytes.byteLength < 8 || loaded.bytes.byteLength > MAX_TEMPLATE_BYTES) {
    throw new Error('Invalid template bytes.');
  }
  const detached = structuredClone(loaded);
  const template = defineVerifiedFormTemplate(detached.template);
  if (template.programId !== programId) throw new Error('Form identity mismatch.');
  verifyTemplateBytes(detached.bytes, template.templateSha256);
  if (template.reviewedOn > clock(deps).slice(0, 10)) throw new Error('Future form review.');
  return { context: createFormAnswerContext(template), template };
}

function validatedSaved(
  value: unknown, userId: string, caseId: string, caseRevision: number, programId: string, now: string,
): SavedFormAnswerSet | null {
  if (value === null) return null;
  const saved = parseSavedFormAnswers(value);
  if (saved.caseId !== caseId || saved.programId !== programId || saved.caseRevision > caseRevision
    || saved.updatedBy !== userId || saved.answers.some(answer => answer.reviewedBy !== null && answer.reviewedBy !== userId)
    || instantMicros(saved.updatedAt) > instantMicros(now)) throw new Error('Invalid saved answer identity.');
  return saved;
}

function response(caseId: string, caseRevision: number, context: FormAnswerContext, saved: SavedFormAnswerSet | null): FormAnswerResult {
  const isCurrent = saved !== null && saved.caseRevision === caseRevision && saved.formContextId === context.formContextId
    && saved.formVersion === context.formVersion && saved.mappingVersion === context.mappingVersion;
  return { status: 200, body: structuredClone({ schemaVersion: '1', caseId, caseRevision, context, saved, isCurrent }),
    headers: { 'Cache-Control': 'no-store' } };
}

async function processRequest(
  input: { body: unknown; bearerToken: string | null }, deps: FormAnswerDependencies, save: boolean,
): Promise<FormAnswerResult> {
  const token = input.bearerToken;
  if (typeof token !== 'string' || token.length === 0 || /\s/.test(token)) return failure('UNAUTHENTICATED');
  let user: AuthenticatedUser | null;
  try { user = await deps.authenticate(token); } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (user === null) return failure('UNAUTHENTICATED');
  if (!record(user) || !identifier(user.userId)) return failure('INTERNAL_ERROR');
  const userId = user.userId;
  const request = parseRequest(input.body, save);
  if (request === null) return failure('INVALID_REQUEST');
  let loaded: CaseSnapshot | null;
  try { loaded = await deps.cases.loadForUser(userId, request.caseId); } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (loaded === null) return failure('CASE_NOT_FOUND');
  const snapshot = structuredClone(loaded);
  const validatedAt = clock(deps);
  matchPrograms(snapshot, [], { evaluatedAt: validatedAt, evaluationDate: validatedAt.slice(0, 10) });
  if (snapshot.caseId !== request.caseId) return failure('INTERNAL_ERROR');
  if (snapshot.revision !== request.expectedCaseRevision) return failure('CASE_REVISION_MISMATCH');
  const loadedForm = await contextFor(request.programId, deps);
  if (loadedForm === null) return failure('FORM_NOT_AVAILABLE');
  const { context, template } = loadedForm;
  if (save && (request as SaveFormAnswersRequest).expectedFormContextId !== context.formContextId) return failure('FORM_CONTEXT_MISMATCH');
  if (save) {
    try { validateAnswersForTemplate((request as SaveFormAnswersRequest).answers, template); } catch { throw new InvalidAnswers(); }
  }

  const currentContext = await contextFor(request.programId, deps);
  if (currentContext === null || canonical(context) !== canonical(currentContext.context)) return failure('FORM_CONTEXT_MISMATCH');
  const repositoryInput = { userId, caseId: request.caseId, revision: snapshot.revision, programId: request.programId };
  if (!save) {
    let result: FormAnswerReadResult;
    try { result = await deps.cases.readFormAnswersIfCurrent(repositoryInput); } catch { return failure('SERVICE_UNAVAILABLE'); }
    if (result.status === 'not_found') return failure('CASE_NOT_FOUND');
    if (result.status === 'conflict') return failure('CASE_REVISION_MISMATCH');
    if (result.status !== 'found') return failure('INTERNAL_ERROR');
    const saved = validatedSaved(result.saved, userId, request.caseId, snapshot.revision, request.programId, clock(deps));
    if (saved !== null && saved.formContextId === context.formContextId) {
      if (saved.formVersion !== context.formVersion || saved.mappingVersion !== context.mappingVersion) {
        throw new Error('Saved form context is inconsistent.');
      }
      validateAnswersForTemplate(saved.answers, template);
    }
    return response(request.caseId, snapshot.revision, context, saved);
  }

  const replacement = request as SaveFormAnswersRequest;
  if (!Number.isSafeInteger(snapshot.revision + 1) || !Number.isSafeInteger(replacement.expectedAnswerRevision + 1)) {
    return failure('INTERNAL_ERROR');
  }
  const updatedAt = clock(deps);
  if (instantMicros(updatedAt) < instantMicros(validatedAt)) throw new Error('Clock moved backwards.');
  const nextSnapshot = { ...snapshot, revision: snapshot.revision + 1 };
  let expected: SavedFormAnswerSet;
  try {
    expected = createSavedFormAnswers({ snapshot: nextSnapshot, context,
      answerRevision: replacement.expectedAnswerRevision + 1, answers: replacement.answers, updatedAt, updatedBy: userId });
  } catch { return failure('INVALID_REQUEST'); }
  let result: FormAnswerSaveResult;
  try {
    result = await deps.cases.saveFormAnswersIfCurrent({ ...repositoryInput,
      expectedAnswerRevision: replacement.expectedAnswerRevision, answers: structuredClone(expected) });
  } catch { return failure('SERVICE_UNAVAILABLE'); }
  if (result.status === 'not_found') return failure('CASE_NOT_FOUND');
  if (result.status === 'conflict') return failure('CASE_REVISION_MISMATCH');
  if (result.status === 'answers_conflict') return failure('FORM_ANSWERS_CONFLICT');
  if (result.status !== 'saved' || result.caseRevision !== nextSnapshot.revision) return failure('INTERNAL_ERROR');
  const saved = validatedSaved(result.saved, userId, request.caseId, result.caseRevision, request.programId, clock(deps));
  if (canonical(saved) !== canonical(expected)) return failure('INTERNAL_ERROR');
  return response(request.caseId, result.caseRevision, context, saved);
}

async function handle(input: { body: unknown; bearerToken: string | null }, deps: FormAnswerDependencies, save: boolean): Promise<FormAnswerResult> {
  try { return await processRequest(input, deps, save); }
  catch (error) { return failure(error instanceof Unavailable ? 'SERVICE_UNAVAILABLE' : error instanceof InvalidAnswers ? 'INVALID_REQUEST' : 'INTERNAL_ERROR'); }
}

export function handleReadFormAnswers(input: { body: unknown; bearerToken: string | null }, deps: FormAnswerDependencies): Promise<FormAnswerResult> {
  return handle(input, deps, false);
}

export function handleSaveFormAnswers(input: { body: unknown; bearerToken: string | null }, deps: FormAnswerDependencies): Promise<FormAnswerResult> {
  return handle(input, deps, true);
}
