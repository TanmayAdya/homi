import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import type { EvidenceCatalog } from '../evidence/types.ts';
import type { CaseSnapshot, Finding } from '../types.ts';
import { parseCaseDraft } from '../cases/validation.ts';
import { canonicalJson, evidenceIdentifier as id, evidenceRevision as revision, evidenceInstant as instant } from '../evidence/validation.ts';
import { check, exact, appendAssessment, type AssessmentRecord, type AssessmentSave } from './metadata.ts';

export const ROOM_TYPES = ['bathroom', 'entrance', 'stairs', 'livingSpaces', 'bedroom', 'kitchen', 'outdoorPaths'] as const;
export const ANSWERS = ['yes', 'no', 'not_sure', 'not_applicable', 'unanswered'] as const;
export const HOME_SAFETY_MAX_BYTES = 256 * 1024;
export const HOME_SAFETY_MAX_EVENTS = 500;
export interface SafetyQuestion { id: string; section: string; rooms: typeof ROOM_TYPES[number][]; prompt: string; concernWhen: 'yes' | 'no'; guidance: string }
export const STEADI_CATALOG = JSON.parse(readFileSync(new URL('./steadi-catalog.json', import.meta.url), 'utf8')) as {
  version: string; sourceUrl: string; sourceTitle: string; reviewedOn: string; questions: SafetyQuestion[];
};
export interface RoomInstance { id: string; type: typeof ROOM_TYPES[number]; name: string | null; archived?: true }
export interface SafetyAnswer { roomId: string; questionId: string; value: typeof ANSWERS[number]; revision: number }
export interface FindingRoom { findingId: string; roomId: string; questionId: string | null; answerRevision: number | null }
export interface SafetyDocument { catalogVersion: string; rooms: RoomInstance[]; answers: SafetyAnswer[]; findingRooms: FindingRoom[] }
export interface SafetyEvent { mutationId: string; requestHash: string; revision: number; caseRevision: number; recordedAt: string; recordedBy: string; operation: SafetyOperation }
export interface HomeSafetyRecord { schemaVersion: '3'; caseId: string; revision: number; document: SafetyDocument; history: SafetyEvent[] }
export interface HomeSafetyState { schemaVersion: '3'; case: CaseSnapshot; safety: HomeSafetyRecord; acknowledgedMutationId: string | null; evidenceCatalogRevision?: number }
export type SafetyOperation = { type: 'add_room'; room: RoomInstance }
  | { type: 'archive_room'; roomId: string }
  | { type: 'restore_room'; roomId: string }
  | { type: 'delete_room'; roomId: string; expectedModelRevision: number }
  | { type: 'rename_room'; roomId: string; name: string | null }
  | { type: 'answer'; roomId: string; questionId: string; value: SafetyAnswer['value'] }
  | { type: 'assign_finding'; roomId: string; findingId: string }
  | { type: 'annotate_answer'; roomId: string; questionId: string; answerRevision: number; note: string | null; expectedCatalogRevision: number; evidence: { evidenceId: string; expectedEvidenceRevision: number }[] }
  | { type: 'set_addressed'; roomId: string; findingId: string; findingFingerprint: string; answerRevision: number | null; addressed: boolean; evidenceCatalogRevision?: number }
  | { type: 'review_concern'; roomId: string; questionId: string; findingId: string; observation: string; state: Finding['reviewState'] };
export interface HomeSafetyRead { schemaVersion: '3'; caseId: string }
export interface HomeSafetySave extends HomeSafetyRead { expectedCaseRevision: number; expectedSafetyRevision: number; mutationId: string; operation: SafetyOperation }
export type HomeSafetyResult = { status: 'found'; state: HomeSafetyState }
  | { status: 'not_found' | 'conflict' | 'safety_conflict' | 'mutation_conflict' | 'history_limit' | 'evidence_conflict' | 'invalid_operation' };
