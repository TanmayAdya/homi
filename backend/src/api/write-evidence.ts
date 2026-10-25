import { matchPrograms } from '../matcher.ts';
import { instantMicros } from '../packets.ts';
import { MAX_IMAGE_INPUT_BYTES } from '../evidence/image-sanitizer.ts';
import { registerTrustedEvidence } from '../evidence/register-trusted-evidence.ts';
import type { EvidenceRepository } from '../evidence/repository.ts';
import type { EvidenceDescriptor } from '../evidence/types.ts';
import { evidenceIdentifier, evidenceInstant, evidenceRevision, parseEvidenceAssetAsync,
  parseEvidenceDescriptor } from '../evidence/validation.ts';
import type { AuthenticatedUser, MatchCaseRepository } from './match-case.ts';

export interface WriteEvidenceDependencies {
  authenticate(token: string): Promise<AuthenticatedUser | null>;
  cases: EvidenceRepository & Pick<MatchCaseRepository, 'loadForUser'>;
  now(): Date;
}

export interface UploadEvidenceRequest {
  schemaVersion: '1'; caseId: string; expectedCaseRevision: number; expectedCatalogRevision: number;
  evidenceId: string; expectedEvidenceRevision: number; findingId: string;
  capturedAt: string | null; imageBase64: string;
}
export type DeleteEvidenceRequest = Pick<UploadEvidenceRequest, 'schemaVersion' | 'caseId' | 'expectedCaseRevision'
  | 'expectedCatalogRevision' | 'evidenceId' | 'expectedEvidenceRevision'>;
export interface UploadEvidenceResponse {
  schemaVersion: '1'; caseId: string; caseRevision: number; catalogRevision: number; evidence: EvidenceDescriptor;
}
export interface DeleteEvidenceResponse {
  schemaVersion: '1'; caseId: string; caseRevision: number; catalogRevision: number;
  evidenceId: string; evidenceRevision: number; deleted: true;
}
export interface WriteEvidenceResult {
  status: number;
  body: UploadEvidenceResponse | DeleteEvidenceResponse
    | { schemaVersion: '1'; error: { code: WriteEvidenceErrorCode; message: string } };
  headers: Record<string, string>;
}

const errors = {
  UNAUTHENTICATED: [401, 'Sign in to change private evidence.'],
  INVALID_REQUEST: [400, 'Provide a valid evidence request with a supported image encoding.'],
  CASE_NOT_FOUND: [404, 'The requested case or linked evidence is unavailable.'],
  CASE_REVISION_MISMATCH: [409, 'The case changed. Reload it before continuing.'],
  EVIDENCE_CONFLICT: [409, 'The evidence changed. Reload the current catalog before continuing.'],
  INVALID_IMAGE: [422, 'Provide a supported JPEG or PNG within the image size limits.'],
  UPLOAD_BUSY: [429, 'Another image is being prepared. Try again shortly.'],
  STORAGE_LIMIT_REACHED: [507, 'Private storage has reached its limit.'],
  SERVICE_UNAVAILABLE: [503, 'Private evidence storage is temporarily unavailable. Reload the catalog before retrying a write.'],
  INTERNAL_ERROR: [500, 'The private evidence request could not be confirmed. Reload the catalog before retrying a write.'],
} as const;
export type WriteEvidenceErrorCode = keyof typeof errors;
class RequestFailure extends Error {
  readonly code: WriteEvidenceErrorCode;
  constructor(code: WriteEvidenceErrorCode) { super(code); this.code = code; }
}
function fail(code: WriteEvidenceErrorCode): never { throw new RequestFailure(code); }
const activeUploads = new WeakSet<WriteEvidenceDependencies>();
export const MAX_IMAGE_BASE64_CHARACTERS = Math.ceil(MAX_IMAGE_INPUT_BYTES / 3) * 4;
type Input = { body: unknown; bearerToken: string | null; signal?: AbortSignal };

