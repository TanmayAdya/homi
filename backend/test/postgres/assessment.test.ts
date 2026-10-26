import assert from 'node:assert/strict';
import { after, before, beforeEach, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { create, draft, imageInput, OWNER, OTHER, iso } from './fixtures.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { caseFingerprint } from '../../src/evidence/validation.ts';
import type { CaseSnapshot } from '../../src/types.ts';
import type { AssessmentSave } from '../../src/assessment/metadata.ts';
import { captureDatabaseBackup, restoreDatabaseBackup } from '../../src/storage/database-backup.ts';
import { intakeDefinition } from '../../src/programs/intake.ts';

let cluster: TestPostgres, target: TestPostgres, admin: Pool, runtime: Pool, targetAdmin: Pool, targetRuntime: Pool;
let repo: PostgresCaseRepository;
const names = ['case_scan_models','share_sensitive','case_shares','assessment_metadata','evidence_annotations','program_intake','cases','matches','packets','form_answers','evidence','exports','request_history','deleted_cases','closed_accounts','account_deletion_previews','auth_deletion_jobs'];
before(async()=>{
 [cluster,target]=await Promise.all([TestPostgres.start(),TestPostgres.start()]);
 admin=cluster.pool();targetAdmin=target.pool();
 for(const pool of [admin,targetAdmin]){
  await applyMigrations(pool);
  await pool.query('CREATE ROLE assessment_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
 }
 runtime=cluster.pool('assessment_runtime');targetRuntime=target.pool('assessment_runtime');repo=new PostgresCaseRepository(runtime);
});
beforeEach(async()=>{
 for(const pool of [admin,targetAdmin]) await pool.query(`TRUNCATE ${names.map(n=>`safeathome_private.${n}`).join(',')}; UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);
});
after(async()=>{await Promise.all([cluster?.close(),target?.close()]);});
function assessment(snapshot:CaseSnapshot):AssessmentSave{
 const {revision,...replacement}=structuredClone(snapshot);
 replacement.findings[0].measurements=[{type:'clear width',value:254,unit:'mm',method:'manual',confirmed:true}];
 return {schemaVersion:'2',caseId:snapshot.caseId,expectedCaseRevision:revision,expectedCaseFingerprint:caseFingerprint(snapshot),
  expectedCatalogRevision:0,expectedAssessmentRevision:0,mutationId:'assessment-write-01',draft:replacement,
  metadata:{measurements:[{findingId:'fictional-finding',type:'clear width',originalText:' 0010.0 ',originalUnit:'in',decimalSeparator:'point',source:'manual',recorder:'self',recordedAt:null}],
   reviews:[{findingId:'fictional-finding',state:'confirmed',note:null}]}};
}
async function annotation(snapshot:CaseSnapshot){
 const uploaded=await repo.saveEvidenceIfCurrent(await imageInput(snapshot));assert.equal(uploaded.status,'saved');if(uploaded.status!=='saved')throw Error();
 const d=uploaded.asset.descriptor;
 return {schemaVersion:'2' as const,caseId:snapshot.caseId,expectedCaseRevision:snapshot.revision,expectedCatalogRevision:1,
  evidenceId:d.evidenceId,expectedEvidenceRevision:d.evidenceRevision,expectedAnnotationRevision:0,
  expectedImageSha256:d.sha256,expectedImageWidth:d.width,expectedImageHeight:d.height,
  marks:[{id:'box-one',rect:[100000,100000,300000,300000] as [number,number,number,number],label:'Fictional observed area'}],reviewedForExport:true};
}
test('concurrent assessment saves have one writer; exact retry is acknowledged after later case revisions',async()=>{
 const snapshot=await create(repo),input=assessment(snapshot),other=new PostgresCaseRepository(cluster.pool('assessment_runtime'));
 const outcomes=await Promise.all([repo.saveAssessmentForUser(OWNER,input,iso()),other.saveAssessmentForUser(OWNER,{...input,mutationId:'assessment-write-02'},iso())]);
 assert.deepEqual(outcomes.map(x=>x.status).sort(),['conflict','found']);
 const winner=outcomes[0].status==='found'?input:{...input,mutationId:'assessment-write-02'};
 assert.equal((await repo.readAssessmentForUser(OTHER,snapshot.caseId)).status,'not_found');
 assert.equal((await repo.replaceIfCurrent(OWNER,snapshot.caseId,2,{...input.draft,profile:{...input.draft.profile,city:'Updated'}})).status,'saved');
 const retry=await repo.saveAssessmentForUser(OWNER,winner,iso());assert.equal(retry.status,'found');if(retry.status!=='found')return;
 assert.equal(retry.state.case.revision,3);assert.equal(retry.state.assessment.caseRevision,2);assert.equal(retry.state.acknowledgedMutationId,winner.mutationId);
 assert.equal(retry.state.assessment.metadata.measurements[0].originalText,' 0010.0 ');assert.equal(retry.state.assessment.history.length,1);
 assert.equal((await repo.saveAssessmentForUser(OWNER,{...winner,metadata:{...winner.metadata,reviews:[{findingId:'fictional-finding',state:'confirmed',note:'Changed'}]}},iso())).status,'mutation_conflict');
});
test('history capacity fails before any case mutation and annotations require owner and canonical image bindings',async()=>{
 const snapshot=await create(repo),input=assessment(snapshot),at=iso();
 const record={schemaVersion:'2',caseId:snapshot.caseId,caseRevision:501,assessmentRevision:500,metadata:{measurements:[],reviews:[]},history:Array.from({length:500},(_,i)=>({mutationId:`historical-${i.toString().padStart(4,'0')}`,requestHash:'a'.repeat(64),caseRevision:i+2,assessmentRevision:i+1,recordedAt:at,recordedBy:OWNER,changes:[]}))};
 const current={...snapshot,revision:501};await admin.query('UPDATE safeathome_private.cases SET revision=501,snapshot=$2 WHERE case_id=$1',[snapshot.caseId,JSON.stringify(current)]);
 await admin.query('INSERT INTO safeathome_private.assessment_metadata VALUES($1,$2)',[snapshot.caseId,JSON.stringify(record)]);
 assert.equal((await repo.saveAssessmentForUser(OWNER,{...input,expectedCaseRevision:501,expectedCaseFingerprint:caseFingerprint(current),expectedAssessmentRevision:500},iso())).status,'history_limit');
 assert.deepEqual(await repo.loadForUser(OWNER,snapshot.caseId),current);
 const request=await annotation(current);
 assert.equal((await repo.saveAnnotationsForUser(OTHER,request,iso())).status,'not_found');
 assert.equal((await repo.saveAnnotationsForUser(OWNER,{...request,expectedImageWidth:request.expectedImageWidth+1},iso())).status,'evidence_conflict');
 assert.equal((await repo.saveAnnotationsForUser(OWNER,request,iso())).status,'found');
 const client=await runtime.connect();try{await client.query('BEGIN');await client.query("SELECT set_config('safeathome.user_id',$1,true)",[OTHER]);
  for(const table of ['assessment_metadata','evidence_annotations'])assert.equal((await client.query(`SELECT * FROM safeathome_private.${table}`)).rowCount,0);
 }finally{await client.query('ROLLBACK');client.release();}
 const replacement=await imageInput(current,2,'fictional-photo-a',1);assert.equal((await repo.saveEvidenceIfCurrent(replacement)).status,'saved');
 const {expectedAnnotationRevision,expectedImageSha256,expectedImageWidth,expectedImageHeight,marks,reviewedForExport,...read}=request;
 const result=await repo.readAnnotationsForUser(OWNER,{...read,expectedCatalogRevision:3,expectedEvidenceRevision:2});assert.equal(result.status,'found');if(result.status==='found'){
  assert.equal(result.state.annotation.annotationRevision,2);assert.deepEqual(result.state.annotation.marks,[]);assert.equal(result.state.annotation.reviewState,'needs_review');
 }
});
test('quarantine restore retains metadata and overlays, revokes annotation review, and case deletion purges all sidecars',async()=>{
 const initial=await create(repo),input=assessment(initial);
 assert.equal((await repo.saveAssessmentForUser(OWNER,input,iso())).status,'found');let snapshot=(await repo.loadForUser(OWNER,initial.caseId))!;
 const definition=intakeDefinition('hpsm-eaa')!;
 assert.equal((await repo.saveProgramIntakeIfCurrent({userId:OWNER,caseId:snapshot.caseId,revision:2,programId:definition.programId,expectedIntakeRevision:0,
  intake:{schemaVersion:'2',caseId:snapshot.caseId,caseRevision:3,programId:definition.programId,questionnaireVersion:definition.questionnaireVersion,intakeRevision:1,updatedAt:iso(),updatedBy:OWNER,
   answers:[{key:'activeMembershipReported',value:null,reviewState:'unknown'}]}})).status,'saved');
 snapshot=(await repo.loadForUser(OWNER,snapshot.caseId))!;const request=await annotation(snapshot);
 assert.equal((await repo.saveAnnotationsForUser(OWNER,request,iso())).status,'found');
 const origin='https://fictional-project.supabase.co';const archive=await captureDatabaseBackup(admin,origin);
 await restoreDatabaseBackup(targetAdmin,archive,origin);await assert.rejects(new PostgresCaseRepository(targetRuntime).readAssessmentForUser(OWNER,snapshot.caseId));const restored=new PostgresCaseRepository(targetAdmin);
 assert.deepEqual(await restored.readAssessmentForUser(OWNER,snapshot.caseId),await repo.readAssessmentForUser(OWNER,snapshot.caseId));
 const restoredRecord=(await targetAdmin.query('SELECT record FROM safeathome_private.evidence_annotations')).rows[0].record;
 assert.deepEqual(restoredRecord.marks,request.marks);assert.equal(restoredRecord.reviewState,'needs_review');assert.equal(restoredRecord.reviewedBy,null);
 assert.equal((await restored.readProgramIntakeIfCurrent({userId:OWNER,caseId:snapshot.caseId,revision:3,programId:definition.programId})).status,'found');
 assert.equal((await restored.deleteCaseIfCurrent({userId:OWNER,caseId:snapshot.caseId,revision:3,expectedCatalogRevision:2})).status,'deleted');
 for(const name of ['assessment_metadata','evidence_annotations','program_intake'])assert.equal((await targetAdmin.query(`SELECT count(*) AS count FROM safeathome_private.${name}`)).rows[0].count,'0');
});