export interface HomeSafetyRepository {
  readHomeSafetyForUser(userId: string, caseId: string): Promise<HomeSafetyResult>;
  saveHomeSafetyForUser(userId: string, request: HomeSafetySave, at: string): Promise<HomeSafetyResult>;
}
const digest = (value: unknown) => createHash('sha256').update(canonicalJson(value)).digest('hex');
export const safetyRequestHash = digest;
export function validRoomName(value: unknown): value is string | null {
  return value === null || typeof value === 'string' && value.trim() === value && value.length > 0 && Array.from(value).length <= 80
    && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069\ud800-\udfff]/u.test(value);
}
function parseRoom(value: unknown): RoomInstance {
  check(exact(value, ['id', 'type', 'name', ...(Object.hasOwn(value ?? {}, 'archived') ? ['archived'] : [])]) && (!Object.hasOwn(value, 'archived') || value.archived === true) && id(value.id) && ROOM_TYPES.includes(value.type) && validRoomName(value.name));
  return structuredClone(value) as RoomInstance;
}
export function parseSafetyOperation(value: unknown): SafetyOperation {
  check(value !== null && typeof value === 'object');
  const op = value as Record<string, any>;
  if (op.type === 'add_room') { check(exact(op, ['type', 'room'])); const room = parseRoom(op.room); check(!room.archived); return { type: 'add_room', room }; }
  check(id(op.roomId));
  if (op.type === 'archive_room' || op.type === 'restore_room') check(exact(op, ['type', 'roomId']));
  else if (op.type === 'delete_room') check(exact(op, ['type', 'roomId', 'expectedModelRevision']) && revision(op.expectedModelRevision, true));
  else if (op.type === 'rename_room') check(exact(op, ['type', 'roomId', 'name']) && validRoomName(op.name));
  else if (op.type === 'assign_finding') check(exact(op, ['type', 'roomId', 'findingId']) && id(op.findingId));
  else if (op.type === 'annotate_answer') {
    check(exact(op, ['type','roomId','questionId','answerRevision','note','expectedCatalogRevision','evidence'])
      && STEADI_CATALOG.questions.some(q => q.id === op.questionId) && revision(op.answerRevision, true) && revision(op.expectedCatalogRevision, true)
      && (op.note === null || typeof op.note === 'string' && op.note.trim() === op.note && op.note.length > 0 && op.note.length <= 500 && !/[\u0000-\u001f]/.test(op.note))
      && Array.isArray(op.evidence) && op.evidence.length <= 6);
    const seen = new Set<string>();
    for (const ref of op.evidence) { check(exact(ref, ['evidenceId','expectedEvidenceRevision']) && id(ref.evidenceId) && revision(ref.expectedEvidenceRevision) && !seen.has(ref.evidenceId)); seen.add(ref.evidenceId); }
  }
  else if (op.type === 'set_addressed') check(exact(op, ['type', 'roomId', 'findingId', 'findingFingerprint', 'answerRevision', 'addressed', ...(Object.hasOwn(op,'evidenceCatalogRevision') ? ['evidenceCatalogRevision'] : [])])
    && id(op.findingId) && /^[a-f0-9]{64}$/.test(op.findingFingerprint) && typeof op.addressed === 'boolean'
    && (op.answerRevision === null || revision(op.answerRevision)) && (op.evidenceCatalogRevision === undefined || revision(op.evidenceCatalogRevision,true)));
  else if (op.type === 'answer') check(exact(op, ['type', 'roomId', 'questionId', 'value']) && ANSWERS.includes(op.value)
    && STEADI_CATALOG.questions.some(q => q.id === op.questionId));
  else {
    check(op.type === 'review_concern' && exact(op, ['type', 'roomId', 'questionId', 'findingId', 'observation', 'state'])
      && id(op.findingId) && STEADI_CATALOG.questions.some(q => q.id === op.questionId)
      && typeof op.observation === 'string' && op.observation.trim() === op.observation && op.observation.length > 0
      && op.observation.length <= 500 && !/[\u0000-\u001f]/.test(op.observation)
      && ['confirmed', 'needs_review', 'dismissed'].includes(op.state));
  }
  return structuredClone(op) as SafetyOperation;
}
export function parseSafetyDocument(value: unknown): SafetyDocument {
  check(exact(value, ['catalogVersion', 'rooms', 'answers', 'findingRooms']) && value.catalogVersion === STEADI_CATALOG.version
    && Array.isArray(value.rooms) && value.rooms.length <= 32 && Array.isArray(value.answers) && value.answers.length <= 512
    && Array.isArray(value.findingRooms) && value.findingRooms.length <= 100);
  const rooms = new Map<string, RoomInstance>();
  for (const raw of value.rooms) { const room = parseRoom(raw); check(!rooms.has(room.id)); rooms.set(room.id, room); }
  const answers = new Map<string, SafetyAnswer>();
  const key = (roomId: string, questionId: string) => JSON.stringify([roomId, questionId]);
  for (const a of value.answers) {
    check(exact(a, ['roomId', 'questionId', 'value', 'revision']) && rooms.has(a.roomId) && ANSWERS.includes(a.value)
      && revision(a.revision) && STEADI_CATALOG.questions.some(q => q.id === a.questionId && q.rooms.includes(rooms.get(a.roomId)!.type))
      && !answers.has(key(a.roomId, a.questionId)));
    answers.set(key(a.roomId, a.questionId), a as SafetyAnswer);
  }
  const findings = new Set<string>(), questions = new Set<string>();
  for (const link of value.findingRooms) {
    check(exact(link, ['findingId', 'roomId', 'questionId', 'answerRevision']) && id(link.findingId) && !findings.has(link.findingId)
      && rooms.has(link.roomId));
    findings.add(link.findingId);
    if (link.questionId === null) check(link.answerRevision === null);
    else {
      const k = key(link.roomId, link.questionId), answer = answers.get(k);
      check(answer && revision(link.answerRevision) && link.answerRevision <= answer.revision && !questions.has(k)); questions.add(k);
    }
  }
  return structuredClone(value) as SafetyDocument;
}
export function emptyHomeSafety(caseId: string): HomeSafetyRecord {
  check(id(caseId));
  return { schemaVersion: '3', caseId, revision: 0, document: { catalogVersion: STEADI_CATALOG.version, rooms: [], answers: [], findingRooms: [] }, history: [] };
}
export function parseHomeSafetyRecord(value: unknown): HomeSafetyRecord {
  check(exact(value, ['schemaVersion', 'caseId', 'revision', 'document', 'history']) && value.schemaVersion === '3' && id(value.caseId)
    && revision(value.revision, true) && Array.isArray(value.history) && value.history.length === value.revision
    && value.history.length <= HOME_SAFETY_MAX_EVENTS && Buffer.byteLength(JSON.stringify(value)) <= HOME_SAFETY_MAX_BYTES);
  parseSafetyDocument(value.document);
  const ids = new Set<string>();
  for (const [index, e] of value.history.entries()) {
    check(exact(e, ['mutationId', 'requestHash', 'revision', 'caseRevision', 'recordedAt', 'recordedBy', 'operation']) && id(e.mutationId)
      && !ids.has(e.mutationId) && /^[a-f0-9]{64}$/.test(e.requestHash) && e.revision === index + 1 && revision(e.caseRevision) && (index === 0 || e.caseRevision >= value.history[index - 1].caseRevision) && instant(e.recordedAt) && id(e.recordedBy));
    parseSafetyOperation(e.operation); ids.add(e.mutationId);
  }
  if (value.revision === 0) check(canonicalJson(value.document) === canonicalJson(emptyHomeSafety(value.caseId).document));
  return structuredClone(value) as HomeSafetyRecord;
}
export function homeSafetyState(snapshot: CaseSnapshot, record: HomeSafetyRecord | null, ack: string | null = null, evidenceCatalogRevision?: number): HomeSafetyState {
  return structuredClone({ schemaVersion: '3', case: snapshot, safety: record ?? emptyHomeSafety(snapshot.caseId), acknowledgedMutationId: ack, ...(evidenceCatalogRevision === undefined ? {} : {evidenceCatalogRevision}) });
}
export function parseHomeSafetyState(value: unknown): HomeSafetyState {
  check(exact(value, ['schemaVersion', 'case', 'safety', 'acknowledgedMutationId', ...(Object.hasOwn(value ?? {},'evidenceCatalogRevision') ? ['evidenceCatalogRevision'] : [])]) && value.schemaVersion === '3'
    && exact(value.case, ['schemaVersion', 'caseId', 'revision', 'profile', 'unresolvedFields', 'findings']) && revision(value.case.revision));
  const { revision: caseRevision, ...draft } = value.case;
  const snapshot = { ...parseCaseDraft(draft, false, 1), revision: caseRevision };
  const record = parseHomeSafetyRecord(value.safety);
  check(record.caseId === snapshot.caseId && record.history.every(e => e.caseRevision <= snapshot.revision)
    && (value.acknowledgedMutationId === null || record.history.some(e => e.mutationId === value.acknowledgedMutationId)));
  check(value.evidenceCatalogRevision === undefined || revision(value.evidenceCatalogRevision,true));
  return homeSafetyState(snapshot, record, value.acknowledgedMutationId, value.evidenceCatalogRevision);
}
export function parseHomeSafetyRequest(value: unknown, save: boolean): HomeSafetyRead | HomeSafetySave {
  check(exact(value, ['schemaVersion', 'caseId', ...(save ? ['expectedCaseRevision', 'expectedSafetyRevision', 'mutationId', 'operation'] : [])])
    && value.schemaVersion === '3' && id(value.caseId));
  if (!save) return { schemaVersion: '3', caseId: value.caseId };
  check(revision(value.expectedCaseRevision) && revision(value.expectedSafetyRevision, true) && id(value.mutationId));
  return { ...structuredClone(value), operation: parseSafetyOperation(value.operation) } as HomeSafetySave;
}

