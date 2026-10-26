import { changeHomeModel, decodeHomeRecord, parseHomeRequest, homeState, homeRoomsValid, purgeHomeRoom, type HomeSave, type HomeResult, type HomeRecord } from '../assessment/home-model.ts';
import { changeScanModel, decodeScanRecord, parseScanRequest, scanState, scanModelKey, scanRoomValid, type ScanSave, type ScanResult, type ScanModelRecord } from '../assessment/scan-model.ts';
import { changeProgress, emptyProgress, parseProgressRecord, parseProgressRequest, type ProgressContext, type ProgressRecord, type ProgressResult, type ProgressSave } from '../tracking/progress.ts';
import { assessmentForSafetyReview, changeHomeSafety, emptyHomeSafety, homeSafetyState, parseHomeSafetyRecord, parseHomeSafetyRequest, type HomeSafetySave, type HomeSafetyResult } from '../assessment/home-safety.ts';
import { emptyPlanName, changePlanName, parseStoredPlanName, parseSavePlanNameRequest, parseNamedCaseListPage,
  type PlanNameState, type PlanNameRepository, type SavePlanNameRequest, type SavePlanNameResult, type NamedCaseListPage } from '../cases/plan-name.ts';
import { parseSavedProgramIntake, type SavedProgramIntake } from '../programs/intake.ts';
import type { ProgramIntakeRepository, ProgramIntakeReadInput, ProgramIntakeReadResult, ProgramIntakeSaveInput, ProgramIntakeSaveResult } from '../api/program-intake.ts';
import { appendAssessment, assessmentState, emptyAssessment, hash as assessmentHash, parseAssessmentRecord, parseAssessmentSave,
  type AssessmentRepository, type AssessmentResult, type AssessmentSave, type AssessmentRecord } from '../assessment/metadata.ts';
import { emptyAnnotations, parseAnnotations, parseAnnotationRequest, changedAnnotations, annotationsBound,
  type AnnotationRepository, type AnnotationResult, type AnnotationRead, type AnnotationSave, type AnnotationRecord } from '../assessment/annotations.ts';
import { createHash } from 'node:crypto';
import type { Pool, PoolClient, QueryResultRow } from 'pg';
import { CAPACITY_LIMITS } from './capacity-limits.ts';
import { readPrivateBytea } from './private-bytea.ts';
import type { CaseSnapshot, DraftPacket, MatchResponse } from '../types.ts';
import type { MatchCaseRepository } from '../api/match-case.ts';
import type { CreatePacketInput, CreatePacketResult, PacketCaseRepository } from '../api/prepare-packet.ts';
import type { FormAnswerCaseRepository, FormAnswerReadInput, FormAnswerReadResult,
  FormAnswerSaveInput, FormAnswerSaveResult } from '../api/form-answers.ts';
import type { CaseWriteRepository, CaseWriteResult } from '../cases/repository.ts';
import { parseCaseListPage, parseCaseListQuery, type CaseListPage, type CaseListQuery,
  type CaseListRepository } from '../cases/discovery.ts';
import type { CaseDraft } from '../cases/types.ts';
import { parseCaseDraft } from '../cases/validation.ts';
import { parseSavedFormAnswers, type SavedFormAnswerSet } from '../forms/form-answers.ts';
import { instantMicros, isPacketCurrent } from '../packets.ts';
import type { EvidenceAsset, EvidenceDescriptor, EvidenceSelection } from '../evidence/types.ts';
import { exportEvidenceFitsBudget } from '../evidence/export-budget.ts';
import type { EvidenceCaseBinding, EvidenceReadInput, EvidenceRepository, EvidenceRepositoryFailure,
  EvidenceSaveInput, ExportCurrentReadInput, ExportPublishInput, ExportReadInput,
  ExportSnapshotInput, PrivateExportArtifact } from '../evidence/repository.ts';
import { canonicalJson, caseFingerprint, evidenceIdentifier, evidenceInstant, evidenceRevision,
  formAnswersFingerprint, parseEvidenceAssetAsync, parseEvidenceDescriptor, parseEvidenceSelections,
  parseSanitizedEvidenceImageAsync } from '../evidence/validation.ts';
import { parseStoredExportArtifactMetadata as parseExportArtifactMetadata } from '../exports/validation.ts';
import type { ExportArtifactMetadata } from '../exports/types.ts';
import { AccountClosedError, type LifecycleRepository, type DeletionCounts,
  type AccountDeletionState, type ConfirmAccountDeletionResult } from '../lifecycle/types.ts';
import { appendRequestHistory, emptyRequestHistory, MAX_REQUEST_PROGRAMS, parseRequestAppendInput,
  parseRequestHistory, parseRequestHistoryInput, type RequestHistory, type RequestHistoryAppendInput,
  type RequestHistoryReadInput, type RequestHistoryRepository, type RequestHistoryResult } from '../requests/tracking.ts';

const S = 'safeathome_private';
const LIMITS = { cases: CAPACITY_LIMITS.cases, assets: CAPACITY_LIMITS.evidence,
  artifacts: CAPACITY_LIMITS.activeExports, bytes: CAPACITY_LIMITS.binaryBytes };
type Row = QueryResultRow;
interface CaseRow { snapshot: CaseSnapshot; catalogRevision: number }
interface Quota { cases: number; assets: number; artifacts: number; bytes: number }
interface Tx { client: PoolClient; quota: Quota | null }
interface ExportBindings {
  userId: string; revision: number; caseFingerprint: string; programId: string;
  catalogRevision: number; answersFingerprint: string | null; contextFingerprint: string;
  selections: EvidenceSelection[];
}
interface ExportRow {
  artifactId: string; bindings: ExportBindings; metadata: ExportArtifactMetadata;
  invalidated: boolean; lastCheckedAt: string; byteLength: number;
}

function check(value: unknown): asserts value { if (!value) throw new Error('Invalid private repository data.'); }
function integer(value: unknown, zero = false): number {
  const parsed = typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) ? Number(value) : value;
  check(evidenceRevision(parsed, zero)); return parsed;
}
function next(value: number): number { return integer(value + 1); }
const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const validHash = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
class DeletionPreviewExpiredError extends Error {}
function linked(snapshot: CaseSnapshot, descriptor: Pick<EvidenceDescriptor, 'evidenceId' | 'findingId'>, confirmed = false): boolean {
  return snapshot.findings.some(finding => finding.id === descriptor.findingId
    && finding.evidenceIds.includes(descriptor.evidenceId) && (!confirmed || finding.reviewState === 'confirmed'));
}
function savedCase(value: unknown, caseId: string, revision: unknown): CaseSnapshot {
  check(value !== null && typeof value === 'object' && !Array.isArray(value));
  const { revision: storedRevision, ...draft } = value as Record<string, unknown>;
  const version = integer(revision); check(storedRevision === version);
  const parsed = parseCaseDraft(draft, false, 1); check(parsed.caseId === caseId);
  return { ...parsed, revision: version };
}
function exportCurrent(metadata: ExportArtifactMetadata, at: string): boolean {
  const now = instantMicros(at);
  return instantMicros(metadata.generatedAt) <= now && now < instantMicros(metadata.expiresAt)
    && (metadata.recheckAfter === null || now < instantMicros(metadata.recheckAfter));
}
function validatePdf(bytes: Uint8Array, metadata: ExportArtifactMetadata): void {
  check(bytes instanceof Uint8Array && bytes.byteLength === metadata.byteLength
    && Buffer.from(bytes.subarray(0, 5)).toString('ascii') === '%PDF-'
    && createHash('sha256').update(bytes).digest('hex') === metadata.sha256);
}

