import { createHash } from 'node:crypto';
import { parseCaseDraft } from '../cases/validation.ts';
import type { CaseDraft } from '../cases/types.ts';
import type { CaseSnapshot } from '../types.ts';
import { canonicalJson, caseFingerprint, evidenceIdentifier as id, evidenceRevision as revision, evidenceInstant as instant } from '../evidence/validation.ts';

export const MAX_ASSESSMENT_BYTES = 256 * 1024;
export const MAX_ASSESSMENT_EVENTS = 500;
export interface MeasurementOriginal {
  findingId: string; type: string; originalText: string | null;
  originalUnit: 'mm' | 'cm' | 'm' | 'in' | 'ft' | null;
  decimalSeparator: 'point' | 'comma' | null;
  source: 'manual' | 'estimated' | 'legacy_unknown'; recorder: 'self' | 'helper' | 'unknown'; recordedAt: string | null;
}
export interface AssessmentMetadata {
  measurements: MeasurementOriginal[];
  reviews: { findingId: string; state: 'confirmed' | 'needs_review' | 'dismissed'; note: string | null }[];
}
export interface AssessmentEvent {
  mutationId: string; requestHash: string; caseRevision: number; assessmentRevision: number;
  recordedAt: string; recordedBy: string; changes: { path: string; before: unknown; after: unknown }[];
}
export interface AssessmentRecord {
  schemaVersion: '2'; caseId: string; caseRevision: number; assessmentRevision: number;
  metadata: AssessmentMetadata; history: AssessmentEvent[];
}
export interface AssessmentState {
  schemaVersion: '2'; case: CaseSnapshot; caseFingerprint: string; catalogRevision: number;
  assessment: AssessmentRecord; acknowledgedMutationId: string | null;
}
export interface AssessmentSave {
  schemaVersion: '2'; caseId: string; expectedCaseRevision: number; expectedCaseFingerprint: string;
  expectedCatalogRevision: number; expectedAssessmentRevision: number; mutationId: string;
  draft: CaseDraft; metadata: AssessmentMetadata;
}
export type AssessmentFailure = { status: 'not_found' | 'conflict' | 'evidence_conflict' | 'assessment_conflict' | 'mutation_conflict' | 'history_limit' };
export type AssessmentResult = { status: 'found'; state: AssessmentState } | AssessmentFailure;
export interface AssessmentRepository {
  readAssessmentForUser(userId: string, caseId: string): Promise<AssessmentResult>;
  saveAssessmentForUser(userId: string, input: AssessmentSave, at: string): Promise<AssessmentResult>;
}
export function check(value: unknown): asserts value { if (!value) throw new Error('Invalid assessment metadata.'); }
export function exact(value: unknown, keys: string[]): value is Record<string, any> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
export function hash(value: unknown): string { return createHash('sha256').update(canonicalJson(value)).digest('hex'); }
const key = (f: string, t: string) => JSON.stringify([f,t]);
export function parseAssessmentMetadata(value: unknown, snapshot?: Pick<CaseSnapshot, 'findings'>): AssessmentMetadata {
  check(exact(value,['measurements','reviews']) && Array.isArray(value.measurements) && value.measurements.length <= 100
    && Array.isArray(value.reviews) && value.reviews.length <= 100 && Buffer.byteLength(JSON.stringify(value)) <= 12*1024);
  const seen = new Set<string>();
  for (const m of value.measurements) {
    check(exact(m,['findingId','type','originalText','originalUnit','decimalSeparator','source','recorder','recordedAt'])
      && id(m.findingId) && id(m.type) && !seen.has(key(m.findingId,m.type))
      && ['manual','estimated','legacy_unknown'].includes(m.source) && ['self','helper','unknown'].includes(m.recorder)
      && (m.recordedAt === null || instant(m.recordedAt)));
    seen.add(key(m.findingId,m.type));
    if (m.source === 'legacy_unknown') check(m.originalText === null && m.originalUnit === null && m.decimalSeparator === null);
    else {
      check(typeof m.originalText === 'string' && m.originalText.length <= 40
        && ['mm','cm','m','in','ft'].includes(m.originalUnit) && ['point','comma'].includes(m.decimalSeparator));
      const pattern = m.decimalSeparator === 'point' ? /^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$/ : /^(?:[0-9]+(?:,[0-9]+)?|,[0-9]+)$/;
      check(pattern.test(m.originalText.trim()));
      const normalized=m.originalText.trim().replace(',','.');check((normalized.split('.')[1]?.length??0)<=4 && normalized.replace('.','').replace(/^0+/,'').length<=9);
      const n = Number(normalized) * ({mm:1,cm:10,m:1000,in:25.4,ft:304.8} as Record<string,number>)[m.originalUnit];
      check(Number.isFinite(n) && n >= 0 && n <= 1000000);
      if (snapshot) {
        const measure = snapshot.findings.find(f=>f.id===m.findingId)?.measurements.find(x=>x.type===m.type);
        check(measure && Math.abs(measure.value-n) <= Math.max(1e-7,Math.abs(n)*1e-12)
          && measure.method === (m.source === 'manual' ? 'manual' : 'estimated'));
      }
    }
  }
  const reviews = new Set<string>();
  for (const r of value.reviews) {
    check(exact(r,['findingId','state','note']) && id(r.findingId) && !reviews.has(r.findingId)
      && ['confirmed','needs_review','dismissed'].includes(r.state)
      && (r.note === null || typeof r.note === 'string' && r.note.length <= 500 && !/[\u0000-\u001f]/.test(r.note)));
    reviews.add(r.findingId);
    if (snapshot) check(snapshot.findings.some(f=>f.id===r.findingId && f.reviewState===r.state));
  }
  if (snapshot) {
    check(value.reviews.length === snapshot.findings.length);
    const all = snapshot.findings.flatMap(f=>f.measurements.map(m=>key(f.id,m.type)));
    check(new Set(all).size === all.length && all.length === seen.size && all.every(k=>seen.has(k)));
  }
  return structuredClone(value) as AssessmentMetadata;
}
export function emptyAssessment(snapshot: CaseSnapshot): AssessmentRecord {
  return {schemaVersion:'2',caseId:snapshot.caseId,caseRevision:snapshot.revision,assessmentRevision:0,
    metadata:{measurements:[],reviews:[]},history:[]};
}
export function assessmentState(snapshot: CaseSnapshot,catalogRevision: number, record: AssessmentRecord|null,ack: string|null=null): AssessmentState {
  return structuredClone({schemaVersion:'2',case:snapshot,caseFingerprint:caseFingerprint(snapshot),catalogRevision,
    assessment:record??emptyAssessment(snapshot),acknowledgedMutationId:ack});
}
export function parseAssessmentSave(value: unknown): AssessmentSave {
  check(exact(value,['schemaVersion','caseId','expectedCaseRevision','expectedCaseFingerprint','expectedCatalogRevision',
    'expectedAssessmentRevision','mutationId','draft','metadata']) && value.schemaVersion==='2' && id(value.caseId)
    && revision(value.expectedCaseRevision) && revision(value.expectedCatalogRevision,true) && revision(value.expectedAssessmentRevision,true)
    && typeof value.expectedCaseFingerprint==='string' && /^[a-f0-9]{64}$/.test(value.expectedCaseFingerprint)
    && typeof value.mutationId==='string' && /^[A-Za-z0-9_-]{8,128}$/.test(value.mutationId));
  const draft = parseCaseDraft(value.draft,false,value.expectedCaseRevision+1); check(draft.caseId===value.caseId);
  return {...structuredClone(value),draft,metadata:parseAssessmentMetadata(value.metadata,draft)} as AssessmentSave;
}
export function parseAssessmentRecord(value: unknown): AssessmentRecord {
  check(exact(value,['schemaVersion','caseId','caseRevision','assessmentRevision','metadata','history']) && value.schemaVersion==='2'
    && id(value.caseId) && revision(value.caseRevision) && revision(value.assessmentRevision,true)
    && Array.isArray(value.history) && value.history.length<=MAX_ASSESSMENT_EVENTS && value.history.length===value.assessmentRevision
    && Buffer.byteLength(JSON.stringify(value))<=MAX_ASSESSMENT_BYTES);
  parseAssessmentMetadata(value.metadata); const mutations=new Set<string>();let lastCase=0;
  for (const [index,e] of value.history.entries()) {
    check(exact(e,['mutationId','requestHash','caseRevision','assessmentRevision','recordedAt','recordedBy','changes'])
      && typeof e.mutationId==='string' && /^[A-Za-z0-9_-]{8,128}$/.test(e.mutationId) && !mutations.has(e.mutationId)
      && typeof e.requestHash==='string' && /^[a-f0-9]{64}$/.test(e.requestHash) && revision(e.caseRevision)
      && e.caseRevision>lastCase && e.caseRevision<=value.caseRevision && e.assessmentRevision===index+1 && instant(e.recordedAt) && id(e.recordedBy)
      && Array.isArray(e.changes) && e.changes.length<=602);
    mutations.add(e.mutationId);lastCase=e.caseRevision;
    for(const c of e.changes) check(exact(c,['path','before','after']) && typeof c.path==='string' && c.path.length<=1024);
  }
  check(value.history.length===0 || lastCase===value.caseRevision);
  return structuredClone(value) as AssessmentRecord;
}
export function appendAssessment(prior: AssessmentRecord, before: CaseSnapshot, input: AssessmentSave, userId:string, at:string): AssessmentRecord|null {
  check(id(userId)&&instant(at)); const changes:AssessmentEvent['changes']=[];
  const values=(snapshot:Pick<CaseSnapshot,'findings'>,metadata:AssessmentMetadata) => new Map<string,unknown>([
    ...snapshot.findings.map(f=>[`finding/${f.id}`,f] as [string,unknown]),
    ...metadata.measurements.map(m=>[`measurement/${key(m.findingId,m.type)}`,m] as [string,unknown]),
    ...metadata.reviews.map(r=>[`review/${r.findingId}`,r] as [string,unknown]),
  ]);
  const old=values(before,prior.metadata),next=values(input.draft,input.metadata);
  for(const path of new Set([...old.keys(),...next.keys()])) {
    const a=old.get(path)??null,b=next.get(path)??null;
    if(canonicalJson(a)!==canonicalJson(b)) changes.push({path,before:a,after:b});
  }
  const record:AssessmentRecord={schemaVersion:'2',caseId:input.caseId,caseRevision:input.expectedCaseRevision+1,
    assessmentRevision:prior.assessmentRevision+1,metadata:input.metadata,history:[...prior.history,
      {mutationId:input.mutationId,requestHash:hash(input),caseRevision:input.expectedCaseRevision+1,
        assessmentRevision:prior.assessmentRevision+1,recordedAt:at,recordedBy:userId,changes}]};
  if(record.history.length>MAX_ASSESSMENT_EVENTS || Buffer.byteLength(JSON.stringify(record))>MAX_ASSESSMENT_BYTES) return null;
  return parseAssessmentRecord(record);
}
