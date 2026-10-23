import { evidenceIdentifier, evidenceRevision, canonicalJson } from '../evidence/validation.ts';
import { isNewCaseId } from '../cases/validation.ts';

export const MAX_REQUEST_EVENTS = 50;
export const MAX_REQUEST_PROGRAMS = 4;
export const REQUEST_STATUSES = ['preparing', 'submitted', 'received', 'needs_information', 'approved', 'denied', 'withdrawn'] as const;
export const REQUEST_SOURCES = ['self_report', 'program_contact', 'document'] as const;
export const REQUEST_PARTIES = ['resident', 'caregiver', 'program', 'clinician', 'contractor', 'other'] as const;
export interface RequestUpdate {
  updateId: string;
  status: typeof REQUEST_STATUSES[number];
  occurredOn: string;
  source: typeof REQUEST_SOURCES[number];
  note: string | null;
  nextAction: string | null;
  responsibleParty: typeof REQUEST_PARTIES[number] | null;
  followUpOn: string | null;
}
export interface RequestEvent extends RequestUpdate { revision: number; caseRevision: number; recordedAt: string }
export interface RequestHistory {
  schemaVersion: '1'; caseId: string; caseRevision: number; programId: string;
  requestRevision: number; provenance: 'user_reported'; events: RequestEvent[];
}
export interface RequestHistoryReadInput { userId: string; caseId: string; revision: number; programId: string }
export interface RequestHistoryAppendInput extends RequestHistoryReadInput {
  expectedRequestRevision: number; update: RequestUpdate; recordedAt: string;
}
export type RequestHistoryResult = { status: 'found'; history: RequestHistory }
  | { status: 'not_found' | 'conflict' | 'request_conflict' | 'update_conflict' | 'quota_exceeded' };
export interface RequestHistoryRepository {
  readRequestHistoryForUser(input: RequestHistoryReadInput): Promise<RequestHistoryResult>;
  appendRequestUpdateForUser(input: RequestHistoryAppendInput): Promise<RequestHistoryResult>;
}
export interface ReadRequestHistoryRequest {
  schemaVersion: '1'; caseId: string; expectedCaseRevision: number; programId: string;
}
export interface AppendRequestUpdateRequest extends ReadRequestHistoryRequest {
  expectedRequestRevision: number; update: RequestUpdate;
}
const updateKeys = ['updateId', 'status', 'occurredOn', 'source', 'note', 'nextAction', 'responsibleParty', 'followUpOn'];
function check(value: unknown): asserts value { if (!value) throw new Error('Invalid request history data.'); }
function object(value: unknown, keys: string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
export function requestDate(value: unknown): value is string {
  if (typeof value !== 'string' || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value) || value.startsWith('0000')) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}