export class PostgresCaseRepository implements MatchCaseRepository, PacketCaseRepository,
  FormAnswerCaseRepository, EvidenceRepository, CaseWriteRepository, CaseListRepository, LifecycleRepository, RequestHistoryRepository, PlanNameRepository {
  private readonly pool: Pool;
  constructor(pool: Pool) { this.pool = pool; }

  private async transaction<T>(userId: string, write: boolean, operation: (tx: Tx) => Promise<T>, allowClosed = false): Promise<T> {
    check(evidenceIdentifier(userId));
    const client = await this.pool.connect();
    let broken = false;
    try {
      await client.query(write ? 'BEGIN' : 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      await client.query("SET LOCAL lock_timeout = '5s'");
      await client.query("SET LOCAL statement_timeout = '10s'");
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '10s'");
      await client.query("SELECT set_config('safeathome.user_id', $1, true)", [userId]);
      let quota: Quota | null = null;
      if (write) {
        const row = (await client.query(`SELECT * FROM ${S}.repository_quota WHERE singleton FOR UPDATE`)).rows[0];
        check(row); quota = { cases: integer(row.case_count, true), assets: integer(row.asset_count, true),
          artifacts: integer(row.artifact_count, true), bytes: integer(row.stored_bytes, true) };
      }
      if (!allowClosed && (await client.query(`SELECT 1 FROM ${S}.closed_accounts WHERE owner_hash=$1`, [digest(userId)])).rowCount) {
        throw new AccountClosedError();
      }
      const result = await operation({ client, quota });
      await client.query('COMMIT');
      return result;
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch { broken = true; }
      throw error;
    } finally { client.release(broken); }
  }

  private async caseRow(tx: Tx, userId: string, caseId: string, lock = false): Promise<CaseRow | null> {
    check(evidenceIdentifier(caseId));
    const row = (await tx.client.query(`SELECT snapshot, revision, catalog_revision FROM ${S}.cases
      WHERE case_id = $1 AND owner_id = $2${lock ? ' FOR UPDATE' : ''}`, [caseId, userId])).rows[0];
    return row ? { snapshot: savedCase(row.snapshot, caseId, row.revision), catalogRevision: integer(row.catalog_revision, true) } : null;
  }
  private async bound(tx: Tx, input: EvidenceCaseBinding, lock = false): Promise<CaseRow | EvidenceRepositoryFailure> {
    const entry = await this.caseRow(tx, input.userId, input.caseId, lock);
    if (!entry) return { status: 'not_found' };
    check(evidenceRevision(input.revision) && evidenceRevision(input.expectedCatalogRevision, true));
    if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
    if (entry.catalogRevision !== input.expectedCatalogRevision) return { status: 'evidence_conflict' };
    return entry;
  }
  private async clock(tx: Tx, checkedAt?: string): Promise<string> {
    if (checkedAt !== undefined) check(evidenceInstant(checkedAt));
    const row = (await tx.client.query("SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS now")).rows[0];
    check(evidenceInstant(row.now));
    return checkedAt !== undefined && instantMicros(checkedAt) > instantMicros(row.now) ? checkedAt : row.now;
  }
  private async quotaDelta(tx: Tx, cases = 0, assets = 0, artifacts = 0, bytes = 0): Promise<void> {
    check(tx.quota);
    await tx.client.query(`UPDATE ${S}.repository_quota SET case_count=case_count+$1,
      asset_count=asset_count+$2, artifact_count=artifact_count+$3, stored_bytes=stored_bytes+$4 WHERE singleton`,
    [cases, assets, artifacts, bytes]);
    tx.quota.cases += cases; tx.quota.assets += assets; tx.quota.artifacts += artifacts; tx.quota.bytes += bytes;
  }
  private async exportBytes(tx: Tx, caseId: string): Promise<number> {
    return integer((await tx.client.query(`SELECT COALESCE(SUM(octet_length(bytes)),0)::text AS size
      FROM ${S}.exports WHERE case_id=$1`, [caseId])).rows[0].size, true);
  }
  private async invalidateExports(tx: Tx, caseId: string): Promise<void> {
    const bytes = await this.exportBytes(tx, caseId);
    const active = integer((await tx.client.query(`SELECT count(bytes) AS count FROM ${S}.exports WHERE case_id=$1`, [caseId])).rows[0].count, true);
    await tx.client.query(`UPDATE ${S}.exports SET bytes=NULL, invalidated=true WHERE case_id=$1`, [caseId]);
    if (bytes || active) await this.quotaDelta(tx, 0, 0, -active, -bytes);
  }
  private async invalidateCase(tx: Tx, caseId: string): Promise<void> {
    await tx.client.query(`DELETE FROM ${S}.matches WHERE case_id=$1`, [caseId]);
    await tx.client.query(`UPDATE ${S}.packets SET packet=NULL WHERE case_id=$1`, [caseId]);
    await this.invalidateExports(tx, caseId);
  }
  private async answers(tx: Tx, caseId: string, programId: string): Promise<SavedFormAnswerSet | null> {
    const row = (await tx.client.query(`SELECT record, answer_revision FROM ${S}.form_answers
      WHERE case_id=$1 AND program_id=$2`, [caseId, programId])).rows[0];
    if (!row) return null;
    const saved = parseSavedFormAnswers(row.record);
    check(saved.caseId === caseId && saved.programId === programId && saved.answerRevision === integer(row.answer_revision));
    return saved;
  }

  async readProgramIntakeIfCurrent(raw:ProgramIntakeReadInput):Promise<ProgramIntakeReadResult>{
    const input=structuredClone(raw);
    return this.transaction(input.userId,false,async tx=>{
      const entry=await this.caseRow(tx,input.userId,input.caseId);if(!entry)return {status:'not_found'};
      if(entry.snapshot.revision!==input.revision)return {status:'conflict'};
      const row=(await tx.client.query(`SELECT record FROM ${S}.program_intake WHERE case_id=$1 AND program_id=$2`,[input.caseId,input.programId])).rows[0];
      return {status:'found',saved:row?parseSavedProgramIntake(row.record):null};
    });
  }
  async saveProgramIntakeIfCurrent(raw:ProgramIntakeSaveInput):Promise<ProgramIntakeSaveResult>{
    const input=structuredClone(raw),saved=parseSavedProgramIntake(input.intake);
    return this.transaction(input.userId,true,async tx=>{
      const entry=await this.caseRow(tx,input.userId,input.caseId,true);if(!entry)return {status:'not_found'};
      if(entry.snapshot.revision!==input.revision)return {status:'conflict'};
      const row=(await tx.client.query(`SELECT record FROM ${S}.program_intake WHERE case_id=$1 AND program_id=$2`,[input.caseId,input.programId])).rows[0];
      const prior=row?parseSavedProgramIntake(row.record):null;
      if((prior?.intakeRevision??0)!==input.expectedIntakeRevision)return {status:'intake_conflict'};
      const caseRevision=next(input.revision);
      check(saved.caseId===input.caseId&&saved.programId===input.programId&&saved.updatedBy===input.userId&&saved.caseRevision===caseRevision
        &&saved.intakeRevision===input.expectedIntakeRevision+1&&(!prior||instantMicros(saved.updatedAt)>=instantMicros(prior.updatedAt)));
      const snapshot={...entry.snapshot,revision:caseRevision};
      await tx.client.query(`UPDATE ${S}.cases SET revision=$2,snapshot=$3::jsonb WHERE case_id=$1`,[input.caseId,caseRevision,JSON.stringify(snapshot)]);
      await tx.client.query(`INSERT INTO ${S}.program_intake(case_id,program_id,record) VALUES($1,$2,$3::jsonb) ON CONFLICT(case_id,program_id) DO UPDATE SET record=EXCLUDED.record`,[input.caseId,input.programId,JSON.stringify(saved)]);
      await this.invalidateCase(tx,input.caseId);return {status:'saved',saved,caseRevision};
    });
  }
  async readScanModelForUser(userId: string, caseId: string, roomId: string|null): Promise<ScanResult> {
    return this.transaction(userId, false, async tx => {
      const entry=await this.caseRow(tx,userId,caseId); if(!entry)return {status:'not_found'};
      const row=(await tx.client.query(`SELECT record FROM ${S}.case_scan_models WHERE case_id=$1 AND room_key=$2`,[caseId,scanModelKey(roomId)])).rows[0];
      return {status:'found',state:scanState(caseId,roomId,entry.snapshot.revision,row?decodeScanRecord(row.record):null)};
    });
  }
  async saveScanModelForUser(userId: string, raw: ScanSave, at: string): Promise<ScanResult> {
    const input=parseScanRequest(raw,true) as ScanSave;
    return this.transaction(userId,true,async tx=>{
      const entry=await this.caseRow(tx,userId,input.caseId,true);if(!entry)return {status:'not_found'};
      const key=scanModelKey(input.roomId);
      const old=(await tx.client.query(`SELECT record FROM ${S}.case_scan_models WHERE case_id=$1 AND room_key=$2`,[input.caseId,key])).rows[0]?.record as Buffer|undefined;
      const result=changeScanModel(old?decodeScanRecord(old):null,input,userId,entry.snapshot.revision,await this.clock(tx,at));
      if(!('record' in result))return result;
      if(result.status==='changed') {
        const safety=(await tx.client.query(`SELECT home_safety FROM ${S}.cases WHERE case_id=$1`,[input.caseId])).rows[0].home_safety;
        if(!scanRoomValid(input.roomId,input.reviewJson,safety===null?[]:parseHomeSafetyRecord(safety).document.rooms))return {status:'not_found'};
        const count=Number((await tx.client.query(`SELECT count(*) AS count FROM ${S}.case_scan_models WHERE case_id=$1 AND room_key<>'home'`,[input.caseId])).rows[0].count);
        if(!old && count>=33)return {status:'limit'};
        const bytes=Buffer.from(JSON.stringify(result.record)),delta=bytes.byteLength-(old?.byteLength??0);
        if(tx.quota!.bytes+delta>CAPACITY_LIMITS.binaryBytes)return {status:'limit'};
        await tx.client.query(`INSERT INTO ${S}.case_scan_models(case_id,room_key,record) VALUES($1,$2,$3)
          ON CONFLICT(case_id,room_key) DO UPDATE SET record=EXCLUDED.record`,[input.caseId,key,bytes]);
        await this.quotaDelta(tx,0,0,0,delta);
      }
      return {status:'found',state:scanState(input.caseId,input.roomId,entry.snapshot.revision,result.record,input.mutationId)};
    });
  }
  async readHomeModelForUser(userId:string,caseId:string):Promise<HomeResult> {
    return this.transaction(userId,false,async tx=>{
      const entry=await this.caseRow(tx,userId,caseId);if(!entry)return {status:'not_found'};
      const row=(await tx.client.query(`SELECT record FROM ${S}.case_scan_models WHERE case_id=$1 AND room_key='home'`,[caseId])).rows[0];
      return {status:'found',state:homeState(caseId,entry.snapshot.revision,row?decodeHomeRecord(row.record):null)};
    });
  }
  async saveHomeModelForUser(userId:string,raw:HomeSave,at:string):Promise<HomeResult> {
    const input=parseHomeRequest(raw,true) as HomeSave;
    return this.transaction(userId,true,async tx=>{
      const entry=await this.caseRow(tx,userId,input.caseId,true);if(!entry)return {status:'not_found'};
      const old=(await tx.client.query(`SELECT record FROM ${S}.case_scan_models WHERE case_id=$1 AND room_key='home'`,[input.caseId])).rows[0]?.record as Buffer|undefined;
      const result=changeHomeModel(old?decodeHomeRecord(old):null,input,userId,entry.snapshot.revision,await this.clock(tx,at));
      if(!('record' in result))return result;
      if(result.status==='changed') {
        const safety=(await tx.client.query(`SELECT home_safety FROM ${S}.cases WHERE case_id=$1`,[input.caseId])).rows[0].home_safety;
        if(!homeRoomsValid(input.bundleJson,input.caseId,safety===null?[]:parseHomeSafetyRecord(safety).document.rooms))return {status:'conflict'};
        const bytes=Buffer.from(JSON.stringify(result.record)),delta=bytes.byteLength-(old?.byteLength??0);
        if(tx.quota!.bytes+delta>CAPACITY_LIMITS.binaryBytes)return {status:'limit'};
        await tx.client.query(`INSERT INTO ${S}.case_scan_models(case_id,room_key,record) VALUES($1,'home',$2) ON CONFLICT(case_id,room_key) DO UPDATE SET record=EXCLUDED.record`,[input.caseId,bytes]);
        await this.quotaDelta(tx,0,0,0,delta);
      }
      return {status:'found',state:homeState(input.caseId,entry.snapshot.revision,result.record,input.mutationId)};
    });
  }
  private async progressContext(tx: Tx, userId: string, caseId: string, lock = false): Promise<ProgressContext | null> {
    const entry = await this.caseRow(tx, userId, caseId, lock); if (!entry) return null;
    const row = (await tx.client.query(`SELECT progress FROM ${S}.cases WHERE case_id=$1 AND owner_id=$2`, [caseId, userId])).rows[0];
    const legacy = (await tx.client.query(`SELECT record FROM ${S}.request_history WHERE case_id=$1 ORDER BY program_id`, [caseId])).rows.map(r => parseRequestHistory(r.record));
    return { snapshot: entry.snapshot, record: row.progress === null ? emptyProgress(caseId) : parseProgressRecord(row.progress), legacy };
  }
  async readProgressForUser(userId: string, caseId: string): Promise<ProgressResult> {
    return this.transaction(userId, false, async tx => { const context = await this.progressContext(tx, userId, caseId); return context ? { status: 'found', context } : { status: 'not_found' }; });
  }
  async saveProgressForUser(userId: string, raw: ProgressSave, at: string, registry: import('../types.ts').ProgramDefinition[]): Promise<ProgressResult> {
    const input = parseProgressRequest(raw, true) as ProgressSave;
    return this.transaction(userId, true, async tx => {
      const context = await this.progressContext(tx, userId, input.caseId, true); if (!context) return { status: 'not_found' };
      const result = changeProgress(context, input, userId, new Date(await this.clock(tx, at)).toISOString(), registry);
      if (result.status !== 'changed' && result.status !== 'retry') return result;
      if (result.status === 'changed') {
        await tx.client.query(`UPDATE ${S}.cases SET progress=$3::jsonb WHERE case_id=$1 AND owner_id=$2`, [input.caseId, userId, JSON.stringify(result.record)]);
        context.record = result.record;
      }
      return { status: 'found', context, acknowledgedMutationId: input.mutationId };
    });
  }
  async readHomeSafetyForUser(userId: string, caseId: string): Promise<HomeSafetyResult> {
    check(evidenceIdentifier(caseId));
    return this.transaction(userId, false, async tx => {
      const row = (await tx.client.query(`SELECT snapshot,revision,catalog_revision,home_safety FROM ${S}.cases WHERE case_id=$1 AND owner_id=$2`, [caseId,userId])).rows[0];
      if (!row) return {status:'not_found'};
      return {status:'found',state:homeSafetyState(savedCase(row.snapshot,caseId,row.revision),row.home_safety===null?null:parseHomeSafetyRecord(row.home_safety),null,integer(row.catalog_revision,true))};
    });
  }
  async saveHomeSafetyForUser(userId: string, raw: HomeSafetySave, at: string): Promise<HomeSafetyResult> {
    const input = parseHomeSafetyRequest(raw, true) as HomeSafetySave;
    return this.transaction(userId, true, async tx => {
      const entry = await this.caseRow(tx, userId, input.caseId, true); if (!entry) return { status: 'not_found' };
      const row = (await tx.client.query(`SELECT home_safety FROM ${S}.cases WHERE case_id=$1 AND owner_id=$2`, [input.caseId, userId])).rows[0];
      const prior = row.home_safety === null ? emptyHomeSafety(input.caseId) : parseHomeSafetyRecord(row.home_safety);
      const rows = input.operation.type === 'annotate_answer' ? (await tx.client.query(`SELECT evidence_id,finding_id,revision,prepared_at,descriptor FROM ${S}.evidence WHERE case_id=$1 AND descriptor IS NOT NULL ORDER BY evidence_id`, [input.caseId])).rows : [];
      const catalog = { schemaVersion: '1' as const, caseId: input.caseId, caseRevision: entry.snapshot.revision, catalogRevision: entry.catalogRevision, evidence: rows.map(r => this.descriptor(r, input.caseId)).filter(d => linked(entry.snapshot, d)) };
      const result = changeHomeSafety(entry.snapshot, prior, input, userId, await this.clock(tx, at), catalog);
      if (result.status === 'retry') return { status: 'found', state: homeSafetyState(entry.snapshot, prior, input.mutationId, entry.catalogRevision) };
      if (result.status !== 'changed') return result;
      if (input.operation.type === 'delete_room') {
        const model = (await tx.client.query(`SELECT record FROM ${S}.case_scan_models WHERE case_id=$1 AND room_key=$2`, [input.caseId, scanModelKey(input.operation.roomId)])).rows[0]?.record as Buffer | undefined;
        if ((model ? decodeScanRecord(model).revision : 0) !== input.operation.expectedModelRevision) return { status: 'safety_conflict' };
        await tx.client.query(`DELETE FROM ${S}.case_scan_models WHERE case_id=$1 AND room_key=$2`, [input.caseId, scanModelKey(input.operation.roomId)]);
        if (model) await this.quotaDelta(tx, 0, 0, 0, -model.byteLength);
        const home=(await tx.client.query(`SELECT record FROM ${S}.case_scan_models WHERE case_id=$1 AND room_key='home'`,[input.caseId])).rows[0]?.record as Buffer|undefined;
        if(home) {
          const record=decodeHomeRecord(home),purged=purgeHomeRoom(record,input.operation.roomId,userId,await this.clock(tx,at));
          if(purged!==record) {
            const bytes=Buffer.from(JSON.stringify(purged));
            await tx.client.query(`UPDATE ${S}.case_scan_models SET record=$2 WHERE case_id=$1 AND room_key='home'`,[input.caseId,bytes]);
            await this.quotaDelta(tx,0,0,0,bytes.byteLength-home.byteLength);
          }
        }
      }
      let preserved: AssessmentRecord | null = null;
      if (result.changesCase) {
        const old = (await tx.client.query(`SELECT record FROM ${S}.assessment_metadata WHERE case_id=$1`, [input.caseId])).rows[0];
        const assessment = assessmentForSafetyReview({ before: entry.snapshot, next: result.snapshot, prior: old ? parseAssessmentRecord(old.record) : null,
          request: input, userId, at: await this.clock(tx, at), catalogRevision: entry.catalogRevision });
        if (assessment.limit) return { status: 'history_limit' };
        preserved = assessment.record;
      }
      if (preserved) await tx.client.query(`UPDATE ${S}.assessment_metadata SET record=$2::jsonb WHERE case_id=$1`, [input.caseId, JSON.stringify(preserved)]);
      await tx.client.query(`UPDATE ${S}.cases SET home_safety=$3::jsonb, revision=$4, snapshot=$5::jsonb
        WHERE case_id=$1 AND owner_id=$2`, [input.caseId, userId, JSON.stringify(result.record), result.snapshot.revision, JSON.stringify(result.snapshot)]);
      if (result.changesCase) await this.invalidateCase(tx, input.caseId);
      return { status: 'found', state: homeSafetyState(result.snapshot, result.record, input.mutationId, entry.catalogRevision) };
    });
  }
  async readAssessmentForUser(userId:string,caseId:string):Promise<AssessmentResult> {
    return this.transaction(userId,false,async tx=>{
      const entry=await this.caseRow(tx,userId,caseId);if(!entry)return {status:'not_found'};
      const row=(await tx.client.query(`SELECT record FROM ${S}.assessment_metadata WHERE case_id=$1`,[caseId])).rows[0];
      return {status:'found',state:assessmentState(entry.snapshot,entry.catalogRevision,row?parseAssessmentRecord(row.record):null)};
    });
  }
  async saveAssessmentForUser(userId:string,raw:AssessmentSave,at:string):Promise<AssessmentResult> {
    const input=parseAssessmentSave(raw);
    return this.transaction(userId,true,async tx=>{
      const entry=await this.caseRow(tx,userId,input.caseId,true);if(!entry)return {status:'not_found'};
      const row=(await tx.client.query(`SELECT record FROM ${S}.assessment_metadata WHERE case_id=$1`,[input.caseId])).rows[0];
      const prior=row?parseAssessmentRecord(row.record):emptyAssessment(entry.snapshot);
      const retry=prior.history.find(e=>e.mutationId===input.mutationId);
      if(retry)return retry.requestHash===assessmentHash(input)?{status:'found',state:assessmentState(entry.snapshot,entry.catalogRevision,prior,input.mutationId)}:{status:'mutation_conflict'};
      if(entry.snapshot.revision!==input.expectedCaseRevision||caseFingerprint(entry.snapshot)!==input.expectedCaseFingerprint)return {status:'conflict'};
      if(entry.catalogRevision!==input.expectedCatalogRevision)return {status:'evidence_conflict'};
      if(prior.assessmentRevision!==input.expectedAssessmentRevision)return {status:'assessment_conflict'};
      const record=appendAssessment(prior,entry.snapshot,input,userId,await this.clock(tx,at));if(!record)return {status:'history_limit'};
      const links=new Map(input.draft.findings.flatMap(f=>f.evidenceIds.map(id=>[id,f.id] as const)));
      const rows=(await tx.client.query(`SELECT evidence_id,finding_id,descriptor IS NOT NULL AS active FROM ${S}.evidence WHERE case_id=$1`,[input.caseId])).rows;
      if(rows.some(r=>(r.active&&links.get(r.evidence_id)!==r.finding_id)||(links.has(r.evidence_id)&&links.get(r.evidence_id)!==r.finding_id)))return {status:'evidence_conflict'};
      const snapshot={...input.draft,revision:next(input.expectedCaseRevision)};
      await tx.client.query(`UPDATE ${S}.cases SET revision=$2,snapshot=$3::jsonb WHERE case_id=$1`,[input.caseId,snapshot.revision,JSON.stringify(snapshot)]);
      await tx.client.query(`INSERT INTO ${S}.assessment_metadata(case_id,record) VALUES($1,$2::jsonb) ON CONFLICT(case_id) DO UPDATE SET record=EXCLUDED.record`,[input.caseId,JSON.stringify(record)]);
      await this.invalidateCase(tx,input.caseId);
      return {status:'found',state:assessmentState(snapshot,entry.catalogRevision,record,input.mutationId)};
    });
  }
  private async annotationState(tx:Tx,userId:string,input:AnnotationRead,lock=false):Promise<AnnotationResult> {
    const bound=await this.bound(tx,{userId,caseId:input.caseId,revision:input.expectedCaseRevision,expectedCatalogRevision:input.expectedCatalogRevision},lock);
    if('status' in bound)return {status:bound.status==='conflict'?'conflict':bound.status==='not_found'?'not_found':'evidence_conflict'};
    const row=(await tx.client.query(`SELECT descriptor FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`,[input.caseId,input.evidenceId])).rows[0];
    if(!row?.descriptor)return {status:'not_found'};const d=parseEvidenceDescriptor(row.descriptor);
    if(!linked(bound.snapshot,d))return {status:'not_found'};
    if(d.evidenceRevision!==input.expectedEvidenceRevision)return {status:'evidence_conflict'};
    const saved=(await tx.client.query(`SELECT record FROM ${S}.evidence_annotations WHERE case_id=$1 AND evidence_id=$2`,[input.caseId,input.evidenceId])).rows[0];
    const old=saved?parseAnnotations(saved.record):undefined;
    const annotation=old&&annotationsBound(old,d)?old:emptyAnnotations(d,old?.annotationRevision??0);
    return {status:'found',state:{schemaVersion:'2',caseId:input.caseId,caseRevision:bound.snapshot.revision,catalogRevision:bound.catalogRevision,annotation}};
  }
  async readAnnotationsForUser(userId:string,raw:AnnotationRead):Promise<AnnotationResult> {
    const input=parseAnnotationRequest(raw,false) as AnnotationRead;
    return this.transaction(userId,false,tx=>this.annotationState(tx,userId,input));
  }
  async saveAnnotationsForUser(userId:string,raw:AnnotationSave,at:string):Promise<AnnotationResult> {
    const input=parseAnnotationRequest(raw,true) as AnnotationSave;
    return this.transaction(userId,true,async tx=>{
      const result=await this.annotationState(tx,userId,input,true);if(result.status!=='found')return result;
      const old=result.state.annotation;
      if(old.annotationRevision!==input.expectedAnnotationRevision)return {status:'annotation_conflict'};
      if(old.imageSha256!==input.expectedImageSha256||old.imageWidth!==input.expectedImageWidth||old.imageHeight!==input.expectedImageHeight)return {status:'evidence_conflict'};
      const d=parseEvidenceDescriptor((await tx.client.query(`SELECT descriptor FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`,[input.caseId,input.evidenceId])).rows[0].descriptor);
      const annotation=changedAnnotations(d,old,input,userId,await this.clock(tx,at)),catalogRevision=next(result.state.catalogRevision);
      await tx.client.query(`INSERT INTO ${S}.evidence_annotations(case_id,evidence_id,record) VALUES($1,$2,$3::jsonb) ON CONFLICT(case_id,evidence_id) DO UPDATE SET record=EXCLUDED.record`,[input.caseId,input.evidenceId,JSON.stringify(annotation)]);
      await tx.client.query(`UPDATE ${S}.cases SET catalog_revision=$2 WHERE case_id=$1`,[input.caseId,catalogRevision]);
      await this.invalidateExports(tx,input.caseId);
      return {status:'found',state:{...result.state,catalogRevision,annotation}};
    });
  }

  async isAccountClosed(userId: string): Promise<boolean> {
    return this.transaction(userId, false, async tx => Boolean((await tx.client.query(
      `SELECT 1 FROM ${S}.closed_accounts WHERE owner_hash=$1`, [digest(userId)])).rowCount), true);
  }

  private async deletionSnapshot(tx: Tx, userId: string): Promise<{
    ids: string[]; counts: DeletionCounts; fingerprint: string;
  }> {
    const rows = (await tx.client.query(`SELECT case_id,revision,catalog_revision,
      encode(sha256(convert_to(jsonb_build_array(plan_name,home_safety,progress,collaboration)::text,'UTF8')),'hex') AS name_fingerprint FROM ${S}.cases
      WHERE owner_id=$1 ORDER BY case_id FOR UPDATE`, [userId])).rows;
    const ids = rows.map(row => String(row.case_id));
    const cases = rows.map(row => ({ id: row.case_id, revision: integer(row.revision), catalog: integer(row.catalog_revision, true),
      nameFingerprint: row.name_fingerprint }));
    const inventory: Record<string, { total: number; active: number; bytes: number; fingerprint: string }> = {};
    const content: Record<string, string> = {
      case_scan_models: "jsonb_build_array(case_id,room_key,encode(sha256(record),'hex'))::text",
      case_shares: 'to_jsonb(case_shares)::text',
      share_sensitive: 'to_jsonb(share_sensitive)::text',
      matches: 'jsonb_build_array(case_id,response)::text',
      packets: 'jsonb_build_array(case_id,generation_key,packet_id,context_fingerprint,packet)::text',
      form_answers: 'jsonb_build_array(case_id,program_id,answer_revision,record)::text',
      request_history: 'jsonb_build_array(case_id,program_id,request_revision,record)::text',
      program_intake: 'jsonb_build_array(case_id,program_id,record)::text',
      assessment_metadata: 'jsonb_build_array(case_id,record)::text',
      evidence_annotations: 'jsonb_build_array(case_id,evidence_id,record)::text',
      evidence: "jsonb_build_array(case_id,evidence_id,finding_id,revision,prepared_at,descriptor,encode(sha256(bytes),'hex'))::text",
      exports: "jsonb_build_array(case_id,artifact_id,generation_key,bindings,metadata,invalidated,last_checked_at,extract(epoch FROM expires_at),encode(sha256(bytes),'hex'))::text",
    };
    for (const table of ['case_scan_models', 'case_shares', 'share_sensitive', 'matches', 'packets', 'form_answers', 'request_history', 'assessment_metadata', 'evidence_annotations', 'program_intake', 'evidence', 'exports']) {
      const binary = table === 'evidence' || table === 'exports' || table === 'case_scan_models';
      const row = (await tx.client.query(`SELECT count(*) AS total,count(size) AS active,
        COALESCE(sum(size),0) AS bytes,
        encode(sha256(convert_to(COALESCE(string_agg(row_hash,'' ORDER BY row_hash),''),'UTF8')),'hex') AS fingerprint
        FROM (SELECT ${binary ? `octet_length(${table==='case_scan_models'?'record':'bytes'})` : '0'} AS size,
          encode(sha256(convert_to(${content[table]},'UTF8')),'hex') AS row_hash
          FROM ${S}.${table} WHERE case_id=ANY($1::text[])) AS inventory`, [ids])).rows[0];
      check(validHash(row.fingerprint));
      inventory[table] = { total: integer(row.total, true), active: integer(row.active, true), bytes: integer(row.bytes, true), fingerprint: row.fingerprint };
    }
    const counts = { cases: ids.length, evidence: inventory.evidence.active, exports: inventory.exports.active,
      storedBytes: inventory.evidence.bytes + inventory.exports.bytes + inventory.case_scan_models.bytes };
    return { ids, counts, fingerprint: digest(canonicalJson({ cases, inventory })) };
  }

  private async eraseCases(tx: Tx, userId: string, ids: string[]): Promise<void> {
    if (ids.length === 0) return;
    const rows = (await tx.client.query(`SELECT case_id,revision,catalog_revision FROM ${S}.cases
      WHERE owner_id=$1 AND case_id=ANY($2::text[]) ORDER BY case_id FOR UPDATE`, [userId, ids])).rows;
    check(rows.length === ids.length);
    for (const row of rows) {
      await tx.client.query(`INSERT INTO ${S}.deleted_cases(case_hash,owner_hash,revision,catalog_revision)
        VALUES($1,$2,$3,$4)`, [digest(row.case_id), digest(userId), row.revision, row.catalog_revision]);
    }
    const amounts = (await tx.client.query(`SELECT
      (SELECT count(*) FROM ${S}.evidence WHERE case_id=ANY($1::text[])) AS assets,
      (SELECT count(bytes) FROM ${S}.exports WHERE case_id=ANY($1::text[])) AS artifacts,
      ((SELECT COALESCE(sum(octet_length(bytes)),0) FROM ${S}.evidence WHERE case_id=ANY($1::text[]))+
       (SELECT COALESCE(sum(octet_length(bytes)),0) FROM ${S}.exports WHERE case_id=ANY($1::text[])) +
       (SELECT COALESCE(sum(octet_length(record)),0) FROM ${S}.case_scan_models WHERE case_id=ANY($1::text[]))) AS bytes`, [ids])).rows[0];
    for (const table of ['case_scan_models', 'case_shares', 'share_sensitive', 'matches', 'packets', 'form_answers', 'request_history', 'assessment_metadata', 'evidence_annotations', 'program_intake', 'evidence', 'exports']) {
      await tx.client.query(`DELETE FROM ${S}.${table} WHERE case_id=ANY($1::text[])`, [ids]);
    }
    const removed = await tx.client.query(`DELETE FROM ${S}.cases WHERE owner_id=$1 AND case_id=ANY($2::text[])`, [userId, ids]);
    check(removed.rowCount === ids.length);
    await this.quotaDelta(tx, -ids.length, -integer(amounts.assets, true), -integer(amounts.artifacts, true), -integer(amounts.bytes, true));
  }

  async deleteCaseIfCurrent(input: Parameters<LifecycleRepository['deleteCaseIfCurrent']>[0]): ReturnType<LifecycleRepository['deleteCaseIfCurrent']> {
    const request = structuredClone(input);
    if (![request.userId, request.caseId].every(evidenceIdentifier) || !evidenceRevision(request.revision)
      || !evidenceRevision(request.expectedCatalogRevision, true)) return { status: 'invalid_input' };
    return this.transaction(request.userId, true, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId, true);
      if (!entry) {
        const prior = (await tx.client.query(`SELECT revision,catalog_revision FROM ${S}.deleted_cases
          WHERE case_hash=$1 AND owner_hash=$2`, [digest(request.caseId), digest(request.userId)])).rows[0];
        if (!prior) return { status: 'not_found' };
        if (integer(prior.revision) !== request.revision) return { status: 'conflict' };
        if (integer(prior.catalog_revision, true) !== request.expectedCatalogRevision) return { status: 'evidence_conflict' };
        return { status: 'deleted' };
      }
      if (entry.snapshot.revision !== request.revision) return { status: 'conflict' };
      if (entry.catalogRevision !== request.expectedCatalogRevision) return { status: 'evidence_conflict' };
      await this.eraseCases(tx, request.userId, [request.caseId]);
      return { status: 'deleted' };
    });
  }

  async prepareAccountDeletion(input: Parameters<LifecycleRepository['prepareAccountDeletion']>[0]): ReturnType<LifecycleRepository['prepareAccountDeletion']> {
    const request = structuredClone(input);
    if (!evidenceIdentifier(request.userId) || !validHash(request.tokenHash)) return { status: 'invalid_input' };
    return this.transaction(request.userId, true, async tx => {
      const ownerHash = digest(request.userId);
      if ((await tx.client.query(`SELECT 1 FROM ${S}.closed_accounts WHERE owner_hash=$1`, [ownerHash])).rowCount) return { status: 'closed' };
      const snapshot = await this.deletionSnapshot(tx, request.userId);
      const result = await tx.client.query(`INSERT INTO ${S}.account_deletion_previews(owner_hash,token_hash,fingerprint,expires_at)
        VALUES($1,$2,$3,clock_timestamp()+interval '5 minutes') ON CONFLICT(owner_hash) DO UPDATE
        SET token_hash=EXCLUDED.token_hash,fingerprint=EXCLUDED.fingerprint,expires_at=EXCLUDED.expires_at
        RETURNING expires_at`, [ownerHash, request.tokenHash, snapshot.fingerprint]);
      return { status: 'ready', counts: snapshot.counts, expiresAt: result.rows[0].expires_at.toISOString() };
    }, true);
  }

  private deletionState(row: Row): AccountDeletionState {
    return { status: row.auth_deleted_at === null ? 'auth_pending' : 'complete',
      applicationDataDeleted: true, providerIdentityDeleted: row.auth_deleted_at !== null };
  }

  async confirmAccountDeletion(input: Parameters<LifecycleRepository['confirmAccountDeletion']>[0]): ReturnType<LifecycleRepository['confirmAccountDeletion']> {
    const request = structuredClone(input);
    if (!evidenceIdentifier(request.userId) || !validHash(request.tokenHash)) return { status: 'invalid_input' };
    return this.transaction<ConfirmAccountDeletionResult>(request.userId, true, async tx => {
      const ownerHash = digest(request.userId);
      const prior = (await tx.client.query(`SELECT auth_deleted_at FROM ${S}.closed_accounts
        WHERE owner_hash=$1 AND receipt_hash=$2 AND receipt_expires_at>clock_timestamp()`, [ownerHash, request.tokenHash])).rows[0];
      if (prior) return { status: 'confirmed', deletion: this.deletionState(prior) };
      if ((await tx.client.query(`SELECT 1 FROM ${S}.closed_accounts WHERE owner_hash=$1`, [ownerHash])).rowCount) return { status: 'not_found' };
      const preview = (await tx.client.query(`SELECT fingerprint,expires_at>clock_timestamp() AS current
        FROM ${S}.account_deletion_previews WHERE owner_hash=$1 AND token_hash=$2 FOR UPDATE`, [ownerHash, request.tokenHash])).rows[0];
      if (!preview) return { status: 'not_found' };
      if (!preview.current) return { status: 'expired' };
      const snapshot = await this.deletionSnapshot(tx, request.userId);
      if (snapshot.fingerprint !== preview.fingerprint) return { status: 'changed' };
      const current = (await tx.client.query(`SELECT expires_at>clock_timestamp() AS current
        FROM ${S}.account_deletion_previews WHERE owner_hash=$1`, [ownerHash])).rows[0];
      if (!current?.current) return { status: 'expired' };
      await this.eraseCases(tx, request.userId, snapshot.ids);
      await tx.client.query(`INSERT INTO ${S}.closed_accounts(owner_hash,closed_at,receipt_hash,receipt_expires_at)
        VALUES($1,clock_timestamp(),$2,clock_timestamp()+interval '30 days')`, [ownerHash, request.tokenHash]);
      await tx.client.query(`INSERT INTO ${S}.auth_deletion_jobs(owner_hash,raw_user_id) VALUES($1,$2)`, [ownerHash, request.userId]);
      const finalCheck = (await tx.client.query(`SELECT expires_at>clock_timestamp() AS current
        FROM ${S}.account_deletion_previews WHERE owner_hash=$1`, [ownerHash])).rows[0];
      if (!finalCheck?.current) throw new DeletionPreviewExpiredError();
      await tx.client.query(`DELETE FROM ${S}.account_deletion_previews WHERE owner_hash=$1`, [ownerHash]);
      return { status: 'confirmed', deletion: { status: 'auth_pending', applicationDataDeleted: true, providerIdentityDeleted: false } };
    }, true).catch(error => {
      if (error instanceof DeletionPreviewExpiredError) return { status: 'expired' };
      throw error;
    });
  }

  async readAccountDeletionReceipt(tokenHash: string): Promise<AccountDeletionState | null> {
    if (!validHash(tokenHash)) return null;
    const client = await this.pool.connect();
    let broken = false;
    try {
      await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      await client.query("SET LOCAL statement_timeout = '5s'");
      await client.query("SELECT set_config('safeathome.user_id', '', true), set_config('safeathome.receipt_hash', $1, true)", [tokenHash]);
      const row = (await client.query(`SELECT auth_deleted_at FROM ${S}.closed_accounts
        WHERE receipt_hash=$1 AND receipt_expires_at>clock_timestamp()`, [tokenHash])).rows[0];
      const preview = row ? null : (await client.query(`SELECT 1 FROM ${S}.account_deletion_previews
        WHERE token_hash=$1 AND expires_at>clock_timestamp()`, [tokenHash])).rows[0];
      await client.query('COMMIT');
      return row ? this.deletionState(row) : preview ? { status: 'awaiting_confirmation',
        applicationDataDeleted: false, providerIdentityDeleted: false } : null;
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch { broken = true; }
      throw error;
    } finally { client.release(broken); }
  }

  async loadForUser(userId: string, caseId: string): Promise<CaseSnapshot | null> {
    return this.transaction(userId, false, async tx => (await this.caseRow(tx, userId, caseId))?.snapshot ?? null);
  }
  private async requestHistory(tx: Tx, input: RequestHistoryReadInput): Promise<RequestHistory> {
    const row = (await tx.client.query(`SELECT request_revision,record FROM ${S}.request_history
      WHERE case_id=$1 AND program_id=$2`, [input.caseId, input.programId])).rows[0];
    if (!row) return emptyRequestHistory(input);
    const stored = parseRequestHistory(row.record);
    check(stored.caseId === input.caseId && stored.programId === input.programId
      && stored.requestRevision === integer(row.request_revision) && stored.caseRevision <= input.revision);
    return parseRequestHistory({ ...stored, caseRevision: input.revision });
  }
  async readRequestHistoryForUser(raw: RequestHistoryReadInput): Promise<RequestHistoryResult> {
    const input = parseRequestHistoryInput(raw);
    return this.transaction(input.userId, false, async tx => {
      const entry = await this.caseRow(tx, input.userId, input.caseId);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
      return { status: 'found', history: await this.requestHistory(tx, input) };
    });
  }
  async appendRequestUpdateForUser(raw: RequestHistoryAppendInput): Promise<RequestHistoryResult> {
    const input = parseRequestAppendInput(raw);
    return this.transaction(input.userId, true, async tx => {
      const entry = await this.caseRow(tx, input.userId, input.caseId, true);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== input.revision) return { status: 'conflict' };
      const current = await this.requestHistory(tx, input);
      const result = appendRequestHistory(current, input);
      if (result.status !== 'found' || result.history.requestRevision === current.requestRevision) return result;
      if (current.requestRevision === 0) {
        const row = (await tx.client.query(`SELECT count(*) AS count FROM ${S}.request_history WHERE case_id=$1`, [input.caseId])).rows[0];
        if (integer(row.count, true) >= MAX_REQUEST_PROGRAMS) return { status: 'quota_exceeded' };
      }
      await tx.client.query(`INSERT INTO ${S}.request_history(case_id,program_id,request_revision,record)
        VALUES($1,$2,$3,$4::jsonb) ON CONFLICT(case_id,program_id) DO UPDATE
        SET request_revision=EXCLUDED.request_revision,record=EXCLUDED.record`,
      [input.caseId, input.programId, result.history.requestRevision, JSON.stringify(result.history)]);
      return result;
    });
  }
  async readPlanNameForUser(userId: string, caseId: string): Promise<PlanNameState | null> {
    check(evidenceIdentifier(caseId));
    return this.transaction(userId, false, async tx => {
      const row = (await tx.client.query(`SELECT plan_name FROM ${S}.cases WHERE owner_id=$1 AND case_id=$2`, [userId, caseId])).rows[0];
      if (!row) return null;
      const state = row.plan_name === null ? emptyPlanName(caseId) : parseStoredPlanName(row.plan_name);
      check(state.caseId === caseId);
      return state;
    });
  }
  async savePlanNameForUser(userId: string, request: SavePlanNameRequest): Promise<SavePlanNameResult> {
    const input = parseSavePlanNameRequest(request);
    return this.transaction(userId, true, async tx => {
      const row = (await tx.client.query(`SELECT plan_name FROM ${S}.cases
        WHERE owner_id=$1 AND case_id=$2 FOR UPDATE`, [userId, input.caseId])).rows[0];
      if (!row) return { status: 'not_found' };
      const prior = row.plan_name === null ? emptyPlanName(input.caseId) : parseStoredPlanName(row.plan_name);
      const state = changePlanName(prior, input);
      if (state === null) return { status: 'conflict' };
      if (state.nameRevision !== prior.nameRevision) {
        const result = await tx.client.query(`UPDATE ${S}.cases SET plan_name=$3::jsonb WHERE owner_id=$1 AND case_id=$2`,
          [userId, input.caseId, JSON.stringify(state)]);
        check(result.rowCount === 1);
      }
      return { status: 'saved', state };
    });
  }
  async listNamedForUser(userId: string, query: CaseListQuery): Promise<NamedCaseListPage> {
    const captured = parseCaseListQuery(query);
    return this.transaction(userId, false, async tx => {
      const rows = (await tx.client.query(`SELECT case_id,revision,plan_name FROM ${S}.cases
        WHERE owner_id=$1 AND ($2::text IS NULL OR case_id COLLATE "C" > $2::text COLLATE "C")
        ORDER BY case_id COLLATE "C" ASC LIMIT $3`, [userId, captured.afterCaseId, captured.limit + 1])).rows;
      const cases = rows.slice(0, captured.limit).map(row => {
        const { schemaVersion: _, ...name } = row.plan_name === null ? emptyPlanName(row.case_id) : parseStoredPlanName(row.plan_name);
        check(name.caseId === row.case_id);
        return { ...name, caseRevision: integer(row.revision) };
      });
      return parseNamedCaseListPage({ cases, nextAfterCaseId: rows.length > captured.limit ? cases.at(-1)!.caseId : null }, captured);
    });
  }
  async listForUser(userId: string, query: CaseListQuery): Promise<CaseListPage> {
    const captured = parseCaseListQuery(query);
    return this.transaction(userId, false, async tx => {
      const rows = (await tx.client.query(`SELECT case_id, revision FROM ${S}.cases
        WHERE owner_id=$1 AND ($2::text IS NULL OR case_id COLLATE "C" > $2::text COLLATE "C")
        ORDER BY case_id COLLATE "C" ASC LIMIT $3`,
      [userId, captured.afterCaseId, captured.limit + 1])).rows;
      const cases = rows.slice(0, captured.limit).map(row => ({
        caseId: row.case_id, caseRevision: integer(row.revision),
      }));
      return parseCaseListPage({ cases, nextAfterCaseId: rows.length > captured.limit
        ? cases[cases.length - 1]!.caseId : null }, captured);
    });
  }
  async createForUser(userId: string, draft: CaseDraft): Promise<CaseWriteResult> {
    if (!evidenceIdentifier(userId)) return { status: 'invalid_input' };
    let parsed: CaseDraft;
    try { parsed = parseCaseDraft(draft, true); } catch { return { status: 'invalid_input' }; }
    const snapshot: CaseSnapshot = { ...parsed, revision: 1 };
    return this.transaction(userId, true, async tx => {
      const deleted = await tx.client.query(`SELECT ${S}.case_id_was_deleted($1) AS deleted`, [digest(snapshot.caseId)]);
      if (deleted.rows[0].deleted === true) return { status: 'id_unavailable' };
      await tx.client.query('SAVEPOINT create_case');
      const result = await tx.client.query(`INSERT INTO ${S}.cases(case_id,owner_id,revision,snapshot)
        VALUES($1,$2,1,$3::jsonb) ON CONFLICT(case_id) DO NOTHING RETURNING case_id`,
      [snapshot.caseId, userId, JSON.stringify(snapshot)]);
      if (result.rowCount === 0) return { status: 'id_unavailable' };
      const owned = (await tx.client.query(`SELECT count(*) AS count FROM ${S}.cases WHERE owner_id=$1`, [userId])).rows[0];
      if (tx.quota!.cases >= LIMITS.cases || integer(owned.count, true) > CAPACITY_LIMITS.casesPerOwner) {
        await tx.client.query('ROLLBACK TO SAVEPOINT create_case'); return { status: 'quota_exceeded' };
      }
      await this.quotaDelta(tx, 1);
      return { status: 'saved', snapshot: structuredClone(snapshot) };
    });
  }
  async replaceIfCurrent(userId: string, caseId: string, revision: number, draft: CaseDraft): Promise<CaseWriteResult> {
    if (![userId, caseId].every(evidenceIdentifier) || !evidenceRevision(revision)) return { status: 'invalid_input' };
    let parsed: CaseDraft;
    try { parsed = parseCaseDraft(draft, false, next(revision)); } catch { return { status: 'invalid_input' }; }
    if (parsed.caseId !== caseId) return { status: 'invalid_input' };
    return this.transaction(userId, true, async tx => {
      const entry = await this.caseRow(tx, userId, caseId, true);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== revision) return { status: 'conflict' };
      const links = new Map(parsed.findings.flatMap(finding => finding.evidenceIds.map(id => [id, finding.id] as const)));
      const rows = (await tx.client.query(`SELECT evidence_id,finding_id,descriptor IS NOT NULL AS active
        FROM ${S}.evidence WHERE case_id=$1`, [caseId])).rows;
      if (rows.some(row => (row.active && links.get(row.evidence_id) !== row.finding_id)
        || (links.has(row.evidence_id) && links.get(row.evidence_id) !== row.finding_id))) return { status: 'evidence_conflict' };
      const snapshot = { ...parsed, revision: next(revision) };
      await tx.client.query(`UPDATE ${S}.cases SET revision=$2,snapshot=$3::jsonb WHERE case_id=$1`,
        [caseId, snapshot.revision, JSON.stringify(snapshot)]);
      await this.invalidateCase(tx, caseId);
      return { status: 'saved', snapshot: structuredClone(snapshot) };
    });
  }
  async saveMatchIfCurrent(userId: string, caseId: string, revision: number, response: MatchResponse): Promise<'saved' | 'not_found' | 'conflict'> {
    const detached = structuredClone(response);
    return this.transaction(userId, true, async tx => {
      const entry = await this.caseRow(tx, userId, caseId, true);
      if (!entry) return 'not_found';
      if (entry.snapshot.revision !== revision) return 'conflict';
      check(detached.caseId === caseId && detached.caseRevision === revision);
      await tx.client.query(`INSERT INTO ${S}.matches(case_id,response) VALUES($1,$2::jsonb)
        ON CONFLICT(case_id) DO UPDATE SET response=EXCLUDED.response`, [caseId, JSON.stringify(detached)]);
      return 'saved';
    });
  }
  async readSavedMatchForUser(userId: string, caseId: string): Promise<MatchResponse | null> {
    return this.transaction(userId, false, async tx => {
      const entry = await this.caseRow(tx, userId, caseId);
      if (!entry) return null;
      const row = (await tx.client.query(`SELECT response FROM ${S}.matches WHERE case_id=$1`, [caseId])).rows[0];
      if (!row || row.response.caseRevision !== entry.snapshot.revision) return null;
      check(row.response.caseId === caseId); return structuredClone(row.response);
    });
  }
  async loadFormAnswersForUser(userId: string, caseId: string, programId: string): Promise<SavedFormAnswerSet | null> {
    return this.transaction(userId, false, async tx => (await this.caseRow(tx, userId, caseId)) ? this.answers(tx, caseId, programId) : null);
  }
  async readFormAnswersIfCurrent(input: FormAnswerReadInput): Promise<FormAnswerReadResult> {
    const request = structuredClone(input);
    return this.transaction(request.userId, false, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== request.revision) return { status: 'conflict' };
      return { status: 'found', saved: await this.answers(tx, request.caseId, request.programId) };
    });
  }
  async saveFormAnswersIfCurrent(input: FormAnswerSaveInput): Promise<FormAnswerSaveResult> {
    const request = structuredClone(input), saved = parseSavedFormAnswers(request.answers);
    return this.transaction(request.userId, true, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId, true);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== request.revision) return { status: 'conflict' };
      const existing = await this.answers(tx, request.caseId, request.programId);
      if ((existing?.answerRevision ?? 0) !== request.expectedAnswerRevision) return { status: 'answers_conflict' };
      const caseRevision = next(entry.snapshot.revision);
      check(saved.caseId === request.caseId && saved.caseRevision === caseRevision && saved.programId === request.programId
        && saved.answerRevision === next(request.expectedAnswerRevision) && saved.updatedBy === request.userId
        && saved.answers.every(answer => answer.reviewedBy === null || answer.reviewedBy === request.userId)
        && (!existing || instantMicros(saved.updatedAt) >= instantMicros(existing.updatedAt)));
      await tx.client.query(`INSERT INTO ${S}.form_answers(case_id,program_id,answer_revision,record)
        VALUES($1,$2,$3,$4::jsonb) ON CONFLICT(case_id,program_id) DO UPDATE
        SET answer_revision=EXCLUDED.answer_revision,record=EXCLUDED.record`,
      [request.caseId, request.programId, saved.answerRevision, JSON.stringify(saved)]);
      await tx.client.query(`UPDATE ${S}.cases SET revision=$2,snapshot=$3::jsonb WHERE case_id=$1`,
        [request.caseId, caseRevision, JSON.stringify({ ...entry.snapshot, revision: caseRevision })]);
      await this.invalidateCase(tx, request.caseId);
      return { status: 'saved', saved, caseRevision };
    });
  }
  async createPacketIfCurrent(input: CreatePacketInput): Promise<CreatePacketResult> {
    const request = structuredClone(input);
    check(/^[A-Za-z0-9_-]{8,128}$/.test(request.generationKey));
    return this.transaction(request.userId, true, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId, true);
      if (!entry) return { status: 'not_found' };
      if (entry.snapshot.revision !== request.revision) return { status: 'conflict' };
      check(request.packet.caseId === request.caseId && request.packet.caseRevision === request.revision);
      const at = await this.clock(tx, request.checkedAt);
      const existing = (await tx.client.query(`SELECT packet,context_fingerprint FROM ${S}.packets
        WHERE case_id=$1 AND generation_key=$2`, [request.caseId, request.generationKey])).rows[0];
      if (existing) {
        if (existing.packet === null || existing.context_fingerprint !== request.contextFingerprint
          || !isPacketCurrent(existing.packet, at)) return { status: 'generation_conflict' };
        return { status: 'reused', packet: structuredClone(existing.packet) };
      }
      check(instantMicros(request.packet.generatedAt) <= instantMicros(at));
      if (request.packet.recheckAfter !== null && !isPacketCurrent(request.packet, at)) return { status: 'generation_conflict' };
      const count = (await tx.client.query(`SELECT count(*) AS count FROM ${S}.packets WHERE case_id=$1`, [request.caseId])).rows[0];
      if (integer(count.count, true) >= CAPACITY_LIMITS.packetsPerCase) return { status: 'quota_exceeded' };
      await tx.client.query(`INSERT INTO ${S}.packets(case_id,generation_key,packet_id,context_fingerprint,packet)
        VALUES($1,$2,$3,$4,$5::jsonb)`, [request.caseId, request.generationKey, request.packet.packetId,
        request.contextFingerprint, JSON.stringify(request.packet)]);
      return { status: 'saved', packet: request.packet };
    });
  }

  private descriptor(row: Row, caseId: string): EvidenceDescriptor {
    const descriptor = parseEvidenceDescriptor(row.descriptor);
    check(descriptor.caseId === caseId && descriptor.evidenceId === row.evidence_id
      && descriptor.findingId === row.finding_id && descriptor.evidenceRevision === integer(row.revision)
      && descriptor.preparedAt === row.prepared_at);
    return descriptor;
  }
  private async selected(tx: Tx, snapshot: CaseSnapshot, selections: EvidenceSelection[], bytes: boolean): Promise<
    { descriptors: EvidenceDescriptor[]; assets: EvidenceAsset[] } | EvidenceRepositoryFailure> {
    const descriptors: EvidenceDescriptor[] = [], assets: EvidenceAsset[] = [];
    for (const selection of selections) {
      const row = (await tx.client.query(`SELECT evidence_id,finding_id,revision,prepared_at,descriptor
        FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`, [snapshot.caseId, selection.evidenceId])).rows[0];
      if (!row || row.descriptor === null) return { status: 'evidence_conflict' };
      const descriptor = this.descriptor(row, snapshot.caseId);
      if (!linked(snapshot, descriptor, true) || descriptor.evidenceRevision !== selection.expectedEvidenceRevision) return { status: 'evidence_conflict' };
      descriptors.push(descriptor);
    }
    if (!exportEvidenceFitsBudget(descriptors)) return { status: 'selection_too_large' };
    if (bytes) for (const descriptor of descriptors) {
      const payload = await readPrivateBytea(tx.client, 'evidence', snapshot.caseId, descriptor.evidenceId, descriptor.byteLength);
      assets.push(await parseEvidenceAssetAsync({ descriptor, bytes: payload }));
    }
    return { descriptors, assets };
  }
  async readEvidenceCatalogForUser(userId: string, caseId: string): ReturnType<EvidenceRepository['readEvidenceCatalogForUser']> {
    return this.transaction(userId, false, async tx => {
      const entry = await this.caseRow(tx, userId, caseId);
      if (!entry) return { status: 'not_found' };
      const rows = (await tx.client.query(`SELECT evidence_id,finding_id,revision,prepared_at,descriptor
        FROM ${S}.evidence WHERE case_id=$1 AND descriptor IS NOT NULL ORDER BY evidence_id`, [caseId])).rows;
      const evidence = rows.map(row => this.descriptor(row, caseId)).filter(descriptor => linked(entry.snapshot, descriptor));
      return { status: 'found', catalog: { schemaVersion: '1', caseId, caseRevision: entry.snapshot.revision,
        catalogRevision: entry.catalogRevision, evidence } };
    });
  }
  async readEvidenceForUser(input: EvidenceReadInput): ReturnType<EvidenceRepository['readEvidenceForUser']> {
    const request = structuredClone(input);
    return this.transaction(request.userId, false, async tx => {
      const bound = await this.bound(tx, request);
      if ('status' in bound) return bound;
      const row = (await tx.client.query(`SELECT evidence_id,finding_id,revision,prepared_at,descriptor FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`,
        [request.caseId, request.evidenceId])).rows[0];
      if (!row || row.descriptor === null) return { status: 'not_found' };
      const descriptor = this.descriptor(row, request.caseId);
      if (!linked(bound.snapshot, descriptor)) return { status: 'not_found' };
      if (descriptor.evidenceRevision !== request.expectedEvidenceRevision) return { status: 'evidence_conflict' };
      const bytes = await readPrivateBytea(tx.client, 'evidence', request.caseId, request.evidenceId, descriptor.byteLength);
      return { status: 'found', asset: await parseEvidenceAssetAsync({ descriptor, bytes }) };
    });
  }
  async saveEvidenceIfCurrent(input: EvidenceSaveInput): ReturnType<EvidenceRepository['saveEvidenceIfCurrent']> {
    const { image: suppliedImage, ...binding } = input;
    const request = structuredClone(binding), image = await parseSanitizedEvidenceImageAsync(suppliedImage);
    check(evidenceIdentifier(request.evidenceId) && evidenceIdentifier(request.findingId)
      && evidenceRevision(request.expectedEvidenceRevision, true));
    return this.transaction(request.userId, true, async tx => {
      const bound = await this.bound(tx, request, true);
      if ('status' in bound) return bound;
      if (!linked(bound.snapshot, request)) return { status: 'not_found' };
      const existing = (await tx.client.query(`SELECT revision,finding_id,prepared_at,COALESCE(octet_length(bytes),0) AS size
        FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`, [request.caseId, request.evidenceId])).rows[0];
      const revision = existing ? integer(existing.revision) : 0;
      if (revision !== request.expectedEvidenceRevision || (existing && existing.finding_id !== request.findingId)) return { status: 'evidence_conflict' };
      const descriptor = parseEvidenceDescriptor({ evidenceId: request.evidenceId, evidenceRevision: next(revision),
        caseId: request.caseId, findingId: request.findingId, mediaType: image.mediaType, byteLength: image.byteLength,
        sha256: image.sha256, width: image.width, height: image.height, capturedAt: request.capturedAt,
        preparedAt: request.preparedAt, processingVersion: image.processingVersion });
      check(!existing || instantMicros(descriptor.preparedAt) >= instantMicros(existing.prepared_at));
      const catalogRevision = next(bound.catalogRevision), replaced = existing ? integer(existing.size, true) : 0;
      const freed = await this.exportBytes(tx, request.caseId);
      const owned = existing ? 0 : integer((await tx.client.query(`SELECT count(*) AS count FROM ${S}.evidence e
        JOIN ${S}.cases c ON c.case_id=e.case_id WHERE c.owner_id=$1`, [request.userId])).rows[0].count, true);
      if ((!existing && (tx.quota!.assets >= LIMITS.assets || owned >= CAPACITY_LIMITS.evidencePerOwner))
        || tx.quota!.bytes - freed - replaced + image.byteLength > LIMITS.bytes) return { status: 'quota_exceeded' };
      await tx.client.query(`INSERT INTO ${S}.evidence(case_id,evidence_id,finding_id,revision,prepared_at,descriptor,bytes)
        VALUES($1,$2,$3,$4,$5,$6::jsonb,$7) ON CONFLICT(case_id,evidence_id) DO UPDATE SET
        revision=EXCLUDED.revision,prepared_at=EXCLUDED.prepared_at,descriptor=EXCLUDED.descriptor,bytes=EXCLUDED.bytes`,
      [request.caseId, request.evidenceId, request.findingId, descriptor.evidenceRevision, descriptor.preparedAt,
        JSON.stringify(descriptor), Buffer.from(image.bytes.buffer, image.bytes.byteOffset, image.bytes.byteLength)]);
      await tx.client.query(`UPDATE ${S}.evidence_annotations SET record=jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(record,
        '{annotationRevision}',to_jsonb((record->>'annotationRevision')::bigint+1)),'{marks}','[]'::jsonb),'{reviewState}','"needs_review"'::jsonb),
        '{reviewedCaseRevision}','null'::jsonb),'{reviewedAt}','null'::jsonb),'{reviewedBy}','null'::jsonb) WHERE case_id=$1 AND evidence_id=$2`,[request.caseId,request.evidenceId]);
      await tx.client.query(`UPDATE ${S}.cases SET catalog_revision=$2 WHERE case_id=$1`, [request.caseId, catalogRevision]);
      await this.invalidateExports(tx, request.caseId);
      await this.quotaDelta(tx, 0, existing ? 0 : 1, 0, image.byteLength - replaced);
      return { status: 'saved', asset: { descriptor, bytes: image.bytes }, catalogRevision };
    });
  }
  async deleteEvidenceIfCurrent(input: EvidenceReadInput): ReturnType<EvidenceRepository['deleteEvidenceIfCurrent']> {
    const request = structuredClone(input);
    return this.transaction(request.userId, true, async tx => {
      const bound = await this.bound(tx, request, true);
      if ('status' in bound) return bound;
      const row = (await tx.client.query(`SELECT evidence_id,finding_id,revision,prepared_at,descriptor,octet_length(bytes) AS size
        FROM ${S}.evidence WHERE case_id=$1 AND evidence_id=$2`, [request.caseId, request.evidenceId])).rows[0];
      if (!row || row.descriptor === null) return { status: 'not_found' };
      const descriptor = this.descriptor(row, request.caseId);
      if (!linked(bound.snapshot, descriptor)) return { status: 'not_found' };
      if (descriptor.evidenceRevision !== request.expectedEvidenceRevision) return { status: 'evidence_conflict' };
      const evidenceRevision = next(descriptor.evidenceRevision), catalogRevision = next(bound.catalogRevision);
      await tx.client.query(`UPDATE ${S}.evidence SET revision=$3,descriptor=NULL,bytes=NULL WHERE case_id=$1 AND evidence_id=$2`,
        [request.caseId, request.evidenceId, evidenceRevision]);
      await tx.client.query(`UPDATE ${S}.evidence_annotations SET record=jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(record,
        '{annotationRevision}',to_jsonb((record->>'annotationRevision')::bigint+1)),'{marks}','[]'::jsonb),'{reviewState}','"needs_review"'::jsonb),
        '{reviewedCaseRevision}','null'::jsonb),'{reviewedAt}','null'::jsonb),'{reviewedBy}','null'::jsonb) WHERE case_id=$1 AND evidence_id=$2`,[request.caseId,request.evidenceId]);
      await tx.client.query(`UPDATE ${S}.cases SET catalog_revision=$2 WHERE case_id=$1`, [request.caseId, catalogRevision]);
      await this.invalidateExports(tx, request.caseId);
      await this.quotaDelta(tx, 0, 0, 0, -integer(row.size));
      return { status: 'deleted', evidenceRevision, catalogRevision };
    });
  }
  async loadExportSnapshotForUser(input: ExportSnapshotInput): ReturnType<EvidenceRepository['loadExportSnapshotForUser']> {
    const request = structuredClone(input), selections = parseEvidenceSelections(request.selections);
    return this.transaction(request.userId, false, async tx => {
      const bound = await this.bound(tx, request);
      if ('status' in bound) return bound;
      const selected = await this.selected(tx, bound.snapshot, selections, true);
      if ('status' in selected) return selected;
      const answers = await this.answers(tx, request.caseId, request.programId);
      return { status: 'found', snapshot: { snapshot: bound.snapshot, caseFingerprint: caseFingerprint(bound.snapshot),
        answers, answersFingerprint: formAnswersFingerprint(answers), catalogRevision: bound.catalogRevision, assets: selected.assets } };
    });
  }

  async loadExportReviewForUser(input: ExportSnapshotInput): ReturnType<EvidenceRepository['loadExportReviewForUser']> {
    const request = structuredClone(input), selections = parseEvidenceSelections(request.selections);
    return this.transaction(request.userId, false, async tx => {
      const bound = await this.bound(tx, request);
      if ('status' in bound) return bound;
      const selected = await this.selected(tx, bound.snapshot, selections, false);
      if ('status' in selected) return selected;
      const answers = await this.answers(tx, request.caseId, request.programId);
      return { status: 'found', snapshot: { snapshot: bound.snapshot, caseFingerprint: caseFingerprint(bound.snapshot),
        answers, answersFingerprint: formAnswersFingerprint(answers), catalogRevision: bound.catalogRevision,
        evidence: selected.descriptors } };
    });
  }

  private parseExport(row: Row, caseId: string, userId: string): ExportRow {
    const metadata = parseExportArtifactMetadata(row.metadata), bindings = structuredClone(row.bindings) as ExportBindings;
    check(metadata.caseId === caseId && metadata.artifactId === row.artifact_id && typeof row.invalidated === 'boolean'
      && evidenceInstant(row.last_checked_at) && bindings.userId === userId
      && bindings.revision === metadata.caseRevision && bindings.programId === metadata.programId
      && bindings.catalogRevision === metadata.evidenceCatalogRevision && bindings.contextFingerprint === metadata.exportContextId
      && /^[a-f0-9]{64}$/.test(bindings.caseFingerprint)
      && (bindings.answersFingerprint === null || /^[a-f0-9]{64}$/.test(bindings.answersFingerprint)));
    bindings.selections = parseEvidenceSelections(bindings.selections);
    check(bindings.selections.length === metadata.selectedEvidence.length
      && bindings.selections.every((selection, index) => selection.evidenceId === metadata.selectedEvidence[index].evidenceId
        && selection.expectedEvidenceRevision === metadata.selectedEvidence[index].evidenceRevision));
    return { artifactId: row.artifact_id, bindings, metadata, invalidated: row.invalidated,
      lastCheckedAt: row.last_checked_at, byteLength: integer(row.size, true) };
  }
  private async exportRow(tx: Tx, caseId: string, userId: string, column: 'artifact_id' | 'generation_key', value: string): Promise<ExportRow | 'compacted' | null> {
    const row = (await tx.client.query(`SELECT artifact_id,bindings,metadata,invalidated,last_checked_at,
      COALESCE(octet_length(bytes),0) AS size FROM ${S}.exports WHERE case_id=$1 AND ${column}=$2`, [caseId, value])).rows[0];
    if (row && row.metadata === null && row.bindings === null && row.invalidated === true && integer(row.size, true) === 0) return 'compacted';
    return row ? this.parseExport(row, caseId, userId) : null;
  }
  private async bindingsCurrent(tx: Tx, entry: CaseRow, saved: ExportRow): Promise<EvidenceRepositoryFailure | null> {
    if (entry.snapshot.revision !== saved.bindings.revision || caseFingerprint(entry.snapshot) !== saved.bindings.caseFingerprint) return { status: 'conflict' };
    if (entry.catalogRevision !== saved.bindings.catalogRevision) return { status: 'evidence_conflict' };
    const answers = await this.answers(tx, entry.snapshot.caseId, saved.bindings.programId);
    if (formAnswersFingerprint(answers) !== saved.bindings.answersFingerprint) return { status: 'answers_conflict' };
    if (saved.invalidated) return { status: 'expired' };
    const selected = await this.selected(tx, entry.snapshot, saved.bindings.selections, false);
    if ('status' in selected) return selected;
    check(selected.descriptors.every((descriptor, index) => descriptor.sha256 === saved.metadata.selectedEvidence[index].sha256
      && descriptor.findingId === saved.metadata.selectedEvidence[index].findingId));
    return null;
  }
  private async checkExportClock(tx: Tx, saved: ExportRow, at: string): Promise<boolean> {
    if (instantMicros(at) < instantMicros(saved.lastCheckedAt)) return false;
    const current = exportCurrent(saved.metadata, at);
    await tx.client.query(`UPDATE ${S}.exports SET last_checked_at=$2,
      invalidated=invalidated OR $3,bytes=CASE WHEN $3 THEN NULL ELSE bytes END WHERE artifact_id=$1`,
    [saved.artifactId, at, !current]);
    if (!current && saved.byteLength) {
      await this.quotaDelta(tx, 0, 0, -1, -saved.byteLength);
      saved.byteLength = 0; saved.invalidated = true;
    }
    return current;
  }
  async publishExportIfCurrent(input: ExportPublishInput): ReturnType<EvidenceRepository['publishExportIfCurrent']> {
    const request = structuredClone(input), selections = parseEvidenceSelections(request.selections);
    const metadata = parseExportArtifactMetadata(request.artifact.metadata), bytes = request.artifact.bytes;
    validatePdf(bytes, metadata);
    check(/^[a-f0-9]{64}$/.test(request.contextFingerprint) && /^[A-Za-z0-9_-]{8,128}$/.test(request.generationKey)
      && evidenceInstant(request.checkedAt));
    return this.transaction(request.userId, true, async tx => {
      const bound = await this.bound(tx, request, true);
      if ('status' in bound) return bound;
      if (caseFingerprint(bound.snapshot) !== request.expectedCaseFingerprint) return { status: 'conflict' };
      const selected = await this.selected(tx, bound.snapshot, selections, false);
      if ('status' in selected) return selected;
      const answers = await this.answers(tx, request.caseId, request.programId);
      if (formAnswersFingerprint(answers) !== request.expectedAnswersFingerprint) return { status: 'answers_conflict' };
      check(metadata.caseId === request.caseId && metadata.caseRevision === request.revision && metadata.programId === request.programId
        && metadata.evidenceCatalogRevision === request.expectedCatalogRevision && metadata.answerRevision === (answers?.answerRevision ?? 0)
        && metadata.exportContextId === request.contextFingerprint);
      if (answers !== null && (answers.caseRevision !== request.revision || answers.updatedBy !== request.userId
        || answers.answers.some(answer => answer.reviewedBy !== null && answer.reviewedBy !== request.userId)
        || answers.formContextId !== metadata.formContextId || answers.formVersion !== metadata.formVersion
        || answers.mappingVersion !== metadata.mappingVersion || instantMicros(answers.updatedAt) > instantMicros(metadata.generatedAt))) return { status: 'answers_conflict' };
      check(metadata.selectedEvidence.length === selected.descriptors.length && selected.descriptors.every((descriptor, index) => {
        const included = metadata.selectedEvidence[index];
        return included.evidenceId === descriptor.evidenceId && included.evidenceRevision === descriptor.evidenceRevision
          && included.findingId === descriptor.findingId && included.sha256 === descriptor.sha256
          && included.reviewedBy === request.userId && included.reviewedAt === metadata.generatedAt;
      }));
      const at = await this.clock(tx, request.checkedAt);
      check(instantMicros(metadata.generatedAt) <= instantMicros(at));
      if (!exportCurrent(metadata, at)) return { status: 'expired' };
      const existing = await this.exportRow(tx, request.caseId, request.userId, 'generation_key', request.generationKey);
      if (existing === 'compacted') return { status: 'generation_conflict' };
      if (existing) {
        if (existing.invalidated || existing.bindings.contextFingerprint !== request.contextFingerprint
          || existing.bindings.caseFingerprint !== request.expectedCaseFingerprint || existing.bindings.catalogRevision !== request.expectedCatalogRevision
          || existing.bindings.answersFingerprint !== request.expectedAnswersFingerprint || existing.bindings.programId !== request.programId
          || canonicalJson(existing.bindings.selections) !== canonicalJson(selections)
          || !await this.checkExportClock(tx, existing, at)) return { status: 'generation_conflict' };
        return { status: 'reused', artifact: existing.metadata };
      }
      const count = (await tx.client.query(`SELECT count(*) AS count FROM ${S}.exports WHERE case_id=$1`, [request.caseId])).rows[0];
      if (integer(count.count, true) >= CAPACITY_LIMITS.exportsPerCase
        || tx.quota!.artifacts >= LIMITS.artifacts || tx.quota!.bytes + bytes.byteLength > LIMITS.bytes) return { status: 'quota_exceeded' };
      const bindings: ExportBindings = { userId: request.userId, revision: request.revision, caseFingerprint: request.expectedCaseFingerprint,
        programId: request.programId, catalogRevision: request.expectedCatalogRevision, answersFingerprint: request.expectedAnswersFingerprint,
        contextFingerprint: request.contextFingerprint, selections };
      await tx.client.query(`INSERT INTO ${S}.exports(artifact_id,case_id,generation_key,bindings,metadata,bytes,last_checked_at,expires_at)
        VALUES($1,$2,$3,$4::jsonb,$5::jsonb,$6,$7,$8::timestamptz)`, [metadata.artifactId, request.caseId, request.generationKey,
        JSON.stringify(bindings), JSON.stringify(metadata), Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), at, metadata.expiresAt]);
      await this.quotaDelta(tx, 0, 0, 1, bytes.byteLength);
      return { status: 'saved', artifact: metadata };
    });
  }
  async readExportForUser(input: ExportReadInput): ReturnType<EvidenceRepository['readExportForUser']> {
    const request = structuredClone(input);
    return this.transaction(request.userId, false, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId);
      if (!entry) return { status: 'not_found' };
      const saved = await this.exportRow(tx, request.caseId, request.userId, 'artifact_id', request.artifactId);
      if (!saved) return { status: 'not_found' };
      if (saved === 'compacted') return { status: 'expired' };
      const stale = await this.bindingsCurrent(tx, entry, saved);
      return stale ?? { status: 'found', artifact: saved.metadata };
    });
  }
  async readExportForUserIfCurrent(input: ExportCurrentReadInput): ReturnType<EvidenceRepository['readExportForUserIfCurrent']> {
    return this.currentExport(input, true);
  }
  async reviewExportForUserIfCurrent(input: ExportCurrentReadInput): ReturnType<EvidenceRepository['reviewExportForUserIfCurrent']> {
    return this.currentExport(input, false);
  }
  private currentExport(input: ExportCurrentReadInput, includeBytes: true): ReturnType<EvidenceRepository['readExportForUserIfCurrent']>;
  private currentExport(input: ExportCurrentReadInput, includeBytes: false): ReturnType<EvidenceRepository['reviewExportForUserIfCurrent']>;
  private async currentExport(input: ExportCurrentReadInput, includeBytes: boolean): Promise<
    { status: 'found'; artifact: PrivateExportArtifact | ExportArtifactMetadata } | EvidenceRepositoryFailure> {
    const request = structuredClone(input);
    return this.transaction(request.userId, true, async tx => {
      const entry = await this.caseRow(tx, request.userId, request.caseId, true);
      if (!entry) return { status: 'not_found' };
      const saved = await this.exportRow(tx, request.caseId, request.userId, 'artifact_id', request.artifactId);
      if (!saved) return { status: 'not_found' };
      if (saved === 'compacted') return { status: 'expired' };
      const stale = await this.bindingsCurrent(tx, entry, saved);
      if (stale) return stale;
      if (saved.bindings.contextFingerprint !== request.contextFingerprint) return { status: 'generation_conflict' };
      const at = await this.clock(tx, request.checkedAt);
      if (!await this.checkExportClock(tx, saved, at)) return { status: 'expired' };
      check(saved.byteLength === saved.metadata.byteLength);
      let bytes: Uint8Array | undefined;
      if (includeBytes) {
        bytes = await readPrivateBytea(tx.client, 'exports', request.caseId, request.artifactId, saved.metadata.byteLength);
        validatePdf(bytes, saved.metadata);
      }
      const after = await this.clock(tx, at);
      if (!await this.checkExportClock(tx, saved, after)) return { status: 'expired' };
      return { status: 'found', artifact: bytes === undefined ? saved.metadata : { metadata: saved.metadata, bytes } };
    });
  }
}