function object(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function base64Length(value: unknown): number {
  if (typeof value !== 'string' || value.length < 12 || value.length > MAX_IMAGE_BASE64_CHARACTERS
    || value.length % 4 !== 0) fail('INVALID_REQUEST');
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  const length = value.length / 4 * 3 - padding;
  if (length < 8 || length > MAX_IMAGE_INPUT_BYTES) fail('INVALID_REQUEST');
  let last = 0;
  for (let index = 0; index < value.length - padding; index++) {
    const code = value.charCodeAt(index);
    last = code >= 65 && code <= 90 ? code - 65 : code >= 97 && code <= 122 ? code - 71
      : code >= 48 && code <= 57 ? code + 4 : code === 43 ? 62 : code === 47 ? 63 : -1;
    if (last < 0) fail('INVALID_REQUEST');
  }
  if ((padding === 1 && (last & 3) !== 0) || (padding === 2 && (last & 15) !== 0)) fail('INVALID_REQUEST');
  return length;
}

function parseRequest(body: unknown, upload: true): UploadEvidenceRequest;
function parseRequest(body: unknown, upload: false): DeleteEvidenceRequest;
function parseRequest(body: unknown, upload: boolean): UploadEvidenceRequest | DeleteEvidenceRequest {
  const keys = ['schemaVersion', 'caseId', 'expectedCaseRevision', 'expectedCatalogRevision', 'evidenceId', 'expectedEvidenceRevision'];
  if (upload) keys.push('findingId', 'capturedAt', 'imageBase64');
  if (!object(body, keys)) fail('INVALID_REQUEST');
  const value = Object.fromEntries(keys.map(key => [key, body[key]]));
  if (value.schemaVersion !== '1' || !evidenceIdentifier(value.caseId) || !evidenceIdentifier(value.evidenceId)
    || !evidenceRevision(value.expectedCaseRevision) || !evidenceRevision(value.expectedCatalogRevision, true)
    || value.expectedCatalogRevision >= Number.MAX_SAFE_INTEGER
    || !evidenceRevision(value.expectedEvidenceRevision, upload) || value.expectedEvidenceRevision >= Number.MAX_SAFE_INTEGER) fail('INVALID_REQUEST');
  if (upload) {
    if (!evidenceIdentifier(value.findingId) || (value.capturedAt !== null && !evidenceInstant(value.capturedAt))) fail('INVALID_REQUEST');
    base64Length(value.imageBase64);
  }
  return value as unknown as UploadEvidenceRequest | DeleteEvidenceRequest;
}

async function storage<T>(operation: () => Promise<T>): Promise<T> {
  try { return await operation(); } catch { return fail('SERVICE_UNAVAILABLE'); }
}
function time(deps: WriteEvidenceDependencies): string {
  const now = deps.now();
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) fail('INTERNAL_ERROR');
  const value = now.toISOString();
  if (!evidenceInstant(value)) fail('INTERNAL_ERROR');
  return value;
}
function repositoryFailure(value: unknown): never {
  if (!object(value, ['status'])) fail('INTERNAL_ERROR');
  switch (value.status) {
    case 'not_found': return fail('CASE_NOT_FOUND');
    case 'conflict': return fail('CASE_REVISION_MISMATCH');
    case 'evidence_conflict': return fail('EVIDENCE_CONFLICT');
    case 'quota_exceeded': return fail('STORAGE_LIMIT_REACHED');
    case 'invalid_input': return fail('INVALID_REQUEST');
    case 'invalid_image': return fail('INVALID_IMAGE');
    case 'service_unavailable': return fail('SERVICE_UNAVAILABLE');
    default: return fail('INTERNAL_ERROR');
  }
}
async function authenticate(token: string, deps: WriteEvidenceDependencies, signal?: AbortSignal): Promise<string> {
  if (signal?.aborted) fail('SERVICE_UNAVAILABLE');
  let stop: () => void = () => {};
  const stopped = new Promise<{ status: 'stopped' }>(resolve => { stop = () => resolve({ status: 'stopped' }); });
  signal?.addEventListener('abort', stop, { once: true });
  const timer = setTimeout(stop, 10_000);
  timer.unref();
  try {
    const result = await Promise.race([
      Promise.resolve().then(() => deps.authenticate(token))
        .then(user => ({ status: 'authenticated' as const, user }), () => ({ status: 'stopped' as const })),
      stopped,
    ]);
    if (result.status === 'stopped' || signal?.aborted) fail('SERVICE_UNAVAILABLE');
    const user = result.user;
    if (user === null) fail('UNAUTHENTICATED');
    if (typeof user !== 'object' || Array.isArray(user) || !evidenceIdentifier(user.userId)) fail('INTERNAL_ERROR');
    return user.userId;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', stop);
  }
}

