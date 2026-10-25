import { changeHomeModel, decodeHomeRecord, parseHomeRequest, homeState, homeRoomsValid, purgeHomeRoom, type HomeSave, type HomeResult, type HomeRecord } from '../assessment/home-model.ts';
import { changeScanModel, decodeScanRecord, parseScanRequest, scanState, scanModelKey, scanRoomValid, type ScanSave, type ScanResult, type ScanModelRecord } from '../assessment/scan-model.ts';
import { changeProgress, emptyProgress, parseProgressRecord, parseProgressRequest, type ProgressContext, type ProgressRecord, type ProgressResult, type ProgressSave } from '../tracking/progress.ts';
import { assessmentForSafetyReview, changeHomeSafety, emptyHomeSafety, homeSafetyState, parseHomeSafetyRequest, type HomeSafetySave, type HomeSafetyResult } from '../assessment/home-safety.ts';
import { emptyPlanName, changePlanName, parseSavePlanNameRequest, parseNamedCaseListPage,
  type PlanNameState, type PlanNameRepository, type SavePlanNameRequest, type SavePlanNameResult, type NamedCaseListPage } from '../cases/plan-name.ts';
import { parseSavedProgramIntake, type SavedProgramIntake } from '../programs/intake.ts';
import type { ProgramIntakeRepository, ProgramIntakeReadInput, ProgramIntakeReadResult, ProgramIntakeSaveInput, ProgramIntakeSaveResult } from '../api/program-intake.ts';
import { appendAssessment, assessmentState, emptyAssessment, hash as assessmentHash, parseAssessmentRecord, parseAssessmentSave,
  type AssessmentRepository, type AssessmentResult, type AssessmentSave, type AssessmentRecord } from '../assessment/metadata.ts';
import { emptyAnnotations, parseAnnotations, parseAnnotationRequest, changedAnnotations, annotationsBound,
  type AnnotationRepository, type AnnotationResult, type AnnotationRead, type AnnotationSave, type AnnotationRecord } from '../assessment/annotations.ts';
import { instantMicros, isPacketCurrent } from '../packets.ts';
import type { CaseSnapshot, DraftPacket, MatchResponse } from '../types.ts';
import type { MatchCaseRepository } from './match-case.ts';
import type { CreatePacketInput, CreatePacketResult, PacketCaseRepository } from './prepare-packet.ts';
import { parseSavedFormAnswers, type SavedFormAnswerSet } from '../forms/form-answers.ts';
import type {
  FormAnswerCaseRepository, FormAnswerReadInput, FormAnswerReadResult, FormAnswerSaveInput, FormAnswerSaveResult,
} from './form-answers.ts';
import { createHash } from 'node:crypto';
import type { EvidenceAsset, EvidenceDescriptor, EvidenceSelection } from '../evidence/types.ts';
import { exportEvidenceFitsBudget } from '../evidence/export-budget.ts';
import type {
  EvidenceCaseBinding, EvidenceReadInput, EvidenceRepository, EvidenceRepositoryFailure, EvidenceSaveInput,
  ExportCurrentReadInput, ExportPublishInput, ExportReadInput, ExportSnapshotInput, PrivateExportArtifact,
} from '../evidence/repository.ts';
import { canonicalJson, caseFingerprint, evidenceIdentifier, evidenceInstant, evidenceRevision,
  formAnswersFingerprint, parseEvidenceDescriptor, parseEvidenceSelections, parseSanitizedEvidenceImageAsync } from '../evidence/validation.ts';
import { parseStoredExportArtifactMetadata as parseExportArtifactMetadata } from '../exports/validation.ts';
import { MAX_MEMORY_CASES, type CaseDraft } from '../cases/types.ts';
import { CAPACITY_LIMITS } from '../storage/capacity-limits.ts';
import { parseCaseDraft } from '../cases/validation.ts';
import type { CaseWriteRepository, CaseWriteResult } from '../cases/repository.ts';
import { compareCaseIds, parseCaseListPage, parseCaseListQuery,
  type CaseListPage, type CaseListQuery, type CaseListRepository } from '../cases/discovery.ts';
import { MAX_REQUEST_PROGRAMS, appendRequestHistory, emptyRequestHistory, parseRequestAppendInput,
  parseRequestHistory, parseRequestHistoryInput, type RequestHistory, type RequestHistoryRepository,
  type RequestHistoryReadInput, type RequestHistoryAppendInput, type RequestHistoryResult } from '../requests/tracking.ts';

export interface MemoryEvidenceLimits { maxBytes: number; maxAssets: number; maxArtifacts: number }
const DEFAULT_EVIDENCE_LIMITS: MemoryEvidenceLimits = { maxBytes: CAPACITY_LIMITS.binaryBytes,
  maxAssets: CAPACITY_LIMITS.evidence, maxArtifacts: CAPACITY_LIMITS.activeExports };

interface StoredEvidence { revision: number; findingId: string; preparedAt: string; asset: EvidenceAsset | null }
interface StoredExport {
  userId: string;
  caseId: string;
  revision: number;
  caseFingerprint: string;
  programId: string;
  catalogRevision: number;
  answersFingerprint: string | null;
  contextFingerprint: string;
  selections: EvidenceSelection[];
  artifact: PrivateExportArtifact;
  invalidated: boolean;
  lastCheckedAt: string;
}

export interface OwnedCase {
  userId: string;
  snapshot: CaseSnapshot;
}

export class MemoryCaseRepository implements MatchCaseRepository, PacketCaseRepository, FormAnswerCaseRepository, EvidenceRepository, CaseWriteRepository, CaseListRepository, RequestHistoryRepository, PlanNameRepository {
  private readonly programIntake = new Map<string,SavedProgramIntake>();
  private readonly assessments = new Map<string, AssessmentRecord>();
  private readonly annotations = new Map<string, AnnotationRecord>();
  private readonly cases = new Map<string, OwnedCase>();
  private readonly planNames = new Map<string, PlanNameState>();
  private readonly matches = new Map<string, MatchResponse>();
  private readonly packets = new Map<string, { caseId: string; contextFingerprint: string; packet: DraftPacket | null }>();
  private readonly packetIds = new Set<string>();
  private readonly formAnswers = new Map<string, SavedFormAnswerSet>();
  private readonly requestHistories = new Map<string, Map<string, RequestHistory>>();
  private readonly evidence = new Map<string, Map<string, StoredEvidence>>();
  private readonly catalogRevisions = new Map<string, number>();
  private readonly exports = new Map<string, StoredExport>();
  private readonly exportKeys = new Map<string, string>();
  private readonly evidenceLimits: MemoryEvidenceLimits;

