import { check, object, uuid, instant } from './validation.ts';
import { invitationEmail } from '../auth/invitation-email.ts';
import { SENSITIVE_ROUTES, parseSensitiveRequest, type SensitiveRoute, type SensitiveRequest } from './sensitive.ts';
export { check, object, uuid, instant } from './validation.ts';
import { COLLABORATION_ROUTES, parseCollaborationRequest, type CollaborationRequest, type CollaborationRoute } from './collaboration.ts';
import { evidenceIdentifier, evidenceRevision } from '../evidence/validation.ts';
import type { CaseSnapshot } from '../types.ts';
import { validPlanName } from '../cases/plan-name.ts';


export const SHARING_ROUTES = ['preview-sharing', 'create-invitation', 'create-email-invitation', 'list-email-sharing', 'list-sharing', 'change-sharing', 'revoke-sharing',
  'review-invitation', 'accept-invitation', 'list-shared-cases', 'read-shared-case', 'add-shared-note', ...COLLABORATION_ROUTES, ...SENSITIVE_ROUTES] as const;
export type SharingRoute = typeof SHARING_ROUTES[number];
export interface ShareScope { findingIds: string[]; programIds: string[]; allowHelperNotes: boolean }
export interface SharedCaseProjection {
  schemaVersion: '3'; caseId: string; sourceRevision: number; publishedAt: string; stale: boolean;
  summary: 'Selected home safety information';
  findings: { id: string; room: string; observation: string; reviewState: string }[];
  programs: { programId: string; status: string | null; occurredOn: string | null; provenance: 'user_reported' }[];
}
export interface SharedNote { mutationId: string; authorId: string; note: string; recordedAt: string }
export interface AccessAuditEvent { type: 'invited' | 'accepted' | 'changed' | 'revoked' | 'read' | 'note'; actorId: string; at: string }
export interface CaseMembership {
  membershipId: string; caseId: string; grantorId: string; recipientId: string; role: 'viewer' | 'helper'; scope: ShareScope;
  permissionRevision: number; expiresAt: string | null; invitationExpiresAt: string;
  state: 'pending' | 'active' | 'revoked' | 'expired';
  recipientLabel?: string;
  ownerLabel?: string;
}
export interface OwnerShare extends CaseMembership { projection: SharedCaseProjection | null; notes: SharedNote[]; audit: AccessAuditEvent[] }
export interface SharedView { membership: CaseMembership; projection: SharedCaseProjection; notes: SharedNote[] }
export type SharingRequest = CollaborationRequest & { schemaVersion: '3'; caseId?: string; expectedCaseRevision?: number; invitationId?: string;
  recipientId?: string; recipientEmail?: string; role?: 'viewer' | 'helper'; scope?: ShareScope; expiresAt?: string | null;
  expectedPermissionRevision?: number; code?: string; membershipId?: string; mutationId?: string; note?: string;
  recipientLabel?: string; ownerLabel?: string; includeLabels?: true };