export function requestInstant(value: unknown): value is string {
  if (typeof value !== 'string' || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$/.test(value)
    || value.startsWith('0000')) return false;
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString() === value;
}
function text(value: unknown, max: number): boolean {
  return value === null || (typeof value === 'string' && value.length > 0 && value.trim() === value
    && Array.from(value).length <= max && !/[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u2028\u2029\uD800-\uDFFF]/u.test(value));
}
export function parseRequestUpdate(value: unknown): RequestUpdate {
  check(object(value, updateKeys));
  check(isNewCaseId(value.updateId) && REQUEST_STATUSES.includes(value.status as RequestUpdate['status'])
    && requestDate(value.occurredOn) && REQUEST_SOURCES.includes(value.source as RequestUpdate['source'])
    && text(value.note, 500) && text(value.nextAction, 250)
    && (value.responsibleParty === null || REQUEST_PARTIES.includes(value.responsibleParty as NonNullable<RequestUpdate['responsibleParty']>))
    && (value.followUpOn === null || requestDate(value.followUpOn))
    && ((value.nextAction === null) === (value.responsibleParty === null))
    && (value.followUpOn === null || value.nextAction !== null));
  return structuredClone(value) as unknown as RequestUpdate;
}
export function parseRequestTrackingRequest(value: unknown, append: boolean): ReadRequestHistoryRequest | AppendRequestUpdateRequest {
  check(object(value, ['schemaVersion', 'caseId', 'expectedCaseRevision', 'programId', ...(append ? ['expectedRequestRevision', 'update'] : [])]));
  check(value.schemaVersion === '1' && evidenceIdentifier(value.caseId) && evidenceIdentifier(value.programId)
    && evidenceRevision(value.expectedCaseRevision));
  const common: ReadRequestHistoryRequest = { schemaVersion: '1', caseId: value.caseId,
    expectedCaseRevision: value.expectedCaseRevision, programId: value.programId };
  if (!append) return common;
  check(evidenceRevision(value.expectedRequestRevision, true) && value.expectedRequestRevision <= MAX_REQUEST_EVENTS);
  return { ...common, expectedRequestRevision: value.expectedRequestRevision, update: parseRequestUpdate(value.update) };
}
export function parseRequestHistoryInput(value: RequestHistoryReadInput): RequestHistoryReadInput {
  check(object(value, ['userId', 'caseId', 'revision', 'programId']) && evidenceIdentifier(value.userId)
    && evidenceIdentifier(value.caseId) && evidenceIdentifier(value.programId) && evidenceRevision(value.revision));
  return { ...value };
}
export function parseRequestAppendInput(value: RequestHistoryAppendInput): RequestHistoryAppendInput {
  check(object(value, ['userId', 'caseId', 'revision', 'programId', 'expectedRequestRevision', 'update', 'recordedAt']));
  const common = parseRequestHistoryInput({ userId: value.userId, caseId: value.caseId, revision: value.revision, programId: value.programId });
  const update = parseRequestUpdate(value.update);
  check(evidenceRevision(value.expectedRequestRevision, true) && value.expectedRequestRevision <= MAX_REQUEST_EVENTS
    && requestInstant(value.recordedAt) && update.occurredOn <= value.recordedAt.slice(0, 10));
  return { ...common, expectedRequestRevision: value.expectedRequestRevision, update, recordedAt: value.recordedAt };
}
export function emptyRequestHistory(input: RequestHistoryReadInput): RequestHistory {
  const parsed = parseRequestHistoryInput({ userId: input.userId, caseId: input.caseId, revision: input.revision, programId: input.programId });
  return { schemaVersion: '1', caseId: parsed.caseId, caseRevision: parsed.revision, programId: parsed.programId,
    requestRevision: 0, provenance: 'user_reported', events: [] };
}
export function parseRequestHistory(value: unknown): RequestHistory {
  check(object(value, ['schemaVersion', 'caseId', 'caseRevision', 'programId', 'requestRevision', 'provenance', 'events']));
  check(value.schemaVersion === '1' && value.provenance === 'user_reported'
    && evidenceIdentifier(value.caseId) && evidenceIdentifier(value.programId) && evidenceRevision(value.caseRevision)
    && Array.isArray(value.events) && value.events.length <= MAX_REQUEST_EVENTS && value.requestRevision === value.events.length);
  const ids = new Set<string>();
  let previousCaseRevision = 0;
  let previousTime = '';
  const events = Array.from(value.events, (event, index): RequestEvent => {
    check(object(event, [...updateKeys, 'revision', 'caseRevision', 'recordedAt']));
    const update = parseRequestUpdate(Object.fromEntries(updateKeys.map(key => [key, event[key]])));
    check(event.revision === index + 1 && evidenceRevision(event.caseRevision) && event.caseRevision <= Number(value.caseRevision)
      && event.caseRevision >= previousCaseRevision && requestInstant(event.recordedAt) && event.recordedAt >= previousTime
      && update.occurredOn <= event.recordedAt.slice(0, 10) && !ids.has(update.updateId));
    ids.add(update.updateId); previousCaseRevision = event.caseRevision; previousTime = event.recordedAt;
    return { ...update, revision: event.revision, caseRevision: event.caseRevision, recordedAt: event.recordedAt };
  });
  return { schemaVersion: '1', caseId: value.caseId, caseRevision: value.caseRevision, programId: value.programId,
    requestRevision: events.length, provenance: 'user_reported', events };
}
export function sameRequestUpdate(event: RequestUpdate, update: RequestUpdate): boolean {
  return canonicalJson(Object.fromEntries(updateKeys.map(key => [key, event[key as keyof RequestUpdate]]))) === canonicalJson(parseRequestUpdate(update));
}
export function appendRequestHistory(history: RequestHistory, raw: RequestHistoryAppendInput): RequestHistoryResult {
  const input = parseRequestAppendInput(raw);
  const current = parseRequestHistory(history);
  check(current.caseId === input.caseId && current.programId === input.programId && current.caseRevision === input.revision);
  const existing = current.events.find(event => event.updateId === input.update.updateId);
  if (existing) return existing.revision === input.expectedRequestRevision + 1 && existing.caseRevision === input.revision
    && sameRequestUpdate(existing, input.update) ? { status: 'found', history: current } : { status: 'update_conflict' };
  if (current.requestRevision !== input.expectedRequestRevision) return { status: 'request_conflict' };
  if (current.events.length >= MAX_REQUEST_EVENTS) return { status: 'quota_exceeded' };
  const recordedAt = current.events.at(-1)?.recordedAt;
  const timestamp = recordedAt && recordedAt > input.recordedAt ? recordedAt : input.recordedAt;
  return { status: 'found', history: parseRequestHistory({ ...current, requestRevision: current.requestRevision + 1,
    events: [...current.events, { ...input.update, revision: current.requestRevision + 1, caseRevision: input.revision, recordedAt: timestamp }] }) };
}