  constructor(cases: OwnedCase[], evidenceLimits: MemoryEvidenceLimits = DEFAULT_EVIDENCE_LIMITS) {
    if (!Array.isArray(cases) || cases.length > MAX_MEMORY_CASES) throw new Error('Memory case limit exceeded.');
    if (evidenceLimits === null || typeof evidenceLimits !== 'object' || Object.keys(evidenceLimits).length !== 3
      || (['maxBytes', 'maxAssets', 'maxArtifacts'] as const).some(key => !Object.hasOwn(evidenceLimits, key)
        || !Number.isSafeInteger(evidenceLimits[key]) || evidenceLimits[key] < 0 || evidenceLimits[key] > DEFAULT_EVIDENCE_LIMITS[key])) {
      throw new Error('Invalid memory limits.');
    }
    this.evidenceLimits = { ...evidenceLimits };
    for (const entry of cases) {
      if (!entry.userId.trim() || this.cases.has(entry.snapshot.caseId)) {
        throw new Error('Seed cases require an owner and unique case IDs.');
      }
      this.cases.set(entry.snapshot.caseId, structuredClone(entry));
    }
  }

  async readProgramIntakeIfCurrent(input:ProgramIntakeReadInput):Promise<ProgramIntakeReadResult>{
    const entry=this.cases.get(input.caseId);if(!entry||entry.userId!==input.userId)return {status:'not_found'};
    if(entry.snapshot.revision!==input.revision)return {status:'conflict'};
    return {status:'found',saved:structuredClone(this.programIntake.get(JSON.stringify([input.caseId,input.programId]))??null)};
  }
  async saveProgramIntakeIfCurrent(input:ProgramIntakeSaveInput):Promise<ProgramIntakeSaveResult>{
    const entry=this.cases.get(input.caseId);if(!entry||entry.userId!==input.userId)return {status:'not_found'};
    if(entry.snapshot.revision!==input.revision)return {status:'conflict'};
    const key=JSON.stringify([input.caseId,input.programId]),prior=this.programIntake.get(key);
    if((prior?.intakeRevision??0)!==input.expectedIntakeRevision)return {status:'intake_conflict'};
    const saved=parseSavedProgramIntake(input.intake),caseRevision=input.revision+1;
    if(saved.caseId!==input.caseId||saved.programId!==input.programId||saved.updatedBy!==input.userId||saved.caseRevision!==caseRevision
      ||saved.intakeRevision!==input.expectedIntakeRevision+1||prior&&instantMicros(saved.updatedAt)<instantMicros(prior.updatedAt))throw Error('Invalid program intake.');
    const next=structuredClone({...entry,snapshot:{...entry.snapshot,revision:caseRevision}});
    this.programIntake.set(key,saved);this.cases.set(input.caseId,next);this.invalidateCaseOutputs(input.caseId);
    return {status:'saved',saved:structuredClone(saved),caseRevision};
  }
  private readonly scanModels = new Map<string, ScanModelRecord>();
  async readScanModelForUser(userId: string, caseId: string, roomId: string|null): Promise<ScanResult> {
    const entry=this.cases.get(caseId);if(!entry || entry.userId!==userId)return {status:'not_found'};
    return {status:'found',state:structuredClone(scanState(caseId,roomId,entry.snapshot.revision,this.scanModels.get(JSON.stringify([caseId,scanModelKey(roomId)]))??null))};
  }
  async saveScanModelForUser(userId: string, raw: ScanSave, at: string): Promise<ScanResult> {
    const input=parseScanRequest(raw,true) as ScanSave,entry=this.cases.get(input.caseId);
    if(!entry || entry.userId!==userId)return {status:'not_found'};
    const key=JSON.stringify([input.caseId,scanModelKey(input.roomId)]),old=this.scanModels.get(key)??null,result=changeScanModel(old,input,userId,entry.snapshot.revision,at);
    if(!('record' in result))return result;
    if(result.status==='changed') {
      if(!scanRoomValid(input.roomId,input.reviewJson,this.homeSafety.get(input.caseId)?.document.rooms??[]))return {status:'not_found'};
      if(!old && [...this.scanModels.values()].filter(r=>r.caseId===input.caseId).length>=33)return {status:'limit'};
      const size=Buffer.byteLength(JSON.stringify(result.record)),prior=old===null?0:Buffer.byteLength(JSON.stringify(old));
      if(this.byteCount()-prior+size>this.evidenceLimits.maxBytes)return {status:'limit'};
      this.scanModels.set(key,result.record);
    }
    return {status:'found',state:structuredClone(scanState(input.caseId,input.roomId,entry.snapshot.revision,result.record,input.mutationId))};
  }
  private readonly homeModels = new Map<string,HomeRecord>();
  async readHomeModelForUser(userId:string,caseId:string):Promise<HomeResult> {
    const entry=this.cases.get(caseId);if(!entry || entry.userId!==userId)return {status:'not_found'};
    return {status:'found',state:structuredClone(homeState(caseId,entry.snapshot.revision,this.homeModels.get(caseId)??null))};
  }
  async saveHomeModelForUser(userId:string,raw:HomeSave,at:string):Promise<HomeResult> {
    const input=parseHomeRequest(raw,true) as HomeSave,entry=this.cases.get(input.caseId);
    if(!entry || entry.userId!==userId)return {status:'not_found'};
    const old=this.homeModels.get(input.caseId)??null,result=changeHomeModel(old,input,userId,entry.snapshot.revision,at);
    if(!('record' in result))return result;
    if(result.status==='changed') {
      if(!homeRoomsValid(input.bundleJson,input.caseId,this.homeSafety.get(input.caseId)?.document.rooms??[]))return {status:'conflict'};
      const size=Buffer.byteLength(JSON.stringify(result.record)),prior=old===null?0:Buffer.byteLength(JSON.stringify(old));
      if(this.byteCount()-prior+size>this.evidenceLimits.maxBytes)return {status:'limit'};
      this.homeModels.set(input.caseId,result.record);
    }
    return {status:'found',state:structuredClone(homeState(input.caseId,entry.snapshot.revision,result.record,input.mutationId))};
  }
  private readonly progress = new Map<string, ProgressRecord>();
  async readProgressForUser(userId: string, caseId: string): Promise<ProgressResult> {
    const entry = this.cases.get(caseId); if (!entry || entry.userId !== userId) return { status: 'not_found' };
    return { status: 'found', context: structuredClone({ snapshot: entry.snapshot, record: this.progress.get(caseId) ?? emptyProgress(caseId),
      legacy: [...(this.requestHistories.get(caseId)?.values() ?? [])] }) };
  }
  async saveProgressForUser(userId: string, raw: ProgressSave, at: string, registry: import('../types.ts').ProgramDefinition[]): Promise<ProgressResult> {
    const input = parseProgressRequest(raw, true) as ProgressSave;
    const entry = this.cases.get(input.caseId); if (!entry || entry.userId !== userId) return { status: 'not_found' };
    const context: ProgressContext = { snapshot: entry.snapshot, record: this.progress.get(input.caseId) ?? emptyProgress(input.caseId), legacy: [...(this.requestHistories.get(input.caseId)?.values() ?? [])] };
    const result = changeProgress(context, input, userId, at, registry);
    if (result.status !== 'changed' && result.status !== 'retry') return result;
    if (result.status === 'changed') { this.progress.set(input.caseId, result.record); context.record = result.record; }
    return { status: 'found', context: structuredClone(context), acknowledgedMutationId: input.mutationId };
  }
  private readonly homeSafety = new Map<string, ReturnType<typeof emptyHomeSafety>>();
  async readHomeSafetyForUser(userId: string, caseId: string): Promise<HomeSafetyResult> {
    const entry = this.cases.get(caseId); if (!entry || entry.userId !== userId) return { status: 'not_found' };
    return { status: 'found', state: homeSafetyState(entry.snapshot, this.homeSafety.get(caseId) ?? null, null, this.catalogRevisions.get(caseId) ?? 0) };
  }
  async saveHomeSafetyForUser(userId: string, raw: HomeSafetySave, at: string): Promise<HomeSafetyResult> {
    const input = parseHomeSafetyRequest(raw, true) as HomeSafetySave, entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== userId) return { status: 'not_found' };
    const prior = this.homeSafety.get(input.caseId) ?? emptyHomeSafety(input.caseId);
    const catalog = { schemaVersion: '1' as const, caseId: input.caseId, caseRevision: entry.snapshot.revision, catalogRevision: this.catalogRevisions.get(input.caseId) ?? 0, evidence: [...(this.evidence.get(input.caseId)?.values() ?? [])].flatMap(s => s.asset && this.linked(entry.snapshot, s.asset.descriptor) ? [s.asset.descriptor] : []) };
    const result = changeHomeSafety(entry.snapshot, prior, input, userId, at, catalog);
    if (result.status === 'retry') return { status: 'found', state: homeSafetyState(entry.snapshot, prior, input.mutationId, this.catalogRevisions.get(input.caseId) ?? 0) };
    if (result.status !== 'changed') return result;
    if (input.operation.type === 'delete_room') {
      const key = JSON.stringify([input.caseId, scanModelKey(input.operation.roomId)]);
      if ((this.scanModels.get(key)?.revision ?? 0) !== input.operation.expectedModelRevision) return { status: 'safety_conflict' };
      this.scanModels.delete(key);
      const home=this.homeModels.get(input.caseId);
      if(home)this.homeModels.set(input.caseId,purgeHomeRoom(home,input.operation.roomId,userId,at));
    }
    const preserved = result.changesCase ? assessmentForSafetyReview({ before: entry.snapshot, next: result.snapshot,
      prior: this.assessments.get(input.caseId) ?? null, request: input, userId, at, catalogRevision: this.catalogRevisions.get(input.caseId) ?? 0 }) : { record: null, limit: false };
    if (preserved.limit) return { status: 'history_limit' };
    this.cases.set(input.caseId, { ...entry, snapshot: result.snapshot });
    if (preserved.record) this.assessments.set(input.caseId, preserved.record);
    this.homeSafety.set(input.caseId, result.record);
    if (result.changesCase) this.invalidateCaseOutputs(input.caseId);
    return { status: 'found', state: homeSafetyState(result.snapshot, result.record, input.mutationId, this.catalogRevisions.get(input.caseId) ?? 0) };
  }
  async readAssessmentForUser(userId:string,caseId:string):Promise<AssessmentResult> {
    const entry=this.cases.get(caseId);if(!entry||entry.userId!==userId)return {status:'not_found'};
    return {status:'found',state:assessmentState(entry.snapshot,this.catalogRevisions.get(caseId)??0,this.assessments.get(caseId)??null)};
  }
  async saveAssessmentForUser(userId:string,raw:AssessmentSave,at:string):Promise<AssessmentResult> {
    const input=parseAssessmentSave(raw),entry=this.cases.get(input.caseId);
    if(!entry||entry.userId!==userId)return {status:'not_found'};
    const prior=this.assessments.get(input.caseId)??emptyAssessment(entry.snapshot),catalog=this.catalogRevisions.get(input.caseId)??0;
    const retry=prior.history.find(e=>e.mutationId===input.mutationId);
    if(retry) return retry.requestHash===assessmentHash(input)?{status:'found',state:assessmentState(entry.snapshot,catalog,prior,input.mutationId)}:{status:'mutation_conflict'};
    if(entry.snapshot.revision!==input.expectedCaseRevision||caseFingerprint(entry.snapshot)!==input.expectedCaseFingerprint)return {status:'conflict'};
    if(catalog!==input.expectedCatalogRevision)return {status:'evidence_conflict'};
    if(prior.assessmentRevision!==input.expectedAssessmentRevision)return {status:'assessment_conflict'};
    const record=appendAssessment(prior,entry.snapshot,input,userId,at);if(!record)return {status:'history_limit'};
    const result=this.replaceCaseNow(userId,input.caseId,input.expectedCaseRevision,input.draft);
    if(result.status!=='saved')return {status:result.status==='evidence_conflict'?'evidence_conflict':'conflict'};
    this.assessments.set(input.caseId,record);
    return {status:'found',state:assessmentState(result.snapshot,catalog,record,input.mutationId)};
  }
  async readAnnotationsForUser(userId:string,raw:AnnotationRead):Promise<AnnotationResult> {
    const input=parseAnnotationRequest(raw,false) as AnnotationRead;
    return this.annotationState(userId,input);
  }
  private annotationState(userId:string,input:AnnotationRead):AnnotationResult {
    const entry=this.cases.get(input.caseId);if(!entry||entry.userId!==userId)return {status:'not_found'};
    if(entry.snapshot.revision!==input.expectedCaseRevision)return {status:'conflict'};
    const catalog=this.catalogRevisions.get(input.caseId)??0;
    if(catalog!==input.expectedCatalogRevision)return {status:'evidence_conflict'};
    const d=this.evidence.get(input.caseId)?.get(input.evidenceId)?.asset?.descriptor;
    if(!d||!this.linked(entry.snapshot,d))return {status:'not_found'};
    if(d.evidenceRevision!==input.expectedEvidenceRevision)return {status:'evidence_conflict'};
    const old=this.annotations.get(JSON.stringify([input.caseId,input.evidenceId]));
    const annotation=old&&annotationsBound(old,d)?old:emptyAnnotations(d,old?.annotationRevision??0);
    return {status:'found',state:structuredClone({schemaVersion:'2',caseId:input.caseId,caseRevision:entry.snapshot.revision,catalogRevision:catalog,annotation})};
  }
  async saveAnnotationsForUser(userId:string,raw:AnnotationSave,at:string):Promise<AnnotationResult> {
    const input=parseAnnotationRequest(raw,true) as AnnotationSave,result=this.annotationState(userId,input);
    if(result.status!=='found')return result;const old=result.state.annotation;
    if(old.annotationRevision!==input.expectedAnnotationRevision)return {status:'annotation_conflict'};
    if(old.imageSha256!==input.expectedImageSha256||old.imageWidth!==input.expectedImageWidth||old.imageHeight!==input.expectedImageHeight)return {status:'evidence_conflict'};
    const d=this.evidence.get(input.caseId)!.get(input.evidenceId)!.asset!.descriptor;
    const annotation=changedAnnotations(d,old,input,userId,at),catalogRevision=this.nextCatalogRevision(input.caseId);
    this.annotations.set(JSON.stringify([input.caseId,input.evidenceId]),annotation);this.catalogRevisions.set(input.caseId,catalogRevision);this.invalidateExports(input.caseId);
    return {status:'found',state:{...result.state,catalogRevision,annotation:structuredClone(annotation)}};
  }

  async loadForUser(userId: string, caseId: string): Promise<CaseSnapshot | null> {
    const entry = this.cases.get(caseId);
    return entry?.userId === userId ? structuredClone(entry.snapshot) : null;
  }

  async readPlanNameForUser(userId: string, caseId: string): Promise<PlanNameState | null> {
    if (!evidenceIdentifier(userId) || !evidenceIdentifier(caseId)) throw new Error('Invalid plan name owner.');
    const entry = this.cases.get(caseId);
    if (!entry || entry.userId !== userId) return null;
    return structuredClone(this.planNames.get(caseId) ?? emptyPlanName(caseId));
  }
  async savePlanNameForUser(userId: string, request: SavePlanNameRequest): Promise<SavePlanNameResult> {
    if (!evidenceIdentifier(userId)) throw new Error('Invalid plan name owner.');
    const input = parseSavePlanNameRequest(request), entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== userId) return { status: 'not_found' };
    const state = changePlanName(this.planNames.get(input.caseId) ?? emptyPlanName(input.caseId), input);
    if (state === null) return { status: 'conflict' };
    this.planNames.set(input.caseId, state);
    return { status: 'saved', state: structuredClone(state) };
  }
  async listNamedForUser(userId: string, query: CaseListQuery): Promise<NamedCaseListPage> {
    if (!evidenceIdentifier(userId)) throw new Error('Invalid plan name owner.');
    const captured = parseCaseListQuery(query);
    const rows = [...this.cases.values()].filter(entry => entry.userId === userId
      && (captured.afterCaseId === null || compareCaseIds(entry.snapshot.caseId, captured.afterCaseId) > 0))
      .sort((a, b) => compareCaseIds(a.snapshot.caseId, b.snapshot.caseId)).slice(0, captured.limit + 1);
    const cases = rows.slice(0, captured.limit).map(({ snapshot }) => {
      const { schemaVersion: _, ...name } = this.planNames.get(snapshot.caseId) ?? emptyPlanName(snapshot.caseId);
      return { ...name, caseRevision: snapshot.revision };
    });
    return parseNamedCaseListPage({ cases, nextAfterCaseId: rows.length > captured.limit ? cases.at(-1)!.caseId : null }, captured);
  }
  async listForUser(userId: string, input: CaseListQuery): Promise<CaseListPage> {
    if (!evidenceIdentifier(userId)) throw new Error('Invalid case discovery identity.');
    const query = parseCaseListQuery(input);
    const rows = [...this.cases.values()].filter(entry => entry.userId === userId
      && (query.afterCaseId === null || compareCaseIds(entry.snapshot.caseId, query.afterCaseId) > 0))
      .sort((a, b) => compareCaseIds(a.snapshot.caseId, b.snapshot.caseId));
    const cases = rows.slice(0, query.limit).map(entry => ({
      caseId: entry.snapshot.caseId, caseRevision: entry.snapshot.revision,
    }));
    return parseCaseListPage({ cases, nextAfterCaseId: rows.length > query.limit ? cases.at(-1)!.caseId : null }, query);
  }

  async readRequestHistoryForUser(raw: RequestHistoryReadInput): Promise<RequestHistoryResult> {
    const input = parseRequestHistoryInput(raw);
    const entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== input.userId) return { status: 'not_found' };
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    const stored = this.requestHistories.get(input.caseId)?.get(input.programId);
    const history = stored ? parseRequestHistory(stored) : emptyRequestHistory(input);
    return { status: 'found', history: parseRequestHistory({ ...history, caseRevision: input.revision }) };
  }

  async appendRequestUpdateForUser(raw: RequestHistoryAppendInput): Promise<RequestHistoryResult> {
    const input = parseRequestAppendInput(raw);
    const entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== input.userId) return { status: 'not_found' };
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    const programs = this.requestHistories.get(input.caseId) ?? new Map<string, RequestHistory>();
    const stored = programs.get(input.programId);
    const prior = stored ? parseRequestHistory(stored) : emptyRequestHistory(input);
    const result = appendRequestHistory({ ...prior, caseRevision: input.revision }, input);
    if (result.status === 'found') {
      if (!stored && programs.size >= MAX_REQUEST_PROGRAMS) return { status: 'quota_exceeded' };
      programs.set(input.programId, structuredClone(result.history));
      this.requestHistories.set(input.caseId, programs);
    }
    return result;
  }

  async createForUser(userId: string, draft: CaseDraft): Promise<CaseWriteResult> {
    if (!evidenceIdentifier(userId)) return { status: 'invalid_input' };
    let parsed: CaseDraft;
    try { parsed = parseCaseDraft(draft, true); } catch { return { status: 'invalid_input' }; }
    if (this.cases.has(parsed.caseId)) return { status: 'id_unavailable' };
    if (this.cases.size >= MAX_MEMORY_CASES
      || [...this.cases.values()].filter(entry => entry.userId === userId).length >= CAPACITY_LIMITS.casesPerOwner) {
      return { status: 'quota_exceeded' };
    }
    const snapshot: CaseSnapshot = { ...parsed, revision: 1 };
    this.cases.set(parsed.caseId, { userId, snapshot });
    return { status: 'saved', snapshot: structuredClone(snapshot) };
  }

  async replaceIfCurrent(userId: string, caseId: string, revision: number, draft: CaseDraft): Promise<CaseWriteResult> {
    return this.replaceCaseNow(userId, caseId, revision, draft);
  }
  private replaceCaseNow(userId: string, caseId: string, revision: number, draft: CaseDraft): CaseWriteResult {
    const existing = this.cases.get(caseId);
    if (!existing || existing.userId !== userId) return { status: 'not_found' };
    if (!evidenceIdentifier(userId) || !evidenceIdentifier(caseId) || !evidenceRevision(revision)) return { status: 'invalid_input' };
    if (existing.snapshot.revision !== revision) return { status: 'conflict' };
    const nextRevision = revision + 1;
    if (!evidenceRevision(nextRevision)) throw new Error('Case revision exhausted.');
    let parsed: CaseDraft;
    try { parsed = parseCaseDraft(draft, false, nextRevision); } catch { return { status: 'invalid_input' }; }
    if (parsed.caseId !== caseId) return { status: 'invalid_input' };
    const links = new Map<string, string>();
    for (const finding of parsed.findings) for (const evidenceId of finding.evidenceIds) links.set(evidenceId, finding.id);
    for (const [evidenceId, stored] of this.evidence.get(caseId) ?? []) {
      const findingId = links.get(evidenceId);
      if ((stored.asset !== null && findingId !== stored.findingId)
        || (findingId !== undefined && findingId !== stored.findingId)) return { status: 'evidence_conflict' };
    }
    const snapshot: CaseSnapshot = { ...parsed, revision: nextRevision };
    const detached = structuredClone(snapshot);
    this.cases.set(caseId, { userId, snapshot });
    this.invalidateCaseOutputs(caseId);
    return { status: 'saved', snapshot: detached };
  }

  async saveMatchIfCurrent(
    userId: string,
    caseId: string,
    revision: number,
    response: MatchResponse,
  ): Promise<'saved' | 'not_found' | 'conflict'> {
    const entry = this.cases.get(caseId);
    if (!entry || entry.userId !== userId) return 'not_found';
    if (entry.snapshot.revision !== revision) return 'conflict';
    if (response.caseId !== caseId || response.caseRevision !== revision) {
      throw new Error('Result identity does not match the saved case.');
    }
    this.matches.set(caseId, structuredClone(response));
    return 'saved';
  }

  async readSavedMatchForUser(userId: string, caseId: string): Promise<MatchResponse | null> {
    const entry = this.cases.get(caseId);
    const result = this.matches.get(caseId);
    if (!entry || entry.userId !== userId || !result || result.caseRevision !== entry.snapshot.revision) return null;
    return structuredClone(result);
  }

  async loadFormAnswersForUser(userId: string, caseId: string, programId: string): Promise<SavedFormAnswerSet | null> {
    const entry = this.cases.get(caseId);
    if (!entry || entry.userId !== userId) return null;
    const saved = this.formAnswers.get(JSON.stringify([userId, caseId, programId]));
    return saved ? structuredClone(saved) : null;
  }

  async readFormAnswersIfCurrent(input: FormAnswerReadInput): Promise<FormAnswerReadResult> {
    const entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== input.userId) return { status: 'not_found' };
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    const saved = this.formAnswers.get(JSON.stringify([input.userId, input.caseId, input.programId]));
    return { status: 'found', saved: saved ? structuredClone(saved) : null };
  }

  async saveFormAnswersIfCurrent(input: FormAnswerSaveInput): Promise<FormAnswerSaveResult> {
    const entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== input.userId) return { status: 'not_found' };
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    const key = JSON.stringify([input.userId, input.caseId, input.programId]);
    const existing = this.formAnswers.get(key);
    if ((existing?.answerRevision ?? 0) !== input.expectedAnswerRevision) return { status: 'answers_conflict' };
    const saved = parseSavedFormAnswers(input.answers);
    const caseRevision = entry.snapshot.revision + 1;
    if (!Number.isSafeInteger(caseRevision) || saved.caseId !== input.caseId || saved.caseRevision !== caseRevision
      || saved.programId !== input.programId || saved.answerRevision !== input.expectedAnswerRevision + 1
      || saved.updatedBy !== input.userId
      || saved.answers.some(answer => answer.reviewedBy !== null && answer.reviewedBy !== input.userId)) {
      throw new Error('Form-answer identity does not match the atomic save.');
    }
    if (existing && instantMicros(saved.updatedAt) < instantMicros(existing.updatedAt)) {
      throw new Error('Form-answer update time moved backwards.');
    }
    const detached = structuredClone(saved);
    const nextCase = structuredClone({ ...entry, snapshot: { ...entry.snapshot, revision: caseRevision } });
    this.formAnswers.set(key, detached);
    this.cases.set(input.caseId, nextCase);
    this.invalidateCaseOutputs(input.caseId);
    return { status: 'saved', saved: structuredClone(detached), caseRevision };
  }

  async readEvidenceCatalogForUser(userId: string, caseId: string) {
    const entry = this.cases.get(caseId);
    if (!entry || entry.userId !== userId) return { status: 'not_found' as const };
    const evidence: EvidenceDescriptor[] = [];
    for (const stored of this.evidence.get(caseId)?.values() ?? []) {
      if (stored.asset && this.linked(entry.snapshot, stored.asset.descriptor)) evidence.push(structuredClone(stored.asset.descriptor));
    }
    return { status: 'found' as const, catalog: { schemaVersion: '1' as const, caseId,
      caseRevision: entry.snapshot.revision, catalogRevision: this.catalogRevisions.get(caseId) ?? 0, evidence } };
  }

  async readEvidenceForUser(input: EvidenceReadInput) {
    const bound = this.evidenceCase(input);
    if ('status' in bound) return bound;
    const stored = this.evidence.get(input.caseId)?.get(input.evidenceId);
    if (!stored?.asset || !this.linked(bound.snapshot, stored.asset.descriptor)) return { status: 'not_found' as const };
    if (stored.revision !== input.expectedEvidenceRevision) return { status: 'evidence_conflict' as const };
    return { status: 'found' as const, asset: structuredClone(stored.asset) };
  }

  async saveEvidenceIfCurrent(input: EvidenceSaveInput) {
    const { image: suppliedImage, ...binding } = input;
    const request = structuredClone(binding);
    const image = await parseSanitizedEvidenceImageAsync(suppliedImage);
    const bound = this.evidenceCase(request);
    if ('status' in bound) return bound;
    if (!evidenceIdentifier(request.evidenceId) || !evidenceIdentifier(request.findingId)
      || !evidenceRevision(request.expectedEvidenceRevision, true)) throw new Error('Invalid evidence identity.');
    if (!this.linked(bound.snapshot, { evidenceId: request.evidenceId, findingId: request.findingId })) return { status: 'not_found' as const };
    const rows = this.evidence.get(request.caseId) ?? new Map<string, StoredEvidence>();
    const existing = rows.get(request.evidenceId);
    if ((existing?.revision ?? 0) !== request.expectedEvidenceRevision) return { status: 'evidence_conflict' as const };
    if (existing && existing.findingId !== request.findingId) return { status: 'evidence_conflict' as const };
    const descriptor = parseEvidenceDescriptor({ evidenceId: request.evidenceId, evidenceRevision: (existing?.revision ?? 0) + 1,
      caseId: request.caseId, findingId: request.findingId, mediaType: image.mediaType, byteLength: image.byteLength,
      sha256: image.sha256, width: image.width, height: image.height, capturedAt: request.capturedAt,
      preparedAt: request.preparedAt, processingVersion: image.processingVersion });
    if (existing && instantMicros(descriptor.preparedAt) < instantMicros(existing.preparedAt)) {
      throw new Error('Evidence preparation time moved backwards.');
    }
    const catalogRevision = this.nextCatalogRevision(request.caseId);
    const replacedBytes = existing?.asset?.bytes.byteLength ?? 0;
    if ((!existing && (this.assetCount() >= this.evidenceLimits.maxAssets
      || this.assetCount(request.userId) >= CAPACITY_LIMITS.evidencePerOwner))
      || this.byteCount() - this.exportBytesForCase(request.caseId) - replacedBytes + image.byteLength > this.evidenceLimits.maxBytes) return { status: 'quota_exceeded' as const };
    const asset = { descriptor, bytes: image.bytes };
    rows.set(request.evidenceId, { revision: descriptor.evidenceRevision, findingId: descriptor.findingId, preparedAt: descriptor.preparedAt, asset });
    this.evidence.set(request.caseId, rows);
    const annotationKey=JSON.stringify([request.caseId,request.evidenceId]);
    const previousAnnotation=this.annotations.get(annotationKey);
    if(previousAnnotation) this.annotations.set(annotationKey,{...emptyAnnotations(descriptor,previousAnnotation.annotationRevision+1)});
    this.catalogRevisions.set(request.caseId, catalogRevision);
    this.invalidateExports(request.caseId);
    return { status: 'saved' as const, asset: structuredClone(asset), catalogRevision };
  }

  async deleteEvidenceIfCurrent(input: EvidenceReadInput) {
    const bound = this.evidenceCase(input);
    if ('status' in bound) return bound;
    const rows = this.evidence.get(input.caseId);
    const existing = rows?.get(input.evidenceId);
    if (!existing?.asset || !this.linked(bound.snapshot, existing.asset.descriptor)) return { status: 'not_found' as const };
    if (existing.revision !== input.expectedEvidenceRevision) return { status: 'evidence_conflict' as const };
    const revision = existing.revision + 1;
    if (!evidenceRevision(revision)) throw new Error('Evidence revision exhausted.');
    const catalogRevision = this.nextCatalogRevision(input.caseId);
    rows!.set(input.evidenceId, { ...existing, revision, asset: null });
    const annotationKey=JSON.stringify([input.caseId,input.evidenceId]);
    const previousAnnotation=this.annotations.get(annotationKey);
    if(previousAnnotation) this.annotations.set(annotationKey,{...previousAnnotation,annotationRevision:previousAnnotation.annotationRevision+1,
      marks:[],reviewState:'needs_review',reviewedCaseRevision:null,reviewedAt:null,reviewedBy:null});
    this.catalogRevisions.set(input.caseId, catalogRevision);
    this.invalidateExports(input.caseId);
    return { status: 'deleted' as const, evidenceRevision: revision, catalogRevision };
  }

  async loadExportSnapshotForUser(input: ExportSnapshotInput) {
    const bound = this.evidenceCase(input);
    if ('status' in bound) return bound;
    const selected = this.selectedAssets(bound.snapshot, input.selections);
    if ('status' in selected) return selected;
    const answers = this.currentAnswers(input.userId, input.caseId, input.programId);
    return { status: 'found' as const, snapshot: { snapshot: structuredClone(bound.snapshot), caseFingerprint: caseFingerprint(bound.snapshot), answers: structuredClone(answers),
      answersFingerprint: formAnswersFingerprint(answers), catalogRevision: input.expectedCatalogRevision,
      assets: structuredClone(selected.assets) } };
  }

  async loadExportReviewForUser(input: ExportSnapshotInput) {
    const bound = this.evidenceCase(input);
    if ('status' in bound) return bound;
    const selected = this.selectedAssets(bound.snapshot, input.selections);
    if ('status' in selected) return selected;
    const answers = this.currentAnswers(input.userId, input.caseId, input.programId);
    return { status: 'found' as const, snapshot: { snapshot: structuredClone(bound.snapshot),
      caseFingerprint: caseFingerprint(bound.snapshot), answers: structuredClone(answers),
      answersFingerprint: formAnswersFingerprint(answers), catalogRevision: input.expectedCatalogRevision,
      evidence: selected.assets.map(asset => structuredClone(asset.descriptor)) } };
  }

  async publishExportIfCurrent(input: ExportPublishInput) {
    const bound = this.evidenceCase(input);
    if ('status' in bound) return bound;
    if (caseFingerprint(bound.snapshot) !== input.expectedCaseFingerprint) return { status: 'conflict' as const };
    const selected = this.selectedAssets(bound.snapshot, input.selections);
    if ('status' in selected) return selected;
    const answers = this.currentAnswers(input.userId, input.caseId, input.programId);
    if (formAnswersFingerprint(answers) !== input.expectedAnswersFingerprint) return { status: 'answers_conflict' as const };
    const metadata = parseExportArtifactMetadata(input.artifact.metadata);
    const bytes = input.artifact.bytes;
    if (!(bytes instanceof Uint8Array) || bytes.byteLength < 8 || bytes.byteLength > 32 * 1024 * 1024
      || Buffer.from(bytes.subarray(0, 5)).toString('ascii') !== '%PDF-'
      || bytes.byteLength !== metadata.byteLength || createHash('sha256').update(bytes).digest('hex') !== metadata.sha256
      || metadata.caseId !== input.caseId || metadata.caseRevision !== input.revision || metadata.programId !== input.programId
      || metadata.evidenceCatalogRevision !== input.expectedCatalogRevision || metadata.answerRevision !== (answers?.answerRevision ?? 0)
      || metadata.exportContextId !== input.contextFingerprint
      || !/^[a-f0-9]{64}$/.test(input.contextFingerprint) || !/^[A-Za-z0-9_-]{8,128}$/.test(input.generationKey)
      || !evidenceInstant(input.checkedAt)) throw new Error('Invalid export publication.');
    if (answers !== null && (answers.caseId !== input.caseId || answers.caseRevision !== input.revision
      || answers.programId !== input.programId || answers.updatedBy !== input.userId
      || answers.answers.some(answer => answer.reviewedBy !== null && answer.reviewedBy !== input.userId)
      || answers.formContextId !== metadata.formContextId || answers.formVersion !== metadata.formVersion
      || answers.mappingVersion !== metadata.mappingVersion || instantMicros(answers.updatedAt) > instantMicros(metadata.generatedAt))) {
      return { status: 'answers_conflict' as const };
    }
    if (metadata.selectedEvidence.length !== selected.assets.length || selected.assets.some((asset, index) => {
      const included = metadata.selectedEvidence[index];
      return included.evidenceId !== asset.descriptor.evidenceId || included.evidenceRevision !== asset.descriptor.evidenceRevision
        || included.findingId !== asset.descriptor.findingId || included.sha256 !== asset.descriptor.sha256
        || included.reviewedBy !== input.userId || included.reviewedAt !== metadata.generatedAt;
    })) throw new Error('Export evidence does not match the selected assets.');
    this.validateExportTimes(metadata, input.checkedAt);
    if (!this.exportTimeCurrent(metadata, input.checkedAt)) return { status: 'expired' as const };
    const key = JSON.stringify([input.userId, input.caseId, input.generationKey]);
    const existingId = this.exportKeys.get(key);
    if (existingId !== undefined) {
      const existing = this.exports.get(existingId)!;
      if (existing.invalidated || existing.contextFingerprint !== input.contextFingerprint
        || existing.caseFingerprint !== input.expectedCaseFingerprint || existing.catalogRevision !== input.expectedCatalogRevision
        || existing.answersFingerprint !== input.expectedAnswersFingerprint || existing.programId !== input.programId
        || canonicalJson(existing.selections) !== canonicalJson(input.selections)
        || !this.checkExportClock(existing, input.checkedAt)) return { status: 'generation_conflict' as const };
      return { status: 'reused' as const, artifact: structuredClone(existing.artifact.metadata) };
    }
    if (this.exports.has(metadata.artifactId)) throw new Error('Export artifact IDs must be unique.');
    if ([...this.exports.values()].filter(row => row.caseId === input.caseId).length >= CAPACITY_LIMITS.exportsPerCase
      || [...this.exports.values()].filter(row => row.artifact.bytes.byteLength > 0).length >= this.evidenceLimits.maxArtifacts
      || this.byteCount() + bytes.byteLength > this.evidenceLimits.maxBytes) {
      return { status: 'quota_exceeded' as const };
    }
    const artifact = { metadata, bytes: Uint8Array.from(bytes) };
    const stored: StoredExport = { userId: input.userId, caseId: input.caseId, revision: input.revision,
      caseFingerprint: input.expectedCaseFingerprint, programId: input.programId, catalogRevision: input.expectedCatalogRevision,
      answersFingerprint: input.expectedAnswersFingerprint, contextFingerprint: input.contextFingerprint,
      selections: parseEvidenceSelections(input.selections), artifact, invalidated: false, lastCheckedAt: input.checkedAt };
    this.exports.set(metadata.artifactId, stored);
    this.exportKeys.set(key, metadata.artifactId);
    return { status: 'saved' as const, artifact: structuredClone(metadata) };
  }

  async readExportForUser(input: ExportReadInput) {
    const entry = this.cases.get(input.caseId);
    const saved = this.exports.get(input.artifactId);
    if (!entry || entry.userId !== input.userId || !saved || saved.userId !== input.userId || saved.caseId !== input.caseId) {
      return { status: 'not_found' as const };
    }
    const current = this.exportBindingsCurrent(entry.snapshot, saved);
    if (current) return current;
    return { status: 'found' as const, artifact: structuredClone(saved.artifact.metadata) };
  }

  async readExportForUserIfCurrent(input: ExportCurrentReadInput): ReturnType<EvidenceRepository['readExportForUserIfCurrent']> {
    const current = this.currentExport(input);
    if ('status' in current) return current;
    return { status: 'found', artifact: structuredClone(current.artifact) };
  }

  async reviewExportForUserIfCurrent(input: ExportCurrentReadInput): ReturnType<EvidenceRepository['reviewExportForUserIfCurrent']> {
    const current = this.currentExport(input);
    if ('status' in current) return current;
    return { status: 'found', artifact: structuredClone(current.artifact.metadata) };
  }

  private currentExport(input: ExportCurrentReadInput): StoredExport | EvidenceRepositoryFailure {
    const entry = this.cases.get(input.caseId);
    const saved = this.exports.get(input.artifactId);
    if (!entry || entry.userId !== input.userId || !saved || saved.userId !== input.userId || saved.caseId !== input.caseId) {
      return { status: 'not_found' as const };
    }
    const current = this.exportBindingsCurrent(entry.snapshot, saved);
    if (current) return current;
    if (saved.contextFingerprint !== input.contextFingerprint) return { status: 'generation_conflict' as const };
    if (!evidenceInstant(input.checkedAt)) throw new Error('Invalid export read time.');
    if (!this.checkExportClock(saved, input.checkedAt)) return { status: 'expired' as const };
    if (!(saved.artifact.bytes instanceof Uint8Array) || saved.artifact.bytes.byteLength !== saved.artifact.metadata.byteLength) {
      throw new Error('Invalid private repository data.');
    }
    return saved;
  }

  private exportBindingsCurrent(snapshot: CaseSnapshot, saved: StoredExport): EvidenceRepositoryFailure | null {
    if (snapshot.revision !== saved.revision || caseFingerprint(snapshot) !== saved.caseFingerprint) return { status: 'conflict' };
    if ((this.catalogRevisions.get(saved.caseId) ?? 0) !== saved.catalogRevision) return { status: 'evidence_conflict' };
    if (formAnswersFingerprint(this.currentAnswers(saved.userId, saved.caseId, saved.programId)) !== saved.answersFingerprint) return { status: 'answers_conflict' };
    if (saved.invalidated) return { status: 'expired' };
    const selected = this.selectedAssets(snapshot, saved.selections);
    if ('status' in selected) return selected;
    return null;
  }

  private validateExportTimes(metadata: PrivateExportArtifact['metadata'], checkedAt: string): void {
    const generated = instantMicros(metadata.generatedAt);
    const expires = instantMicros(metadata.expiresAt);
    if (generated > instantMicros(checkedAt) || expires <= generated || expires - generated > 15n * 60n * 1_000_000n
      || (metadata.recheckAfter !== null && expires > instantMicros(metadata.recheckAfter))) {
      throw new Error('Invalid export lifetime.');
    }
  }

  private exportTimeCurrent(metadata: PrivateExportArtifact['metadata'], checkedAt: string): boolean {
    const now = instantMicros(checkedAt);
    return instantMicros(metadata.generatedAt) <= now && now < instantMicros(metadata.expiresAt)
      && (metadata.recheckAfter === null || now < instantMicros(metadata.recheckAfter));
  }

  private checkExportClock(saved: StoredExport, checkedAt: string): boolean {
    if (instantMicros(checkedAt) < instantMicros(saved.lastCheckedAt)) return false;
    saved.lastCheckedAt = checkedAt;
    if (this.exportTimeCurrent(saved.artifact.metadata, checkedAt)) return true;
    saved.invalidated = true;
    saved.artifact.bytes = new Uint8Array();
    return false;
  }

  private evidenceCase(input: EvidenceCaseBinding): OwnedCase | EvidenceRepositoryFailure {
    const entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== input.userId) return { status: 'not_found' };
    if (!evidenceRevision(input.revision) || !evidenceRevision(input.expectedCatalogRevision, true)) throw new Error('Invalid evidence revision.');
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    if ((this.catalogRevisions.get(input.caseId) ?? 0) !== input.expectedCatalogRevision) return { status: 'evidence_conflict' };
    return entry;
  }

  private linked(snapshot: CaseSnapshot, descriptor: Pick<EvidenceDescriptor, 'evidenceId' | 'findingId'>, confirmed = false): boolean {
    return snapshot.findings.some(finding => finding.id === descriptor.findingId && finding.evidenceIds.includes(descriptor.evidenceId)
      && (!confirmed || finding.reviewState === 'confirmed'));
  }

  private selectedAssets(snapshot: CaseSnapshot, input: EvidenceSelection[]): { assets: EvidenceAsset[] } | EvidenceRepositoryFailure {
    const selections = parseEvidenceSelections(input);
    const assets: EvidenceAsset[] = [];
    for (const selection of selections) {
      const stored = this.evidence.get(snapshot.caseId)?.get(selection.evidenceId);
      if (!stored?.asset || !this.linked(snapshot, stored.asset.descriptor, true)
        || stored.revision !== selection.expectedEvidenceRevision) return { status: 'evidence_conflict' };
      assets.push(stored.asset);
    }
    if (!exportEvidenceFitsBudget(assets.map(asset => asset.descriptor))) return { status: 'selection_too_large' };
    return { assets };
  }

  private currentAnswers(userId: string, caseId: string, programId: string): SavedFormAnswerSet | null {
    return this.formAnswers.get(JSON.stringify([userId, caseId, programId])) ?? null;
  }

  private nextCatalogRevision(caseId: string): number {
    const revision = (this.catalogRevisions.get(caseId) ?? 0) + 1;
    if (!evidenceRevision(revision)) throw new Error('Evidence catalog revision exhausted.');
    return revision;
  }

  private assetCount(userId?: string): number {
    let total = 0;
    for (const [caseId, rows] of this.evidence) {
      if (userId === undefined || this.cases.get(caseId)?.userId === userId) total += rows.size;
    }
    return total;
  }

  private byteCount(): number {
    let total = [...this.homeModels.values(),...this.scanModels.values()].reduce((n,r)=>n+Buffer.byteLength(JSON.stringify(r)),0);
    for (const rows of this.evidence.values()) for (const row of rows.values()) total += row.asset?.bytes.byteLength ?? 0;
    for (const row of this.exports.values()) total += row.artifact.bytes.byteLength;
    return total;
  }

  private exportBytesForCase(caseId: string): number {
    let total = 0;
    for (const row of this.exports.values()) if (row.caseId === caseId) total += row.artifact.bytes.byteLength;
    return total;
  }

  private invalidateExports(caseId: string): void {
    for (const row of this.exports.values()) if (row.caseId === caseId) {
      row.invalidated = true;
      row.artifact.bytes = new Uint8Array();
    }
  }

  private invalidateCaseOutputs(caseId: string): void {
    this.matches.delete(caseId);
    for (const row of this.packets.values()) if (row.caseId === caseId) row.packet = null;
    this.invalidateExports(caseId);
  }

  async createPacketIfCurrent(input: CreatePacketInput): Promise<CreatePacketResult> {
    const entry = this.cases.get(input.caseId);
    if (!entry || entry.userId !== input.userId) return { status: 'not_found' };
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    if (input.packet.caseId !== input.caseId || input.packet.caseRevision !== input.revision) {
      throw new Error('Packet identity does not match the current case.');
    }
    const key = JSON.stringify([input.userId, input.caseId, input.generationKey]);
    const existing = this.packets.get(key);
    if (existing) {
      if (existing.packet === null || existing.contextFingerprint !== input.contextFingerprint || !isPacketCurrent(existing.packet, input.checkedAt)) {
        return { status: 'generation_conflict' };
      }
      return { status: 'reused', packet: structuredClone(existing.packet) };
    }
    if (instantMicros(input.packet.generatedAt) > instantMicros(input.checkedAt)) throw new Error('Packet time is in the future.');
    if (input.packet.recheckAfter !== null && !isPacketCurrent(input.packet, input.checkedAt)) {
      return { status: 'generation_conflict' };
    }
    if (this.packetIds.has(input.packet.packetId)) throw new Error('Packet IDs must be unique.');
    if ([...this.packets.values()].filter(row => row.caseId === input.caseId).length >= CAPACITY_LIMITS.packetsPerCase) {
      return { status: 'quota_exceeded' };
    }
    this.packets.set(key, { caseId: input.caseId, contextFingerprint: input.contextFingerprint, packet: structuredClone(input.packet) });
    this.packetIds.add(input.packet.packetId);
    return { status: 'saved', packet: structuredClone(input.packet) };
  }
}
