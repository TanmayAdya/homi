import { evidenceIdentifier as id, evidenceRevision as revision, evidenceInstant as instant } from '../evidence/validation.ts';
import { instantMicros } from '../packets.ts';
import type { ExportArtifactMetadata } from './types.ts';

export const MAX_EXPORT_BYTES = 32 * 1024 * 1024;
export const EXPORT_LIFETIME_MS = 15 * 60 * 1000;

export function parseExportArtifactMetadata(value: unknown): ExportArtifactMetadata {
  check(object(value, ['schemaVersion', 'artifactId', 'caseId', 'caseRevision', 'programId', 'ruleVersion',
    'formVersion', 'mappingVersion', 'formContextId', 'answerRevision', 'evidenceCatalogRevision', 'exportContextId',
    'generatedAt', 'expiresAt', 'recheckAfter', 'status', 'isDemo', 'mediaType', 'byteLength', 'sha256', 'pageCount',
    'renderingVersion', 'selectedEvidence', 'missingItems', 'warnings']));
  check(value.schemaVersion === '1' && ['artifactId', 'caseId', 'programId', 'ruleVersion', 'formVersion', 'mappingVersion'].every(key => id(value[key]))
    && revision(value.caseRevision) && revision(value.answerRevision, true) && revision(value.evidenceCatalogRevision, true)
    && ['formContextId', 'exportContextId', 'sha256'].every(key => typeof value[key] === 'string' && /^[a-f0-9]{64}$/.test(value[key] as string))
    && instant(value.generatedAt) && instant(value.expiresAt) && (value.recheckAfter === null || instant(value.recheckAfter))
    && value.status === 'draft' && typeof value.isDemo === 'boolean' && value.mediaType === 'application/pdf'
    && revision(value.byteLength) && value.byteLength >= 8 && value.byteLength <= MAX_EXPORT_BYTES
    && revision(value.pageCount) && value.pageCount <= 100 && value.renderingVersion === 'draft-export-v1');
  const start = instantMicros(value.generatedAt as string), end = instantMicros(value.expiresAt as string);
  check(end > start && end - start <= BigInt(EXPORT_LIFETIME_MS) * 1000n
    && (value.recheckAfter === null || end <= instantMicros(value.recheckAfter as string)));
  check(Array.isArray(value.selectedEvidence) && value.selectedEvidence.length <= 6);
  const evidenceIds = new Set<string>();
  for (const item of value.selectedEvidence) {
    check(object(item, ['evidenceId', 'evidenceRevision', 'findingId', 'sha256', 'reviewedAt', 'reviewedBy'])
      && id(item.evidenceId) && id(item.findingId) && id(item.reviewedBy) && revision(item.evidenceRevision)
      && typeof item.sha256 === 'string' && /^[a-f0-9]{64}$/.test(item.sha256)
      && item.reviewedAt === value.generatedAt && !evidenceIds.has(item.evidenceId));
    evidenceIds.add(item.evidenceId);
  }
  check(Array.isArray(value.missingItems) && value.missingItems.length <= 500);
  const itemIds = new Set<string>();
  for (const item of value.missingItems) {
    check(object(item, ['id', 'description', 'resolvedBy']) && id(item.id) && !itemIds.has(item.id)
      && typeof item.description === 'string' && item.description.trim().length > 0 && Array.from(item.description).length <= 4000
      && typeof item.resolvedBy === 'string' && ['resident', 'program', 'professional'].includes(item.resolvedBy));
    itemIds.add(item.id);
  }
  check(Array.isArray(value.warnings) && value.warnings.length >= 2 && value.warnings.length <= 3
    && value.warnings[0] === 'INCOMPLETE_DRAFT' && value.warnings[1] === 'NOT_SUBMITTED'
    && (value.warnings.length === 2 || value.warnings[2] === 'POLICY_CURRENTNESS_UNKNOWN'));
  check(value.recheckAfter !== null || value.warnings.includes('POLICY_CURRENTNESS_UNKNOWN'));
  return structuredClone(value) as unknown as ExportArtifactMetadata;
}

function object(value: unknown, keys: string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
function check(condition: unknown): asserts condition {
  if (!condition) throw new Error('Invalid draft export metadata.');
}

export function parseStoredExportArtifactMetadata(value:unknown):ExportArtifactMetadata {
  if(!value||typeof value!=='object'||Array.isArray(value)||(value as {schemaVersion?:unknown}).schemaVersion!=='2')return parseExportArtifactMetadata(value);
  const v=value as Record<string,unknown>;check(v.renderingVersion==='draft-export-annotations-v2'&&Array.isArray(v.selectedEvidence));
  const selection=v.selectedEvidence.map(item=>{
    check(object(item,['evidenceId','evidenceRevision','findingId','sha256','reviewedAt','reviewedBy','annotationRevision','annotationSha256'])
      &&revision(item.annotationRevision,true)&&typeof item.annotationSha256==='string'&&/^[a-f0-9]{64}$/.test(item.annotationSha256));
    const {annotationRevision,annotationSha256,...base}=item;return base;
  });
  parseExportArtifactMetadata({...v,schemaVersion:'1',renderingVersion:'draft-export-v1',selectedEvidence:selection});
  return structuredClone(value) as ExportArtifactMetadata;
}
