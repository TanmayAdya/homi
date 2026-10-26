import type { PoolClient } from 'pg';
import { createHash } from 'node:crypto';
import { canonicalJson, evidenceIdentifier, evidenceRevision, parseEvidenceDescriptor } from '../evidence/validation.ts';
import { intakeDefinition } from '../programs/intake.ts';
import { object, check, uuid, instant } from './validation.ts';

export const SENSITIVE_ROUTES = ['list-sensitive-options', 'preview-sensitive-sharing', 'publish-sensitive-sharing',
  'read-sensitive-sharing', 'preview-sensitive-photo', 'read-sensitive-photo', 'preview-sensitive-report', 'read-sensitive-report'] as const;
export type SensitiveRoute = typeof SENSITIVE_ROUTES[number];
export interface SensitiveSelection { photoIds: string[]; measurementIds: string[]; answerIds: string[] }
export interface SensitiveRequest { schemaVersion: '3'; membershipId: string; expectedPermissionRevision: number;
  expectedCaseRevision?: number; expectedCatalogRevision?: number; selection?: SensitiveSelection; allowPdf?: boolean;
  expiresAt?: string; previewHash?: string; mutationId?: string; sourceHash?: string; evidenceId?: string; expectedEvidenceRevision?: number }
const hash = (v: unknown) => createHash('sha256').update(canonicalJson(v)).digest('hex');
export const sensitiveId = (kind: 'measurement' | 'answer', parent: string, key: string) => `${kind}-${hash([parent, key])}`;
export function parseSensitiveSelection(v: unknown): SensitiveSelection {
  object(v, ['photoIds', 'measurementIds', 'answerIds']);
  for (const [key, max] of [['photoIds', 6], ['measurementIds', 32], ['answerIds', 32]] as const) {
    check(Array.isArray(v[key]) && v[key].length <= max && v[key].every(evidenceIdentifier) && new Set(v[key]).size === v[key].length);
  }
  return structuredClone(v) as unknown as SensitiveSelection;
}
const common = ['schemaVersion', 'membershipId', 'expectedPermissionRevision'];
const preview = ['expectedCaseRevision', 'expectedCatalogRevision', 'selection', 'allowPdf', 'expiresAt'];
const fields: Record<SensitiveRoute, string[]> = {
  'list-sensitive-options': [], 'read-sensitive-sharing': [],
  'preview-sensitive-sharing': preview, 'publish-sensitive-sharing': [...preview, 'previewHash', 'mutationId'],
  'preview-sensitive-report': [...preview, 'previewHash'], 'read-sensitive-report': ['sourceHash'],
  'preview-sensitive-photo': ['expectedCaseRevision', 'expectedCatalogRevision', 'evidenceId', 'expectedEvidenceRevision'],
  'read-sensitive-photo': ['sourceHash', 'evidenceId', 'expectedEvidenceRevision'],
};
export function parseSensitiveRequest(route: SensitiveRoute, v: unknown): SensitiveRequest {
  object(v, [...common, ...fields[route]]);
  check(v.schemaVersion === '3' && uuid(v.membershipId) && evidenceRevision(v.expectedPermissionRevision));
  for (const key of ['expectedCaseRevision', 'expectedEvidenceRevision']) if (key in v) check(evidenceRevision(v[key]));
  if ('expectedCatalogRevision' in v) check(evidenceRevision(v.expectedCatalogRevision, true));
  for (const key of ['sourceHash', 'previewHash']) if (key in v) check(typeof v[key] === 'string' && /^[a-f0-9]{64}$/.test(v[key]));
  if ('selection' in v) { parseSensitiveSelection(v.selection); check(typeof v.allowPdf === 'boolean' && instant(v.expiresAt)); }
  if ('mutationId' in v) check(uuid(v.mutationId));
  if ('evidenceId' in v) check(evidenceIdentifier(v.evidenceId));
  return structuredClone(v) as unknown as SensitiveRequest;
}

