import { matchPrograms } from '../matcher.ts';
import { createHash } from 'node:crypto';
import type { CaseSnapshot, ProgramDefinition } from '../types.ts';
import { canonicalJson, evidenceIdentifier as id, evidenceRevision as rev } from '../evidence/validation.ts';
import { parseRequestUpdate, requestDate, requestInstant, type RequestHistory, type RequestUpdate } from '../requests/tracking.ts';

export const PROGRESS_MAX_BYTES = 240 * 1024;
export const TASK_STATES = ['pending', 'in_progress', 'blocked', 'completed', 'cancelled'] as const;
export const TASK_KINDS = ['profile', 'room_review', 'documents', 'contact', 'draft_review', 'follow_up', 'other'] as const;
export interface TrackedProgram { programId: string; name: string; trackedAt: string; trackedBy: string }
export interface ReferralImport {
  sourceTaskId: string; sourceHash: string; contactNote: string;
  original: { id: string; providerId: string; title: string; responsible: string;
    dueDate: string | null; findingId: string | null; createdAt: string; completedAt: string | null };
}
export interface ReferralTaskLink { providerId: string; imported?: ReferralImport }
export interface NextStepTask {
  id: string; programId: string | null; findingId: string | null; formId: string | null;
  title: string; kind: typeof TASK_KINDS[number]; state: typeof TASK_STATES[number];
  responsiblePerson: string | null; dueOn: string | null; basedOnCaseRevision: number; basedOnRuleVersion: string | null; revision: number;
  sourceEventId: string | null; referral?: ReferralTaskLink;
}
export type ProgressOperation = { type: 'track_program'; programId: string }
  | { type: 'put_task'; task: NextStepTask; expectedTaskRevision: number }
  | { type: 'dismiss_proposal'; eventId: string }
  | { type: 'report_status'; programId: string; update: RequestUpdate };
export interface TaskEvent { mutationId: string; requestHash: string; revision: number; recordedAt: string; recordedBy: string; caseRevision: number; operation: ProgressOperation }
export interface ProgressRecord { schemaVersion: '3'; caseId: string; revision: number; programs: TrackedProgram[]; tasks: NextStepTask[]; dismissedProposals: string[]; events: TaskEvent[] }
export interface ProgressRead { includeReferrals?: true; schemaVersion: '3'; caseId: string; offset: number; limit: number; expectedProgressRevision: number | null; expectedCaseRevision: number | null; expectedHistoryVersion: string | null }
export interface ProgressSave { includeReferrals?: true; schemaVersion: '3'; caseId: string; expectedCaseRevision: number; expectedProgressRevision: number; mutationId: string; operation: ProgressOperation }
export interface ProgressContext { snapshot: CaseSnapshot; record: ProgressRecord; legacy: RequestHistory[] }
export type ProgressResult = { status: 'found'; context: ProgressContext; acknowledgedMutationId?: string }
  | { status: 'not_found' | 'conflict' | 'progress_conflict' | 'task_conflict' | 'mutation_conflict' | 'limit' | 'invalid_operation' };