async function preflight(userId: string, request: DeleteEvidenceRequest, deps: WriteEvidenceDependencies,
  upload: UploadEvidenceRequest | null): Promise<void> {
  const loaded = await storage(() => deps.cases.loadForUser(userId, request.caseId));
  if (loaded === null) fail('CASE_NOT_FOUND');
  const snapshot = structuredClone(loaded);
  const checkedAt = time(deps);
  matchPrograms(snapshot, [], { evaluatedAt: checkedAt, evaluationDate: checkedAt.slice(0, 10) });
  if (snapshot.caseId !== request.caseId) fail('INTERNAL_ERROR');
  if (snapshot.revision !== request.expectedCaseRevision) fail('CASE_REVISION_MISMATCH');
  if (upload && !snapshot.findings.some(finding => finding.id === upload.findingId && finding.evidenceIds.includes(request.evidenceId))) fail('CASE_NOT_FOUND');
  if (upload?.capturedAt != null && instantMicros(upload.capturedAt) > instantMicros(checkedAt)) fail('INVALID_REQUEST');
  const result = await storage(() => deps.cases.readEvidenceCatalogForUser(userId, request.caseId));
  if (result?.status !== 'found') repositoryFailure(result);
  if (!object(result, ['status', 'catalog'])) fail('INTERNAL_ERROR');
  const catalog = structuredClone(result.catalog);
  if (!object(catalog, ['schemaVersion', 'caseId', 'caseRevision', 'catalogRevision', 'evidence'])
    || catalog.schemaVersion !== '1' || catalog.caseId !== request.caseId
    || !evidenceRevision(catalog.caseRevision) || !evidenceRevision(catalog.catalogRevision, true)
    || !Array.isArray(catalog.evidence)) fail('INTERNAL_ERROR');
  if (catalog.caseRevision !== request.expectedCaseRevision) fail('CASE_REVISION_MISMATCH');
  if (catalog.catalogRevision !== request.expectedCatalogRevision) fail('EVIDENCE_CONFLICT');
  const seen = new Set<string>();
  const descriptors = catalog.evidence.map(item => {
    const descriptor = parseEvidenceDescriptor(item);
    if (descriptor.caseId !== request.caseId || seen.has(descriptor.evidenceId)
      || instantMicros(descriptor.preparedAt) > instantMicros(checkedAt)
      || !snapshot.findings.some(finding => finding.id === descriptor.findingId && finding.evidenceIds.includes(descriptor.evidenceId))) fail('INTERNAL_ERROR');
    seen.add(descriptor.evidenceId);
    return descriptor;
  });
  const existing = descriptors.find(item => item.evidenceId === request.evidenceId);
  if (existing) {
    if (existing.evidenceRevision !== request.expectedEvidenceRevision
      || (upload && existing.findingId !== upload.findingId)) fail('EVIDENCE_CONFLICT');
  } else if (!upload || request.expectedEvidenceRevision !== 0) {
    fail('EVIDENCE_CONFLICT');
  }
}

