import { createHash } from 'node:crypto';
import { instantMicros } from '../packets.ts';
import { parseSavedFormAnswers, type SavedFormAnswerSet } from '../forms/form-answers.ts';
import { validateSanitizedEvidenceImage, validateSanitizedEvidenceImageAsync,
  validateSanitizedEvidenceImagesAsync } from './image-sanitizer.ts';
import { exportEvidenceFitsBudget } from './export-budget.ts';
import type { CaseSnapshot } from '../types.ts';
import { MAX_SELECTED_EVIDENCE, type EvidenceAsset, type EvidenceDescriptor,
  type EvidenceSelection, type SanitizedEvidenceImage } from './types.ts';

export function evidenceIdentifier(value: unknown): value is string {
  return typeof value === 'string' && value.trim() === value && value.length > 0
    && Array.from(value).length <= 200 && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u.test(value)
    && !Array.from(value).some(char => { const code = char.codePointAt(0)!; return code >= 0xd800 && code <= 0xdfff; });
}

export function evidenceRevision(value: unknown, zeroAllowed = false): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= (zeroAllowed ? 0 : 1);
}

export function evidenceInstant(value: unknown): value is string {
  if (typeof value !== 'string' || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z$/.test(value)
    || value.startsWith('0000')) return false;
  try { instantMicros(value); return true; } catch { return false; }
}

export function parseEvidenceSelections(value: unknown): EvidenceSelection[] {
  check(Array.isArray(value) && value.length <= MAX_SELECTED_EVIDENCE);
  const seen = new Set<string>();
  return value.map(item => {
    check(object(item, ['evidenceId', 'expectedEvidenceRevision', 'reviewedForExport']));
    check(evidenceIdentifier(item.evidenceId) && evidenceRevision(item.expectedEvidenceRevision)
      && item.reviewedForExport === true && !seen.has(item.evidenceId));
    seen.add(item.evidenceId);
    return { evidenceId: item.evidenceId, expectedEvidenceRevision: item.expectedEvidenceRevision, reviewedForExport: true };
  });
}

export function parseSanitizedEvidenceImage(value: unknown): SanitizedEvidenceImage {
  check(object(value, ['bytes', 'mediaType', 'byteLength', 'sha256', 'width', 'height', 'processingVersion']));
  check(value.mediaType === 'image/png' && value.processingVersion === 'evidence-png-v1' && value.bytes instanceof Uint8Array);
  const actual = validateSanitizedEvidenceImage(value.bytes);
  check(value.byteLength === actual.byteLength && value.sha256 === actual.sha256
    && value.width === actual.width && value.height === actual.height);
  return { bytes: Uint8Array.from(value.bytes), mediaType: 'image/png', processingVersion: 'evidence-png-v1', ...actual };
}

export async function parseSanitizedEvidenceImageAsync(value: unknown): Promise<SanitizedEvidenceImage> {
  check(object(value, ['bytes', 'mediaType', 'byteLength', 'sha256', 'width', 'height', 'processingVersion']));
  check(value.mediaType === 'image/png' && value.processingVersion === 'evidence-png-v1' && value.bytes instanceof Uint8Array);
  const expected = { byteLength: value.byteLength, sha256: value.sha256, width: value.width, height: value.height };
  const actual = await validateSanitizedEvidenceImageAsync(value.bytes);
  check(expected.byteLength === actual.byteLength && expected.sha256 === actual.sha256
    && expected.width === actual.width && expected.height === actual.height);
  return { mediaType: 'image/png', processingVersion: 'evidence-png-v1', ...actual };
}

export function parseEvidenceDescriptor(value: unknown): EvidenceDescriptor {
  check(object(value, ['evidenceId', 'evidenceRevision', 'caseId', 'findingId', 'mediaType', 'byteLength',
    'sha256', 'width', 'height', 'capturedAt', 'preparedAt', 'processingVersion']));
  check(evidenceIdentifier(value.evidenceId) && evidenceIdentifier(value.caseId) && evidenceIdentifier(value.findingId)
    && evidenceRevision(value.evidenceRevision) && value.mediaType === 'image/png'
    && evidenceRevision(value.byteLength) && value.byteLength <= 24 * 1024 * 1024
    && evidenceRevision(value.width) && value.width <= 8192 && evidenceRevision(value.height) && value.height <= 8192
    && value.width * value.height <= 16_000_000 && typeof value.sha256 === 'string' && /^[a-f0-9]{64}$/.test(value.sha256)
    && value.processingVersion === 'evidence-png-v1' && evidenceInstant(value.preparedAt)
    && (value.capturedAt === null || evidenceInstant(value.capturedAt)));
  check(value.capturedAt === null || instantMicros(value.capturedAt as string) <= instantMicros(value.preparedAt as string));
  return structuredClone(value) as unknown as EvidenceDescriptor;
}

export function parseEvidenceAsset(value: unknown): EvidenceAsset {
  check(object(value, ['descriptor', 'bytes']));
  const descriptor = parseEvidenceDescriptor(value.descriptor);
  const image = parseSanitizedEvidenceImage({ bytes: value.bytes, mediaType: descriptor.mediaType,
    byteLength: descriptor.byteLength, sha256: descriptor.sha256, width: descriptor.width, height: descriptor.height,
    processingVersion: descriptor.processingVersion });
  return { descriptor, bytes: image.bytes };
}

export async function parseEvidenceAssetAsync(value: unknown): Promise<EvidenceAsset> {
  check(object(value, ['descriptor', 'bytes']));
  const descriptor = parseEvidenceDescriptor(value.descriptor);
  const image = await parseSanitizedEvidenceImageAsync({ bytes: value.bytes, mediaType: descriptor.mediaType,
    byteLength: descriptor.byteLength, sha256: descriptor.sha256, width: descriptor.width, height: descriptor.height,
    processingVersion: descriptor.processingVersion });
  return { descriptor, bytes: image.bytes };
}

export async function parseEvidenceAssetsAsync(values: ReadonlyArray<unknown>): Promise<EvidenceAsset[]> {
  check(Array.isArray(values) && values.length <= MAX_SELECTED_EVIDENCE);
  const captured = values.map(value => {
    check(object(value, ['descriptor', 'bytes']));
    const descriptor = parseEvidenceDescriptor(value.descriptor);
    check(value.bytes instanceof Uint8Array && value.bytes.byteLength === descriptor.byteLength);
    return { descriptor, bytes: value.bytes };
  });
  check(exportEvidenceFitsBudget(captured.map(asset => asset.descriptor)));
  const images = await validateSanitizedEvidenceImagesAsync(captured.map(asset => asset.bytes));
  return captured.map(({ descriptor }, index) => {
    const image = images[index];
    check(descriptor.byteLength === image.byteLength && descriptor.sha256 === image.sha256
      && descriptor.width === image.width && descriptor.height === image.height);
    return { descriptor, bytes: image.bytes };
  });
}

export function formAnswersFingerprint(value: SavedFormAnswerSet | null): string | null {
  if (value === null) return null;
  return createHash('sha256').update(canonicalJson(parseSavedFormAnswers(value))).digest('hex');
}

export function caseFingerprint(value: CaseSnapshot): string {
  return createHash('sha256').update(canonicalJson(value)).digest('hex');
}

export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (typeof value === 'object' && value !== null) {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function object(value: unknown, keys: string[]): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function check(condition: unknown): asserts condition {
  if (!condition) throw new Error('Invalid private evidence data.');
}