const versions = {
  'scfhp-eaa': 'a435cbfede8e433831b80d2808b5aa611eb796553ab596ce20d089530e04c1a5',
  'hpsm-eaa': '4059c929ea12ef5ae544ccbf65df00360c8ee15ffb72ff5d66cbf977f4417e37',
  'rtp-home-repair': 'b65e4a71378a4eff16968fe695a90dbb4eb2e5f4396e35c4889a253f25f62f72',
} as const;
const categories: Record<string, 'financial' | 'health' | 'private'> = {
  activeMembershipReported: 'health', professionalEvaluationReported: 'health', professionalOrderReported: 'health',
  careManagerEngagedReported: 'health', otherFundingReported: 'financial', estimatedCostUsd: 'financial', priorEaaPaidUsd: 'financial',
  ownerOccupiedReported: 'financial', otherPropertyReported: 'financial', incomeDocumentsReady: 'financial', ownershipDocumentsReady: 'financial',
  willingServicesReported: 'private', intendRemainTwoYearsReported: 'private', residenceDocumentsReady: 'private', repairRequest: 'private',
};
export function sensitiveQuestionMetadata() {
  return Object.fromEntries(Object.entries(versions).flatMap(([id, version]) => {
    const definition = intakeDefinition(id);
    return definition?.questionnaireVersion === version ? [[id, { questionnaireVersion: version,
      questions: definition.questions.filter(q => Object.hasOwn(categories, q.key)).map(q => ({
        key: q.key, label: q.label, category: categories[q.key], id: sensitiveId('answer', id, q.key),
      })) }]] : [];
  }));
}
export async function executeSensitive(client: PoolClient, route: SensitiveRoute, input: SensitiveRequest) {
  const result = (await client.query('SELECT safeathome_private.sensitive_operation($1,$2::jsonb,$3::jsonb) AS result',
    [route, JSON.stringify({ ...input, requestHash: hash(input) }), JSON.stringify(sensitiveQuestionMetadata())])).rows[0].result;
  check(['ok', 'not_found', 'conflict', 'quota_exceeded', 'invalid_request'].includes(result.status));
  return result as { status: 'ok'; data: Record<string, any> } | { status: 'not_found' | 'conflict' | 'quota_exceeded' | 'invalid_request' };
}
export function validateSensitiveScope(v: unknown) {
  check(v !== null && typeof v === 'object' && !Array.isArray(v));
  if (Object.keys(v).length === 0) return;
  object(v, ['selection', 'allowPdf', 'expiresAt', 'content', 'sourceHash', 'caseRevision', 'catalogRevision', 'publishedAt', 'mutationId', 'requestHash']);
  const selection = parseSensitiveSelection(v.selection);
  check(typeof v.allowPdf === 'boolean' && instant(v.expiresAt) && instant(v.publishedAt) && uuid(v.mutationId)
    && evidenceRevision(v.caseRevision) && evidenceRevision(v.catalogRevision, true)
    && typeof v.sourceHash === 'string' && /^[a-f0-9]{64}$/.test(v.sourceHash) && typeof v.requestHash === 'string' && /^[a-f0-9]{64}$/.test(v.requestHash)
    && Buffer.byteLength(JSON.stringify(v)) <= 65536);
  object(v.content, ['photos', 'measurements', 'answers']);
  check(Array.isArray(v.content.photos) && Array.isArray(v.content.measurements) && Array.isArray(v.content.answers));
  for (const row of v.content.photos) check(parseEvidenceDescriptor(row).byteLength <= 8 * 1024 * 1024);
  for (const row of v.content.measurements) {
    object(row, ['id', 'findingId', 'type', 'value', 'unit', 'method', 'confirmed']);
    check(evidenceIdentifier(row.findingId) && evidenceIdentifier(row.type)
      && row.id === sensitiveId('measurement', row.findingId, row.type)
      && typeof row.value === 'number' && Number.isFinite(row.value) && row.unit === 'mm'
      && ['manual', 'estimated'].includes(row.method as string) && typeof row.confirmed === 'boolean');
  }
  for (const row of v.content.answers) {
    object(row, ['id', 'programId', 'key', 'label', 'category', 'questionnaireVersion', 'intakeRevision', 'value', 'reviewState']);
    check(evidenceIdentifier(row.programId) && evidenceIdentifier(row.key)
      && row.id === sensitiveId('answer', row.programId, row.key)
      && typeof row.label === 'string' && row.label.length > 0 && row.label.length <= 300
      && ['financial', 'health', 'private'].includes(row.category as string)
      && typeof row.questionnaireVersion === 'string' && /^[a-f0-9]{64}$/.test(row.questionnaireVersion)
      && evidenceRevision(row.intakeRevision) && ['reported', 'unknown'].includes(row.reviewState as string)
      && (row.value === null) === (row.reviewState === 'unknown')
      && (row.value === null || typeof row.value === 'boolean' || typeof row.value === 'number' && Number.isFinite(row.value)
        || typeof row.value === 'string' && row.value.length <= 600));
  }
  for (const [key, ids] of [['photos', 'photoIds'], ['measurements', 'measurementIds'], ['answers', 'answerIds']] as const) {
    check(Array.isArray(v.content[key]) && v.content[key].length === selection[ids].length);
    const actual = v.content[key].map((row: any) => key === 'photos' ? row.evidenceId : row.id);
    check(new Set(actual).size === actual.length && actual.every((id: string) => selection[ids].includes(id)));
  }
}