export interface ProgressRepository {
  readProgressForUser(userId: string, caseId: string): Promise<ProgressResult>;
  saveProgressForUser(userId: string, input: ProgressSave, at: string, registry: ProgramDefinition[]): Promise<ProgressResult>;
}
function check(v: unknown): asserts v { if (!v) throw Error('Invalid progress record.'); }
function exact(v: any, keys: string[]): v is Record<string, any> {
  return v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === keys.length && keys.every(k => Object.hasOwn(v, k));
}
function text(v: unknown, max: number): v is string { return typeof v === 'string' && id(v) && Array.from(v).length <= max; }
const taskKeys = ['id', 'programId', 'findingId', 'formId', 'title', 'kind', 'state', 'responsiblePerson', 'dueOn', 'basedOnCaseRevision', 'basedOnRuleVersion', 'revision', 'sourceEventId'];
export function parseReferralLink(v: unknown): ReferralTaskLink {
  check(exact(v, ['providerId', ...(Object.hasOwn(v ?? {}, 'imported') ? ['imported'] : [])]) && id(v.providerId));
  if (v.imported !== undefined) {
    const m = v.imported;
    check(exact(m, ['sourceTaskId', 'sourceHash', 'contactNote', 'original']) && id(m.sourceTaskId)
      && typeof m.sourceHash === 'string' && /^[a-f0-9]{64}$/.test(m.sourceHash)
      && typeof m.contactNote === 'string' && (m.contactNote === '' || text(m.contactNote, 500)));
    const o = m.original;
    check(exact(o, ['id', 'providerId', 'title', 'responsible', 'dueDate', 'findingId', 'createdAt', 'completedAt'])
      && o.id === m.sourceTaskId && o.providerId === v.providerId && text(o.title, 160)
      && typeof o.responsible === 'string' && (o.responsible === '' || text(o.responsible, 100))
      && (o.dueDate === null || requestDate(o.dueDate)) && (o.findingId === null || id(o.findingId))
      && requestInstant(o.createdAt) && (o.completedAt === null || requestInstant(o.completedAt))
      && createHash('sha256').update(canonicalJson(o)).digest('hex') === m.sourceHash);
  }
  return structuredClone(v) as ReferralTaskLink;
}
export function parseTask(v: unknown): NextStepTask {
  check(exact(v, [...taskKeys, ...(Object.hasOwn(v ?? {}, 'referral') ? ['referral'] : [])]) && id(v.id) && text(v.title, 200) && TASK_KINDS.includes(v.kind) && TASK_STATES.includes(v.state)
    && ['programId', 'findingId', 'formId', 'sourceEventId', 'basedOnRuleVersion'].every(k => v[k] === null || id(v[k]))
    && (v.responsiblePerson === null || text(v.responsiblePerson, 100)) && (v.dueOn === null || requestDate(v.dueOn))
    && rev(v.basedOnCaseRevision) && rev(v.revision));
  if (Object.hasOwn(v as object, 'referral')) parseReferralLink((v as any).referral);
  return structuredClone(v) as NextStepTask;
}
export function parseProgressOperation(v: unknown): ProgressOperation {
  if (exact(v, ['type', 'programId']) && v.type === 'track_program') check(id(v.programId));
  else if (exact(v, ['type', 'task', 'expectedTaskRevision']) && v.type === 'put_task') { parseTask(v.task); check(rev(v.expectedTaskRevision, true)); }
  else if (exact(v, ['type', 'eventId']) && v.type === 'dismiss_proposal') check(id(v.eventId));
  else if (exact(v, ['type', 'programId', 'update']) && v.type === 'report_status') { check(id(v.programId)); parseRequestUpdate(v.update); }
  else throw Error('Invalid progress operation.');
  return structuredClone(v) as ProgressOperation;
}
export function parseProgressRequest(v: unknown, save: boolean): ProgressRead | ProgressSave {
  check(exact(v, ['schemaVersion', 'caseId', ...(Object.hasOwn(v ?? {}, 'includeReferrals') ? ['includeReferrals'] : []), ...(save ? ['expectedCaseRevision', 'expectedProgressRevision', 'mutationId', 'operation'] : ['offset', 'limit', 'expectedProgressRevision', 'expectedCaseRevision', 'expectedHistoryVersion'])]) && v.schemaVersion === '3' && id(v.caseId) && (!Object.hasOwn(v, 'includeReferrals') || v.includeReferrals === true));
  if (save) { check(rev(v.expectedCaseRevision) && rev(v.expectedProgressRevision, true) && id(v.mutationId)); parseProgressOperation(v.operation); }
  else check(Number.isInteger(v.offset) && v.offset >= 0 && v.offset <= 1000 && Number.isInteger(v.limit) && v.limit >= 1 && v.limit <= 20
    && (v.expectedProgressRevision === null || rev(v.expectedProgressRevision, true)) && (v.expectedCaseRevision === null || rev(v.expectedCaseRevision)) && (v.expectedHistoryVersion === null || typeof v.expectedHistoryVersion === 'string' && /^[a-f0-9]{64}$/.test(v.expectedHistoryVersion)));
  return structuredClone(v) as unknown as ProgressRead | ProgressSave;
}
export function emptyProgress(caseId: string): ProgressRecord { return { schemaVersion: '3', caseId, revision: 0, programs: [], tasks: [], dismissedProposals: [], events: [] }; }
export function parseProgressRecord(v: unknown): ProgressRecord {
  check(exact(v, ['schemaVersion', 'caseId', 'revision', 'programs', 'tasks', 'dismissedProposals', 'events']) && v.schemaVersion === '3' && id(v.caseId) && rev(v.revision, true)
    && Array.isArray(v.programs) && v.programs.length <= 32 && Array.isArray(v.tasks) && v.tasks.length <= 128 && Array.isArray(v.events) && v.events.length <= 500
    && v.events.length === v.revision && Array.isArray(v.dismissedProposals) && v.dismissedProposals.length <= 200 && v.dismissedProposals.every(id));
  for (const p of v.programs) check(exact(p, ['programId', 'name', 'trackedAt', 'trackedBy']) && id(p.programId) && text(p.name, 200) && requestInstant(p.trackedAt) && id(p.trackedBy));
  v.tasks.forEach(parseTask);
  for (const [i, e] of v.events.entries()) { check(exact(e, ['mutationId', 'requestHash', 'revision', 'recordedAt', 'recordedBy', 'caseRevision', 'operation']) && id(e.mutationId)
    && /^[a-f0-9]{64}$/.test(e.requestHash) && e.revision === i + 1 && requestInstant(e.recordedAt) && id(e.recordedBy) && rev(e.caseRevision)); parseProgressOperation(e.operation); }
  for (const values of [v.programs.map((p: TrackedProgram) => p.programId), v.tasks.map((t: NextStepTask) => t.id), v.events.map((e: TaskEvent) => e.mutationId), v.dismissedProposals]) check(new Set(values).size === values.length);
  const tasks = new Map<string, NextStepTask>(), dismissed: string[] = [], imports = new Map<string, string>();
  for (const e of v.events) {
    const op = e.operation as ProgressOperation;
    if (op.type === 'put_task') {
      const previous = tasks.get(op.task.id);
      check((previous?.revision ?? 0) === op.expectedTaskRevision && op.task.revision === op.expectedTaskRevision + 1);
      check(!previous || canonicalJson(previous.referral ?? null) === canonicalJson(op.task.referral ?? null));
      const source = op.task.referral?.imported?.sourceTaskId;
      if (source) { check(!imports.has(source) || imports.get(source) === op.task.id); imports.set(source, op.task.id); }
      tasks.set(op.task.id, op.task);
    } else if (op.type === 'dismiss_proposal') dismissed.push(op.eventId);
  }
  check(canonicalJson([...tasks.values()]) === canonicalJson(v.tasks) && canonicalJson(dismissed) === canonicalJson(v.dismissedProposals));
  check(Buffer.byteLength(JSON.stringify(v)) <= PROGRESS_MAX_BYTES);
  return structuredClone(v) as ProgressRecord;
}
export function progressHash(input: ProgressSave): string { return createHash('sha256').update(canonicalJson(input)).digest('hex'); }
export function programReports(ctx: ProgressContext, programId: string) {
  const old = ctx.legacy.find(h => h.programId === programId)?.events ?? [];
  return [...old.map(e => ({ ...e, recordedBy: null as string | null })), ...ctx.record.events.flatMap(e => e.operation.type === 'report_status' && e.operation.programId === programId
    ? [{ ...e.operation.update, revision: e.revision, caseRevision: e.caseRevision, recordedAt: e.recordedAt, recordedBy: e.recordedBy }] : [])]
    .sort((a, b) => a.recordedAt.localeCompare(b.recordedAt));
}
export function progressPrograms(ctx: ProgressContext, registry: ProgramDefinition[]) {
  const programs = new Map(ctx.record.programs.map(p => [p.programId, p]));
  for (const h of ctx.legacy) if (!programs.has(h.programId)) programs.set(h.programId, { programId: h.programId, name: registry.find(p => p.programId === h.programId)?.programName ?? h.programId,
    trackedAt: h.events[0]?.recordedAt ?? '', trackedBy: '' });
  return [...programs.values()].sort((a, b) => a.programId.localeCompare(b.programId)).map(p => {
    const reports = programReports(ctx, p.programId), latest = reports.at(-1) ?? null;
    const legacy = ctx.legacy.find(h => h.programId === p.programId)?.events.at(-1);
    const proposal = legacy?.nextAction && !ctx.record.dismissedProposals.includes(legacy.updateId) && !ctx.record.tasks.some(t => t.sourceEventId === legacy.updateId)
      ? { eventId: legacy.updateId, title: legacy.nextAction, responsiblePerson: legacy.responsibleParty, dueOn: legacy.followUpOn } : null;
    return { ...p, latest, proposal, retired: !registry.some(r => r.programId === p.programId), ruleVersion: registry.find(r => r.programId === p.programId)?.ruleVersion ?? null,
      unresolvedRequirements: ctx.record.tasks.filter(t => t.programId === p.programId && !['completed', 'cancelled'].includes(t.state)).length };
  });
}
export function progressHistoryVersion(ctx: ProgressContext): string { return createHash('sha256').update(canonicalJson(ctx.legacy.map(h => ({ programId: h.programId, revision: h.requestRevision })).sort((a,b) => a.programId.localeCompare(b.programId)))).digest('hex'); }
export function progressPage(ctx: ProgressContext, query: ProgressRead, registry: ProgramDefinition[], ack: string | null = null, at: string = new Date().toISOString()) {
  const programs = progressPrograms(ctx, registry), tasks = [...ctx.record.tasks].sort((a, b) => a.id.localeCompare(b.id));
  const total = Math.max(programs.length, tasks.length);
  const matches = matchPrograms(ctx.snapshot, registry, { evaluatedAt: at, evaluationDate: at.slice(0, 10) }).matches;
  return { schemaVersion: '3', caseId: ctx.snapshot.caseId, caseRevision: ctx.snapshot.revision, revision: ctx.record.revision, historyVersion: progressHistoryVersion(ctx),
    programs: programs.slice(query.offset, query.offset + query.limit).map(p => ({ ...p, requirements: matches.find(m => m.programId === p.programId)?.checks.filter(c => c.status !== 'pass').map(c => ({ id: c.id, status: c.status, explanation: c.explanation })) ?? null })), tasks: tasks.slice(query.offset, query.offset + query.limit).map(t => { const visible: NextStepTask = { ...t }; if (query.includeReferrals !== true) delete visible.referral; return { ...visible, needsReview: t.basedOnCaseRevision !== ctx.snapshot.revision || t.basedOnRuleVersion !== (registry.find(p => p.programId === t.programId)?.ruleVersion ?? null) }; }),
    nextOffset: query.offset + query.limit < total ? query.offset + query.limit : null, acknowledgedMutationId: ack };
}
export function changeProgress(ctx: ProgressContext, input: ProgressSave, userId: string, at: string, registry: ProgramDefinition[]): { status: 'changed'; record: ProgressRecord } | { status: 'retry' } | Exclude<ProgressResult, { status: 'found' }> {
  const retry = ctx.record.events.find(e => e.mutationId === input.mutationId);
  if (retry) return { status: retry.requestHash === progressHash(input) ? 'retry' : 'mutation_conflict' };
  if (input.expectedCaseRevision !== ctx.snapshot.revision) return { status: 'conflict' };
  if (input.expectedProgressRevision !== ctx.record.revision) return { status: 'progress_conflict' };
  if (ctx.record.events.length >= 500) return { status: 'limit' };
  const record = structuredClone(ctx.record), op = structuredClone(input.operation);
  for (const p of progressPrograms(ctx, registry)) if (!record.programs.some(r => r.programId === p.programId)) record.programs.push({ programId: p.programId, name: p.name, trackedAt: p.trackedAt || at, trackedBy: userId });
  if (op.type === 'track_program') {
    const p = registry.find(p => p.programId === op.programId);
    if (!p && !record.programs.some(p => p.programId === op.programId)) return { status: 'invalid_operation' };
    if (!record.programs.some(p => p.programId === op.programId)) record.programs.push({ programId: op.programId, name: p!.programName, trackedAt: at, trackedBy: userId });
  } else if (op.type === 'put_task') {
    const task = op.task, old = record.tasks.find(t => t.id === task.id);
    if (old?.referral && !Object.hasOwn(task, 'referral')) task.referral = structuredClone(old.referral);
    if (old && canonicalJson(task.referral ?? null) !== canonicalJson(old.referral ?? null)) return { status: 'invalid_operation' };
    const imported = task.referral?.imported;
    if (!old && imported && record.tasks.some(t => t.referral?.imported?.sourceTaskId === imported.sourceTaskId)) return { status: 'task_conflict' };
    if ((old?.revision ?? 0) !== op.expectedTaskRevision || task.revision !== op.expectedTaskRevision + 1) return { status: 'task_conflict' };
    if (task.state === 'completed' && (task.basedOnCaseRevision !== ctx.snapshot.revision || task.basedOnRuleVersion !== (registry.find(p => p.programId === task.programId)?.ruleVersion ?? null))) return { status: 'invalid_operation' };
    if (task.basedOnCaseRevision > ctx.snapshot.revision || !old && task.basedOnCaseRevision !== ctx.snapshot.revision
      || task.programId !== null && !record.programs.some(p => p.programId === task.programId)
      || task.findingId !== null && !ctx.snapshot.findings.some(f => f.id === task.findingId)
      || old && (task.sourceEventId !== old.sourceEventId)) return { status: 'invalid_operation' };
    if (!old && task.sourceEventId !== null) {
      const p = progressPrograms(ctx, registry).find(p => p.programId === task.programId)?.proposal;
      if (!p || p.eventId !== task.sourceEventId || record.tasks.some(t => t.sourceEventId === task.sourceEventId)) return { status: 'invalid_operation' };
    }
    record.tasks = old ? record.tasks.map(t => t.id === task.id ? task : t) : [...record.tasks, task];
  } else if (op.type === 'dismiss_proposal') {
    if (!progressPrograms(ctx, registry).some(p => p.proposal?.eventId === op.eventId)) return { status: 'invalid_operation' };
    record.dismissedProposals.push(op.eventId);
  } else {
    if (!record.programs.some(p => p.programId === op.programId) || op.update.occurredOn > at.slice(0, 10)
      || programReports(ctx, op.programId).some(e => e.updateId === op.update.updateId)) return { status: 'invalid_operation' };
  }
  if (record.programs.length > 32 || record.tasks.length > 128 || record.dismissedProposals.length > 200) return { status: 'limit' };
  record.revision++;
  record.events.push({ mutationId: input.mutationId, requestHash: progressHash(input), revision: record.revision,
    recordedBy: userId, caseRevision: ctx.snapshot.revision, recordedAt: at < (record.events.at(-1)?.recordedAt ?? '') ? record.events.at(-1)!.recordedAt : at, operation: op });
  if (Buffer.byteLength(JSON.stringify(record)) > PROGRESS_MAX_BYTES) return { status: 'limit' };
  return { status: 'changed', record: parseProgressRecord(record) };
}
