import { matchPrograms } from '../matcher.ts';
import { instantMicros } from '../packets.ts';
import type { CaseSnapshot } from '../types.ts';
import { MAX_IMAGE_INPUT_BYTES, sanitizeEvidenceImage } from './image-sanitizer.ts';
import type { EvidenceRepository, EvidenceRepositoryFailure } from './repository.ts';
import type { EvidenceAsset, SanitizedEvidenceImage } from './types.ts';
import { evidenceIdentifier, evidenceInstant, evidenceRevision, parseSanitizedEvidenceImageAsync } from './validation.ts';

export interface TrustedEvidenceRegistration {
  userId: string;
  caseId: string;
  expectedCaseRevision: number;
  expectedCatalogRevision: number;
  evidenceId: string;
  expectedEvidenceRevision: number;
  findingId: string;
  capturedAt: string | null;
  bytes: Uint8Array;
}

export interface TrustedEvidenceRegistrationDependencies {
  cases: EvidenceRepository & { loadForUser(userId: string, caseId: string): Promise<CaseSnapshot | null> };
  now(): Date;
  sanitize?(bytes: Uint8Array): Promise<SanitizedEvidenceImage>;
}

export type TrustedEvidenceRegistrationResult =
  | { status: 'saved'; asset: EvidenceAsset; catalogRevision: number }
  | EvidenceRepositoryFailure
  | { status: 'invalid_input' | 'invalid_image' | 'service_unavailable' };

export async function registerTrustedEvidence(
  input: TrustedEvidenceRegistration,
  deps: TrustedEvidenceRegistrationDependencies,
): Promise<TrustedEvidenceRegistrationResult> {
  if (!validInput(input)) return { status: 'invalid_input' };
  const request = { ...input, bytes: Uint8Array.from(input.bytes) };
  let startedAt: string;
  try {
    startedAt = serverTime(deps.now());
    if (request.capturedAt !== null && instantMicros(request.capturedAt) > instantMicros(startedAt)) return { status: 'invalid_input' };
    const loaded = await deps.cases.loadForUser(request.userId, request.caseId);
    if (loaded === null) return { status: 'not_found' };
    const snapshot = structuredClone(loaded);
    matchPrograms(snapshot, [], { evaluatedAt: startedAt, evaluationDate: startedAt.slice(0, 10) });
    if (snapshot.caseId !== request.caseId) return { status: 'service_unavailable' };
    if (snapshot.revision !== request.expectedCaseRevision) return { status: 'conflict' };
    if (!snapshot.findings.some(finding => finding.id === request.findingId && finding.evidenceIds.includes(request.evidenceId))) {
      return { status: 'not_found' };
    }
    const catalogResult = await deps.cases.readEvidenceCatalogForUser(request.userId, request.caseId);
    if (catalogResult.status !== 'found') return catalogResult;
    if (catalogResult.catalog.caseId !== request.caseId) return { status: 'service_unavailable' };
    if (catalogResult.catalog.caseRevision !== request.expectedCaseRevision) return { status: 'conflict' };
    if (catalogResult.catalog.catalogRevision !== request.expectedCatalogRevision) return { status: 'evidence_conflict' };
    const existing = catalogResult.catalog.evidence.find(asset => asset.evidenceId === request.evidenceId);
    if (existing && (existing.evidenceRevision !== request.expectedEvidenceRevision || existing.findingId !== request.findingId)) {
      return { status: 'evidence_conflict' };
    }
  } catch { return { status: 'service_unavailable' }; }
  let image: SanitizedEvidenceImage;
  try {
    image = deps.sanitize ? await parseSanitizedEvidenceImageAsync(await deps.sanitize(request.bytes))
      : await sanitizeEvidenceImage(request.bytes);
  }
  catch { return { status: 'invalid_image' }; }
  try {
    const preparedAt = serverTime(deps.now());
    if (instantMicros(preparedAt) < instantMicros(startedAt)) return { status: 'service_unavailable' };
    return await deps.cases.saveEvidenceIfCurrent({ userId: request.userId, caseId: request.caseId,
      revision: request.expectedCaseRevision, expectedCatalogRevision: request.expectedCatalogRevision,
      evidenceId: request.evidenceId, expectedEvidenceRevision: request.expectedEvidenceRevision,
      findingId: request.findingId, image, capturedAt: request.capturedAt, preparedAt });
  } catch { return { status: 'service_unavailable' }; }
}

function validInput(value: TrustedEvidenceRegistration): boolean {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === 9
    && ['userId', 'caseId', 'expectedCaseRevision', 'expectedCatalogRevision', 'evidenceId',
      'expectedEvidenceRevision', 'findingId', 'capturedAt', 'bytes'].every(key => Object.hasOwn(value, key))
    && [value.userId, value.caseId, value.evidenceId, value.findingId].every(evidenceIdentifier)
    && evidenceRevision(value.expectedCaseRevision) && evidenceRevision(value.expectedCatalogRevision, true)
    && evidenceRevision(value.expectedEvidenceRevision, true)
    && (value.capturedAt === null || evidenceInstant(value.capturedAt))
    && value.bytes instanceof Uint8Array && value.bytes.byteLength >= 8 && value.bytes.byteLength <= MAX_IMAGE_INPUT_BYTES;
}

function serverTime(value: Date): string {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) throw new Error('Invalid server clock.');
  const result = value.toISOString();
  if (!evidenceInstant(result)) throw new Error('Invalid server clock.');
  return result;
}