function success(body: UploadEvidenceResponse | DeleteEvidenceResponse): WriteEvidenceResult {
  return { status: 200, body, headers: { 'Cache-Control': 'no-store' } };
}
function failure(code: WriteEvidenceErrorCode): WriteEvidenceResult {
  return { status: errors[code][0], body: { schemaVersion: '1', error: { code, message: errors[code][1] } },
    headers: { 'Cache-Control': 'no-store', ...(code === 'UNAUTHENTICATED' ? { 'WWW-Authenticate': 'Bearer' } : {}) } };
}
function bearer(input: Input): string {
  const token = input.bearerToken;
  if (typeof token !== 'string' || token.length === 0 || token.length > 4096 || /\s/.test(token)) fail('UNAUTHENTICATED');
  return token;
}

export async function handleUploadEvidence(input: Input, deps: WriteEvidenceDependencies): Promise<WriteEvidenceResult> {
  let admitted = false;
  try {
    const token = bearer(input);
    if (activeUploads.has(deps)) fail('UPLOAD_BUSY');
    const request = parseRequest(input.body, true);
    activeUploads.add(deps); admitted = true;
    const userId = await authenticate(token, deps, input.signal);
    await preflight(userId, request, deps, request);
    const bytes = Buffer.from(request.imageBase64, 'base64');
    let preparedAt: string | null = null;
    const result = await registerTrustedEvidence({ userId, caseId: request.caseId,
      expectedCaseRevision: request.expectedCaseRevision, expectedCatalogRevision: request.expectedCatalogRevision,
      evidenceId: request.evidenceId, expectedEvidenceRevision: request.expectedEvidenceRevision,
      findingId: request.findingId, capturedAt: request.capturedAt, bytes }, {
      cases: deps.cases, now: () => { preparedAt = time(deps); return new Date(preparedAt); },
    });
    if (result?.status !== 'saved') repositoryFailure(result);
    if (!object(result, ['status', 'asset', 'catalogRevision'])) fail('INTERNAL_ERROR');
    const catalogRevision = result.catalogRevision;
    const asset = await parseEvidenceAssetAsync(result.asset), descriptor = asset.descriptor;
    if (descriptor.caseId !== request.caseId || descriptor.evidenceId !== request.evidenceId
      || descriptor.findingId !== request.findingId || descriptor.evidenceRevision !== request.expectedEvidenceRevision + 1
      || catalogRevision !== request.expectedCatalogRevision + 1
      || descriptor.capturedAt !== request.capturedAt || descriptor.preparedAt !== preparedAt) fail('INTERNAL_ERROR');
    return success({ schemaVersion: '1', caseId: request.caseId, caseRevision: request.expectedCaseRevision,
      catalogRevision, evidence: descriptor });
  } catch (error) { return failure(error instanceof RequestFailure ? error.code : 'INTERNAL_ERROR'); }
  finally { if (admitted) activeUploads.delete(deps); }
}

export async function handleDeleteEvidence(input: Input, deps: WriteEvidenceDependencies): Promise<WriteEvidenceResult> {
  try {
    const token = bearer(input), request = parseRequest(input.body, false);
    const userId = await authenticate(token, deps, input.signal);
    await preflight(userId, request, deps, null);
    const result = await storage(() => deps.cases.deleteEvidenceIfCurrent({ userId, caseId: request.caseId,
      revision: request.expectedCaseRevision, expectedCatalogRevision: request.expectedCatalogRevision,
      evidenceId: request.evidenceId, expectedEvidenceRevision: request.expectedEvidenceRevision }));
    if (result?.status !== 'deleted') repositoryFailure(result);
    if (!object(result, ['status', 'evidenceRevision', 'catalogRevision'])
      || result.evidenceRevision !== request.expectedEvidenceRevision + 1
      || result.catalogRevision !== request.expectedCatalogRevision + 1) fail('INTERNAL_ERROR');
    return success({ schemaVersion: '1', caseId: request.caseId, caseRevision: request.expectedCaseRevision,
      catalogRevision: result.catalogRevision, evidenceId: request.evidenceId,
      evidenceRevision: result.evidenceRevision, deleted: true });
  } catch (error) { return failure(error instanceof RequestFailure ? error.code : 'INTERNAL_ERROR'); }
}
