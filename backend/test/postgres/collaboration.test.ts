import assert from 'node:assert/strict';
import { randomUUID,randomBytes,createHash } from 'node:crypto';
import { before,beforeEach,after,test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { OWNER,create } from './fixtures.ts';
import { demoProgram } from '../../fixtures/demo-program.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { PostgresSharingRepository } from '../../src/sharing/postgres-sharing-repository.ts';
import { parseCollaborationRecord } from '../../src/sharing/collaboration.ts';
import { parseProgressRecord,programReports,type NextStepTask } from '../../src/tracking/progress.ts';
import type { SharingRoute,SharingRequest,SharingResult } from '../../src/sharing/contracts.ts';
import { captureDatabaseBackup,restoreDatabaseBackup,validateDatabaseBackup } from '../../src/storage/database-backup.ts';
const HELPER='33333333-3333-4333-8333-333333333333',VIEWER='22222222-2222-4222-8222-222222222222',OTHER='44444444-4444-4444-8444-444444444444';
let cluster:TestPostgres,target:TestPostgres,admin:Pool,runtime:Pool,cases:PostgresCaseRepository,sharing:PostgresSharingRepository;
before(async()=>{cluster=await TestPostgres.start();admin=cluster.pool();await applyMigrations(admin);await admin.query('CREATE ROLE collaboration_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');runtime=cluster.pool('collaboration_runtime');cases=new PostgresCaseRepository(runtime);sharing=new PostgresSharingRepository(runtime,async()=>[demoProgram]);});
beforeEach(async()=>{await admin.query('TRUNCATE safeathome_private.cases,safeathome_private.deleted_cases,safeathome_private.closed_accounts,safeathome_private.account_deletion_previews,safeathome_private.auth_deletion_jobs CASCADE; UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0');});
after(async()=>{await target?.close();await cluster?.close();});
const call=(userId:string,route:SharingRoute,fields:Record<string,unknown>,hash?:string)=>sharing.execute(userId,route,{schemaVersion:'3',...fields} as SharingRequest,hash);
function ok(r:SharingResult){assert.equal(r.status,'ok');if(r.status!=='ok')throw Error();return r.data as any;}
async function seed(recipient=HELPER,role='helper'){
 const snapshot=await create(cases);
 const task:NextStepTask={id:'assigned-task',programId:null,findingId:'fictional-finding',formId:null,title:'Fictional selected next step',kind:'room_review',state:'pending',responsiblePerson:'Family label only',dueOn:null,basedOnCaseRevision:1,basedOnRuleVersion:null,revision:1,sourceEventId:null};
 const saved=await cases.saveProgressForUser(OWNER,{schemaVersion:'3',caseId:snapshot.caseId,expectedCaseRevision:1,expectedProgressRevision:0,mutationId:randomUUID(),operation:{type:'put_task',task,expectedTaskRevision:0}},new Date().toISOString(),[demoProgram]);assert.equal(saved.status,'found');
 assert.equal((await cases.saveProgressForUser(OWNER,{schemaVersion:'3',caseId:snapshot.caseId,expectedCaseRevision:1,expectedProgressRevision:1,mutationId:randomUUID(),operation:{type:'track_program',programId:demoProgram.programId}},new Date().toISOString(),[demoProgram])).status,'found');
 const code=randomBytes(32).toString('base64url'),hash=createHash('sha256').update(code).digest('hex'),membershipId=randomUUID();
 ok(await call(OWNER,'create-invitation',{caseId:snapshot.caseId,expectedCaseRevision:1,invitationId:membershipId,recipientId:recipient,role,scope:{findingIds:['fictional-finding'],programIds:[demoProgram.programId],allowHelperNotes:role==='helper'},expiresAt:null},hash));
 ok(await call(recipient,'accept-invitation',{code,expectedPermissionRevision:1},hash));
 return {caseId:snapshot.caseId,membershipId,expectedPermissionRevision:2,task};
}
async function read(s:Awaited<ReturnType<typeof seed>>,user=OWNER,revision=3){return ok(await call(user,'read-collaboration',{membershipId:s.membershipId,expectedPermissionRevision:revision}));}
const configure=(s:Awaited<ReturnType<typeof seed>>,extra:Record<string,unknown>={})=>({membershipId:s.membershipId,expectedPermissionRevision:2,expectedCaseRevision:1,expectedProgressRevision:2,expectedCollaborationRevision:0,mutationId:randomUUID(),collaborationScope:{taskIds:['assigned-task'],allowTaskProgress:true,allowStatusProposals:true},assignedTaskIds:['assigned-task'],...extra});
const update=(s:Awaited<ReturnType<typeof seed>>,extra:Record<string,unknown>={})=>({membershipId:s.membershipId,expectedPermissionRevision:3,expectedCaseRevision:1,expectedCollaborationRevision:1,mutationId:randomUUID(),taskId:'assigned-task',expectedTaskRevision:1,state:'completed',...extra});
const proposal=(s:Awaited<ReturnType<typeof seed>>,extra:Record<string,unknown>={})=>({membershipId:s.membershipId,expectedPermissionRevision:3,expectedCaseRevision:1,expectedCollaborationRevision:1,mutationId:randomUUID(),programId:demoProgram.programId,update:{updateId:randomUUID(),status:'submitted',occurredOn:new Date().toISOString().slice(0,10),source:'self_report',note:'Fictional proposal, not an agency report',nextAction:null,responsibleParty:null,followUpOn:null},...extra});
test('explicit signed-in assignment updates the canonical task once and never marks a concern addressed',async()=>{
 const s=await seed(),request=configure(s),configured=ok(await call(OWNER,'configure-collaboration',request));
 assert.equal(configured.permissionRevision,3);assert.deepEqual(ok(await call(OWNER,'configure-collaboration',request)),configured);
 const before=await read(s,HELPER);
 const audit=(await admin.query('SELECT audit FROM safeathome_private.case_shares WHERE membership_id=$1',[s.membershipId])).rows[0].audit.events;
 assert.ok(audit.some((event:any)=>event.type==='read' && event.actorId===HELPER));
 assert.equal(before.tasks[0].assigneeUserId,HELPER);assert.equal(before.tasks[0].responsiblePerson,'Family label only');
 const mutation=update(s),saved=ok(await call(HELPER,'update-shared-task',mutation));assert.equal(saved.tasks[0].state,'completed');assert.equal(saved.tasks[0].revision,2);
 assert.deepEqual(ok(await call(HELPER,'update-shared-task',mutation)),saved);
 const row=(await admin.query('SELECT progress,collaboration,home_safety FROM safeathome_private.cases WHERE case_id=$1',[s.caseId])).rows[0];
 const progress=parseProgressRecord(row.progress);parseCollaborationRecord(row.collaboration);assert.equal(progress.tasks[0].state,'completed');assert.equal(progress.events.at(-1)!.recordedBy,HELPER);assert.equal(row.home_safety,null);
 assert.equal((await call(HELPER,'update-shared-task',{...mutation,state:'blocked'})).status,'conflict');
});
test('viewers, unrelated, unassigned and out-of-scope accounts cannot write task progress or proposals',async()=>{
 const viewer=await seed(VIEWER,'viewer');
 assert.equal((await call(OWNER,'configure-collaboration',configure(viewer))).status,'invalid_request');
 const s=await seed();ok(await call(OWNER,'configure-collaboration',configure(s,{assignedTaskIds:[]})));
 for(const actor of [VIEWER,OTHER])for(const route of ['read-collaboration','update-shared-task','propose-shared-status'] as const){
  const fields=route==='read-collaboration'?{membershipId:s.membershipId,expectedPermissionRevision:3}:route==='update-shared-task'?update(s):proposal(s);
  assert.equal((await call(actor,route,fields)).status,'not_found');
 }
 assert.equal((await call(HELPER,'update-shared-task',update(s))).status,'not_found');
 assert.equal((await call(HELPER,'propose-shared-status',proposal(s,{programId:'unselected-program'}))).status,'not_found');
 assert.equal((await call(HELPER,'configure-collaboration',configure(s,{expectedPermissionRevision:3,expectedCollaborationRevision:1}))).status,'not_found');
});
test('helper status remains pending; only owner review appends the reported status with both actors retained',async()=>{
 const s=await seed();ok(await call(OWNER,'configure-collaboration',configure(s)));
 const request=proposal(s),proposed=ok(await call(HELPER,'propose-shared-status',request));assert.equal(proposed.proposals[0].state,'pending');assert.equal(proposed.progressRevision,2);
 const current=await cases.readProgressForUser(OWNER,s.caseId);assert.equal(current.status,'found');if(current.status!=='found')throw Error();assert.equal(programReports(current.context,demoProgram.programId).length,0);
 const review={membershipId:s.membershipId,expectedPermissionRevision:3,expectedCaseRevision:1,expectedProgressRevision:2,expectedCollaborationRevision:2,proposalId:request.mutationId,decision:'accepted',mutationId:randomUUID()};
 assert.equal((await call(HELPER,'review-shared-status',review)).status,'not_found');
 const accepted=ok(await call(OWNER,'review-shared-status',review));assert.equal(accepted.proposals[0].proposedBy,HELPER);assert.equal(accepted.proposals[0].reviewedBy,OWNER);assert.equal(accepted.proposals[0].state,'accepted');assert.equal(accepted.progressRevision,3);
 assert.deepEqual(ok(await call(OWNER,'review-shared-status',review)),accepted);
 const loaded=await cases.readProgressForUser(OWNER,s.caseId);if(loaded.status!=='found')throw Error();const reports=programReports(loaded.context,demoProgram.programId);assert.equal(reports[0].status,'submitted');assert.equal(reports[0].recordedBy,OWNER);parseProgressRecord(loaded.context.record);
});
test('rejection has its own event and never changes the reported program status',async()=>{
 const s=await seed();ok(await call(OWNER,'configure-collaboration',configure(s)));const p=proposal(s);ok(await call(HELPER,'propose-shared-status',p));
 const rejected=ok(await call(OWNER,'review-shared-status',{membershipId:s.membershipId,expectedPermissionRevision:3,expectedCaseRevision:1,expectedProgressRevision:2,expectedCollaborationRevision:2,proposalId:p.mutationId,decision:'rejected',mutationId:randomUUID()}));
 assert.equal(rejected.progressRevision,2);assert.equal(rejected.proposals[0].state,'rejected');assert.equal(rejected.proposals[0].reviewedBy,OWNER);
});
test('changed task contents remain private and stale; reassignment and permission changes fence old writes',async()=>{
 const s=await seed();ok(await call(OWNER,'configure-collaboration',configure(s)));
 const state=await cases.readProgressForUser(OWNER,s.caseId);if(state.status!=='found')throw Error();
 assert.equal((await cases.saveProgressForUser(OWNER,{schemaVersion:'3',caseId:s.caseId,expectedCaseRevision:1,expectedProgressRevision:2,mutationId:randomUUID(),operation:{type:'put_task',task:{...s.task,title:'New private owner wording',revision:2},expectedTaskRevision:1}},new Date().toISOString(),[demoProgram])).status,'found');
 const shared=await read(s,HELPER);assert.equal(shared.tasks[0].title,'Fictional selected next step');assert.equal(shared.tasks[0].needsReview,true);assert.ok(!JSON.stringify(shared).includes('New private owner wording'));
 assert.equal((await call(HELPER,'update-shared-task',update(s,{expectedTaskRevision:2}))).status,'conflict');
 ok(await call(OWNER,'change-sharing',{caseId:s.caseId,expectedCaseRevision:1,invitationId:s.membershipId,expectedPermissionRevision:3,role:'helper',scope:{findingIds:[],programIds:[],allowHelperNotes:true},expiresAt:null}));
 const hidden=await read(s,HELPER,4);assert.deepEqual(hidden.tasks,[]);assert.equal(hidden.scope.allowStatusProposals,false);
});
test('revocation serializes before a later helper write; pending/expired grants are denied',async()=>{
 const s=await seed();ok(await call(OWNER,'configure-collaboration',configure(s)));
 const c=await admin.connect();await c.query('BEGIN');await c.query('SELECT singleton FROM safeathome_private.repository_quota FOR UPDATE');
 const revoking=call(OWNER,'revoke-sharing',{caseId:s.caseId,invitationId:s.membershipId,expectedPermissionRevision:3});
 await new Promise(r=>setTimeout(r,30));const writing=call(HELPER,'update-shared-task',update(s));await c.query('COMMIT');c.release();assert.equal((await revoking).status,'ok');assert.equal((await writing).status,'not_found');
 const row=(await admin.query('SELECT collaboration_scope FROM safeathome_private.case_shares')).rows[0];assert.deepEqual(row.collaboration_scope.taskSnapshots,[]);
});
test('deletion previews include collaboration; RLS hides the sidecar and quarantine restore cannot restore assignments',async()=>{
 const s=await seed();const tokenHash=createHash('sha256').update('collaboration-delete').digest('hex');await cases.prepareAccountDeletion({userId:OWNER,tokenHash});ok(await call(OWNER,'configure-collaboration',configure(s)));assert.equal((await cases.confirmAccountDeletion({userId:OWNER,tokenHash})).status,'changed');
 const c=await runtime.connect();try{await c.query('BEGIN');await c.query("SELECT set_config('safeathome.user_id',$1,true)",[HELPER]);assert.equal((await c.query('SELECT collaboration FROM safeathome_private.cases')).rowCount,0);await c.query('ROLLBACK');}finally{c.release();}
 const origin='https://fictional-collaboration.supabase.co',archive=await captureDatabaseBackup(admin,origin);await validateDatabaseBackup(archive,origin);
 target=await TestPostgres.start();const targetAdmin=target.pool();await applyMigrations(targetAdmin);await restoreDatabaseBackup(targetAdmin,archive,origin);
 const restored=(await targetAdmin.query('SELECT collaboration FROM safeathome_private.cases')).rows[0].collaboration;assert.deepEqual(restored.assignments,[]);
 const grant=(await targetAdmin.query('SELECT revoked,collaboration_scope FROM safeathome_private.case_shares')).rows[0];assert.equal(grant.revoked,true);assert.deepEqual(grant.collaboration_scope.taskSnapshots,[]);
 assert.equal((await cases.deleteCaseIfCurrent({userId:OWNER,caseId:s.caseId,revision:1,expectedCatalogRevision:0})).status,'deleted');
});

test('expired and closed recipients lose collaboration operations while owner data survives',async()=>{
 const s=await seed();ok(await call(OWNER,'configure-collaboration',configure(s)));
 await admin.query("UPDATE safeathome_private.case_shares SET expires_at=clock_timestamp()-interval '1 second' WHERE membership_id=$1",[s.membershipId]);
 assert.equal((await call(HELPER,'read-collaboration',{membershipId:s.membershipId,expectedPermissionRevision:3})).status,'not_found');
 assert.equal((await call(HELPER,'update-shared-task',update(s))).status,'not_found');
 const hash=createHash('sha256').update('closed-recipient').digest('hex');await cases.prepareAccountDeletion({userId:HELPER,tokenHash:hash});assert.equal((await cases.confirmAccountDeletion({userId:HELPER,tokenHash:hash})).status,'confirmed');
 assert.equal((await admin.query('SELECT case_id FROM safeathome_private.cases WHERE case_id=$1',[s.caseId])).rowCount,1);
 assert.equal((await call(HELPER,'propose-shared-status',proposal(s)).catch(()=>({status:'closed'}))).status,'closed');
});
test('new source metadata and imported referral notes are absent from frozen shared task DTOs',async()=>{
 const s=await seed();
 const original={id:'local-source',providerId:'referral-211-national',title:'Original private follow-up',responsible:'Private source label',dueDate:null,findingId:null,createdAt:new Date().toISOString(),completedAt:null};
 const referral={providerId:original.providerId,imported:{sourceTaskId:original.id,sourceHash:createHash('sha256').update((await import('../../src/evidence/validation.ts')).canonicalJson(original)).digest('hex'),contactNote:'Fictional PRIVATE imported note',original}};
 await admin.query("UPDATE safeathome_private.cases SET progress=jsonb_set(jsonb_set(progress,'{tasks,0,referral}',$2::jsonb),'{events,0,operation,task,referral}',$2::jsonb) WHERE case_id=$1",[s.caseId,JSON.stringify(referral)]);
 ok(await call(OWNER,'configure-collaboration',configure(s)));
 const view=await read(s,HELPER);const json=JSON.stringify(view);assert.ok(!json.includes('PRIVATE'));assert.ok(!json.includes('Original private follow-up'));assert.ok(!json.includes('referral'));assert.ok(!json.includes('sourceHash'));
 ok(await call(HELPER,'update-shared-task',update(s)));
 const owner=(await admin.query('SELECT progress FROM safeathome_private.cases WHERE case_id=$1',[s.caseId])).rows[0].progress;assert.deepEqual(owner.tasks[0].referral,referral);parseProgressRecord(owner);
});

test('viewer grants cannot write and revocation prevents later proposal acceptance',async()=>{
 const v=await seed(VIEWER,'viewer');ok(await call(OWNER,'configure-collaboration',configure(v,{collaborationScope:{taskIds:['assigned-task'],allowTaskProgress:false,allowStatusProposals:false},assignedTaskIds:[]})));
 assert.equal((await call(VIEWER,'update-shared-task',update(v))).status,'not_found');assert.equal((await call(VIEWER,'propose-shared-status',proposal(v))).status,'not_found');
 const s=await seed();ok(await call(OWNER,'configure-collaboration',configure(s)));const p=proposal(s);ok(await call(HELPER,'propose-shared-status',p));
 const review={membershipId:s.membershipId,expectedPermissionRevision:3,expectedCaseRevision:1,expectedProgressRevision:2,expectedCollaborationRevision:2,proposalId:p.mutationId,decision:'accepted',mutationId:randomUUID()};
 const gate=await admin.connect();await gate.query('BEGIN');await gate.query('SELECT singleton FROM safeathome_private.repository_quota FOR UPDATE');
 const revoking=call(OWNER,'revoke-sharing',{caseId:s.caseId,invitationId:s.membershipId,expectedPermissionRevision:3});await new Promise(r=>setTimeout(r,30));
 const accepting=call(OWNER,'review-shared-status',review);await gate.query('COMMIT');gate.release();assert.equal((await revoking).status,'ok');assert.equal((await accepting).status,'conflict');
 const record=(await admin.query('SELECT progress FROM safeathome_private.cases WHERE case_id=$1',[s.caseId])).rows[0].progress;assert.equal(record.revision,2);assert.equal(record.events.filter((e:any)=>e.operation.type==='report_status').length,0);
});
test('verified migration-009 archives fill absent columns without creating collaboration access',async()=>{
 await seed();const origin='https://fictional-collaboration.supabase.co';const archive=JSON.parse((await captureDatabaseBackup(admin,origin)).toString('utf8'));
 archive.migrations=archive.migrations.slice(0,9);delete archive.tables.case_scan_models;delete archive.tables.share_sensitive;for(const row of archive.tables.case_shares)delete row.sensitive_scope;for(const c of archive.tables.cases)delete c.collaboration;for(const s of archive.tables.case_shares){delete s.collaboration_scope;delete s.recipient_email_hash;delete s.invited_email;}
 const bytes=Buffer.from(JSON.stringify(archive));await validateDatabaseBackup(bytes,origin);
 const old=await TestPostgres.start();try{const db=old.pool();await applyMigrations(db);await restoreDatabaseBackup(db,bytes,origin);
   assert.equal((await db.query('SELECT collaboration FROM safeathome_private.cases')).rows[0].collaboration,null);
   const share=(await db.query('SELECT revoked,collaboration_scope FROM safeathome_private.case_shares')).rows[0];assert.equal(share.revoked,true);assert.deepEqual(share.collaboration_scope.taskIds,[]);
 }finally{await old.close();}
});