export interface SharingRepository {
  execute(userId: string, route: SharingRoute, request: SharingRequest, tokenHash?: string, verifiedEmail?: string): Promise<SharingResult>;
  sensitive?(userId: string, route: SensitiveRoute, request: SensitiveRequest): Promise<SharingResult>;
}
export type SharingResult = { status: 'ok'; data: Record<string, unknown> } | { status: 'not_found' | 'conflict' | 'quota_exceeded' | 'invalid_request' };
export function parseScope(value: unknown): ShareScope {
  object(value, ['findingIds', 'programIds', 'allowHelperNotes']);
  for (const [key, max] of [['findingIds', 32], ['programIds', 4]] as const) {
    const ids = value[key]; check(Array.isArray(ids) && ids.length <= max && ids.every(evidenceIdentifier) && new Set(ids).size === ids.length);
  }
  check(typeof value.allowHelperNotes === 'boolean');
  return structuredClone(value) as unknown as ShareScope;
}
const keys: Record<Exclude<SharingRoute,CollaborationRoute | SensitiveRoute>, string[]> = {
  'preview-sharing': ['caseId', 'expectedCaseRevision', 'scope'],
  'create-invitation': ['caseId', 'expectedCaseRevision', 'invitationId', 'recipientId', 'role', 'scope', 'expiresAt'],
  'create-email-invitation': ['caseId', 'expectedCaseRevision', 'invitationId', 'recipientEmail', 'role', 'scope', 'expiresAt'],
  'list-email-sharing': ['caseId'],
  'list-sharing': ['caseId'], 'change-sharing': ['caseId', 'expectedCaseRevision', 'invitationId', 'expectedPermissionRevision', 'role', 'scope', 'expiresAt'],
  'revoke-sharing': ['caseId', 'invitationId', 'expectedPermissionRevision'],
  'review-invitation': ['code'], 'accept-invitation': ['code', 'expectedPermissionRevision'], 'list-shared-cases': [],
  'read-shared-case': ['membershipId', 'expectedPermissionRevision'],
  'add-shared-note': ['membershipId', 'expectedPermissionRevision', 'mutationId', 'note'],
};
const optionalKeys: Partial<Record<SharingRoute, string[]>> = {
  'create-invitation': ['recipientLabel', 'ownerLabel'], 'create-email-invitation': ['recipientLabel', 'ownerLabel'],
  'list-sharing': ['includeLabels'], 'list-email-sharing': ['includeLabels'], 'list-shared-cases': ['includeLabels'], 'review-invitation': ['includeLabels'],
};
export function parseSharingRequest(route: SharingRoute, value: unknown): SharingRequest {
  if ((SENSITIVE_ROUTES as readonly string[]).includes(route)) return parseSensitiveRequest(route as SensitiveRoute, value);
  if((COLLABORATION_ROUTES as readonly string[]).includes(route)) return parseCollaborationRequest(route as CollaborationRoute,value);
  check(value !== null && typeof value === 'object');
  const optional = (optionalKeys[route] ?? []).filter(key => Object.hasOwn(value, key));
  object(value, ['schemaVersion', ...keys[route as Exclude<SharingRoute,CollaborationRoute | SensitiveRoute>], ...optional]); check(value.schemaVersion === '3');
  for (const key of ['recipientLabel', 'ownerLabel']) if (key in value) check(typeof value[key] === 'string' && validPlanName(value[key]));
  if ('includeLabels' in value) check(value.includeLabels === true);
  if ('caseId' in value) check(evidenceIdentifier(value.caseId));
  for (const key of ['invitationId', 'recipientId', 'membershipId', 'mutationId']) if (key in value) check(uuid(value[key]));
  for (const key of ['expectedCaseRevision', 'expectedPermissionRevision']) if (key in value) check(evidenceRevision(value[key]));
  if ('scope' in value) { const scope = parseScope(value.scope); if ('role' in value) check(value.role === 'viewer' || value.role === 'helper'); check(value.role !== 'viewer' || !scope.allowHelperNotes); }
  if ('recipientEmail' in value) check(invitationEmail(value.recipientEmail));
  if ('expiresAt' in value) check(value.expiresAt === null || instant(value.expiresAt));
  if ('code' in value) check(typeof value.code === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value.code));
  if ('note' in value) check(typeof value.note === 'string' && value.note.trim() === value.note && value.note.length > 0 && value.note.length <= 500 && !/[\u0000-\u001f\u007f-\u009f]/.test(value.note));
  const parsed=structuredClone(value) as unknown as SharingRequest;
  if ('recipientEmail' in value) parsed.recipientEmail=invitationEmail(value.recipientEmail)!;
  return parsed;
}
export function projectCase(snapshot: CaseSnapshot, scope: ShareScope, histories: { programId: string; events: { status: string; occurredOn: string }[] }[], at: string): SharedCaseProjection {
  parseScope(scope); check(scope.findingIds.every(id => snapshot.findings.some(f => f.id === id)));
  return { schemaVersion: '3', caseId: snapshot.caseId, sourceRevision: snapshot.revision, publishedAt: at, stale: false,
    summary: 'Selected home safety information', findings: scope.findingIds.map(id => {
      const f = snapshot.findings.find(f => f.id === id)!; return { id: f.id, room: f.room, observation: f.observation, reviewState: f.reviewState };
    }), programs: scope.programIds.map(programId => { const event = histories.find(h => h.programId === programId)?.events.at(-1);
      return { programId, status: event?.status ?? null, occurredOn: event?.occurredOn ?? null, provenance: 'user_reported' }; }) };
}

export function parseSharedProjection(value: unknown): SharedCaseProjection {
  object(value, ['schemaVersion','caseId','sourceRevision','publishedAt','stale','summary','findings','programs']);
  check(value.schemaVersion === '3' && evidenceIdentifier(value.caseId) && evidenceRevision(value.sourceRevision)
    && instant(value.publishedAt) && typeof value.stale === 'boolean' && value.summary === 'Selected home safety information');
  check(Array.isArray(value.findings) && value.findings.length <= 32 && Array.isArray(value.programs) && value.programs.length <= 4);
  for (const finding of value.findings) {
    object(finding, ['id','room','observation','reviewState']);
    check(evidenceIdentifier(finding.id) && ['bathroom','entrance','other'].includes(String(finding.room))
      && typeof finding.observation === 'string' && finding.observation.length > 0 && finding.observation.length <= 2000
      && ['confirmed','needs_review','dismissed'].includes(String(finding.reviewState)));
  }
  for (const program of value.programs) {
    object(program, ['programId','status','occurredOn','provenance']);
    check(evidenceIdentifier(program.programId) && program.provenance === 'user_reported'
      && ((program.status === null && program.occurredOn === null) ||
        (['preparing','submitted','received','needs_information','approved','denied','withdrawn'].includes(String(program.status))
          && typeof program.occurredOn === 'string' && /^\d{4}-\d\d-\d\d$/.test(program.occurredOn)
          && Number.isFinite(Date.parse(program.occurredOn)) && new Date(program.occurredOn).toISOString().slice(0,10) === program.occurredOn)));
  }
  for (const [rows, key] of [[value.findings,'id'],[value.programs,'programId']] as const) check(new Set(rows.map(v=>v[key])).size === rows.length);
  return structuredClone(value) as unknown as SharedCaseProjection;
}