export function assessmentForSafetyReview(input: { before: CaseSnapshot; next: CaseSnapshot; prior: AssessmentRecord | null;
  request: HomeSafetySave; userId: string; at: string; catalogRevision: number }): { record: AssessmentRecord | null; limit: boolean } {
  const { before, next, prior, request, userId, at, catalogRevision } = input;
  if (prior === null || prior.caseRevision !== before.revision) return { record: null, limit: false };
  check(prior.caseId === before.caseId && next.revision === before.revision + 1);
  const { revision: _, ...draft } = next;
  const update: AssessmentSave = { schemaVersion: '2', caseId: before.caseId, expectedCaseRevision: before.revision,
    expectedCaseFingerprint: digest(before), expectedCatalogRevision: catalogRevision, expectedAssessmentRevision: prior.assessmentRevision,
    mutationId: `home-safety-${digest(request)}`, draft,
    metadata: { measurements: structuredClone(prior.metadata.measurements), reviews: next.findings.map(f => ({ findingId: f.id,
      state: f.reviewState, note: prior.metadata.reviews.find(r => r.findingId === f.id)?.note ?? null })) } };
  const record = appendAssessment(prior, before, update, userId, at);
  return { record, limit: record === null };
}

export function changeHomeSafety(snapshot: CaseSnapshot, prior: HomeSafetyRecord, input: HomeSafetySave, userId: string, at: string, evidence?: EvidenceCatalog):
  { status: 'changed'; record: HomeSafetyRecord; snapshot: CaseSnapshot; changesCase: boolean } | Exclude<HomeSafetyResult, { status: 'found' }> | { status: 'retry' } {
  check(snapshot.caseId === prior.caseId && input.caseId === prior.caseId && id(userId) && instant(at));
  const retry = prior.history.find(e => e.mutationId === input.mutationId);
  if (retry) return { status: retry.requestHash === digest(input) ? 'retry' : 'mutation_conflict' };
  if (input.expectedSafetyRevision !== prior.revision) return { status: 'safety_conflict' };
  if (input.expectedCaseRevision !== snapshot.revision) return { status: 'conflict' };
  if (prior.history.length >= HOME_SAFETY_MAX_EVENTS) return { status: 'history_limit' };
  const doc = structuredClone(prior.document), op = input.operation;
  let nextSnapshot = structuredClone(snapshot), changesCase = false;
  if (op.type === 'add_room') {
    if (doc.rooms.length >= 32 || doc.rooms.some(r => r.id === op.room.id) || prior.history.some(e => e.operation.type === 'add_room' && e.operation.room.id === op.room.id)) return { status: 'invalid_operation' };
    doc.rooms.push(op.room);
  } else {
    const room = doc.rooms.find(r => r.id === op.roomId); if (!room) return { status: 'invalid_operation' };
    if (op.type === 'archive_room') {
      if (room.archived) return { status: 'invalid_operation' };
      room.archived = true;
    } else if (op.type === 'restore_room') {
      if (!room.archived) return { status: 'invalid_operation' };
      delete room.archived;
    } else if (op.type === 'delete_room') {
      if (!room.archived) return { status: 'invalid_operation' };
      doc.rooms = doc.rooms.filter(r => r.id !== room.id);
      doc.answers = doc.answers.filter(a => a.roomId !== room.id);
      doc.findingRooms = doc.findingRooms.filter(l => l.roomId !== room.id);
    } else if (room.archived) return { status: 'invalid_operation' };
    else if (op.type === 'rename_room') room.name = op.name;
    else if (op.type === 'set_addressed') {
      const link = doc.findingRooms.find(l => l.roomId === room.id && l.findingId === op.findingId);
      const finding = snapshot.findings.find(f => f.id === op.findingId);
      const answerRevision = link?.questionId ? doc.answers.find(a => a.roomId === room.id && a.questionId === link.questionId)?.revision : null;
      if (!link || !finding || digest(finding) !== op.findingFingerprint || answerRevision !== op.answerRevision
        || op.addressed && (finding.reviewState !== 'confirmed' || link.answerRevision !== answerRevision || finding.evidenceIds.length > 0 && op.evidenceCatalogRevision !== evidence?.catalogRevision)) return { status: 'invalid_operation' };
    }
    else if (op.type === 'assign_finding') {
      if (!snapshot.findings.some(f => f.id === op.findingId)) return { status: 'invalid_operation' };
      const old = doc.findingRooms.find(l => l.findingId === op.findingId);
      if (old?.questionId !== null && old !== undefined) return { status: 'invalid_operation' };
      doc.findingRooms = doc.findingRooms.filter(l => l.findingId !== op.findingId);
      doc.findingRooms.push({ findingId: op.findingId, roomId: op.roomId, questionId: null, answerRevision: null });
    } else {
      const q = STEADI_CATALOG.questions.find(q => q.id === op.questionId && q.rooms.includes(room.type));
      if (!q) return { status: 'invalid_operation' };
      const answer = doc.answers.find(a => a.roomId === room.id && a.questionId === q.id);
      if (op.type === 'annotate_answer') {
        if (op.answerRevision !== (answer?.revision ?? 0)) return { status: 'invalid_operation' };
        if (op.evidence.length > 0 && (!evidence || evidence.caseId !== snapshot.caseId || evidence.caseRevision !== snapshot.revision || evidence.catalogRevision !== op.expectedCatalogRevision
          || op.evidence.some(ref => !evidence.evidence.some(e => e.evidenceId === ref.evidenceId && e.evidenceRevision === ref.expectedEvidenceRevision)))) return { status: 'evidence_conflict' };
      } else if (op.type === 'answer') {
        if (answer) { answer.value = op.value; answer.revision++; }
        else doc.answers.push({ roomId: room.id, questionId: q.id, value: op.value, revision: 1 });
      } else {
        const link = doc.findingRooms.find(l => l.roomId === room.id && l.questionId === q.id);
        const existing = snapshot.findings.find(f => f.id === op.findingId);
        if (!answer || (!link && answer.value !== q.concernWhen) || (link && link.findingId !== op.findingId)
          || (!link && existing) || (link && !existing)) return { status: 'invalid_operation' };
        const finding: Finding = existing ? { ...existing, observation: op.observation, reviewState: op.state }
          : { id: op.findingId, room: room.type === 'bathroom' || room.type === 'entrance' ? room.type : 'other',
            observation: op.observation, reviewState: op.state, evidenceIds: [], measurements: [] };
        const findings = existing ? snapshot.findings.map(f => f.id === finding.id ? finding : f) : [...snapshot.findings, finding];
        const { revision: _, ...draft } = { ...snapshot, findings };
        try { nextSnapshot = { ...parseCaseDraft(draft, false, snapshot.revision + 1), revision: snapshot.revision + 1 }; }
        catch { return { status: 'invalid_operation' }; }
        changesCase = true;
        if (link) link.answerRevision = answer.revision;
        else doc.findingRooms.push({ findingId: finding.id, roomId: room.id, questionId: q.id, answerRevision: answer.revision });
      }
    }
  }
  const record: HomeSafetyRecord = { schemaVersion: '3', caseId: snapshot.caseId, revision: prior.revision + 1, document: doc,
    history: [...prior.history, { mutationId: input.mutationId, requestHash: digest(input), revision: prior.revision + 1,
      caseRevision: nextSnapshot.revision, recordedAt: at, recordedBy: userId, operation: op }] };
  if (Buffer.byteLength(JSON.stringify(record)) > HOME_SAFETY_MAX_BYTES) return { status: 'history_limit' };
  return { status: 'changed', record: parseHomeSafetyRecord(record), snapshot: nextSnapshot, changesCase };
}
