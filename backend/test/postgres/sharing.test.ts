import assert from 'node:assert/strict';
import { randomUUID, randomBytes, createHash } from 'node:crypto';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { OWNER, create } from './fixtures.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { PostgresSharingRepository } from '../../src/sharing/postgres-sharing-repository.ts';
import type { CaseMembership, SharingRequest, SharingRoute, SharingResult } from '../../src/sharing/contracts.ts';
import { captureDatabaseBackup, restoreDatabaseBackup } from '../../src/storage/database-backup.ts';
import { readCapacityReport } from '../../src/storage/capacity-report.ts';
const VIEWER='22222222-2222-4222-8222-222222222222',HELPER='33333333-3333-4333-8333-333333333333',OTHER='44444444-4444-4444-8444-444444444444';
let cluster:TestPostgres,target:TestPostgres,admin:Pool,runtime:Pool,cases:PostgresCaseRepository,shares:PostgresSharingRepository;
before(async()=>{cluster=await TestPostgres.start();admin=cluster.pool();await applyMigrations(admin);await admin.query('CREATE ROLE sharing_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');runtime=cluster.pool('sharing_runtime');cases=new PostgresCaseRepository(runtime);shares=new PostgresSharingRepository(runtime);});
beforeEach(async()=>{await admin.query(`TRUNCATE safeathome_private.cases,safeathome_private.deleted_cases,safeathome_private.closed_accounts,safeathome_private.account_deletion_previews,safeathome_private.auth_deletion_jobs CASCADE;UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);});
after(async()=>{await target?.close();await cluster?.close();});
const scope={findingIds:['fictional-finding'],programIds:[],allowHelperNotes:false};
const execute=(user:string,route:SharingRoute,fields:Record<string,unknown>,tokenHash?:string)=>shares.execute(user,route,{schemaVersion:'3',...fields} as SharingRequest,tokenHash);
function ok(result:SharingResult){assert.equal(result.status,'ok');if(result.status!=='ok')throw Error();return result.data;}
const member=(data:Record<string,unknown>)=>data.membership as CaseMembership;
async function invite(recipientId=VIEWER,helper=false){const snapshot=await create(cases);const code=randomBytes(32).toString('base64url'),tokenHash=createHash('sha256').update(code).digest('hex');const fields={caseId:snapshot.caseId,expectedCaseRevision:snapshot.revision,invitationId:randomUUID(),recipientId,role:helper?'helper':'viewer',scope:{...scope,allowHelperNotes:helper},expiresAt:null};return {snapshot,code,tokenHash,fields,grant:member(ok(await execute(OWNER,'create-invitation',fields,tokenHash)))};}
async function accept(inv:Awaited<ReturnType<typeof invite>>){return member(ok(await execute(inv.fields.recipientId,'accept-invitation',{code:inv.code,expectedPermissionRevision:1},inv.tokenHash)));}
const read=(user:string,g:CaseMembership)=>execute(user,'read-shared-case',{membershipId:g.membershipId,expectedPermissionRevision:g.permissionRevision});
test('recipient-bound, expiring, single-use invites; exact retries do not mint capabilities',async()=>{
 const inv=await invite();assert.equal((await execute(OTHER,'review-invitation',{code:inv.code},inv.tokenHash)).status,'not_found');assert.equal((await read(VIEWER,inv.grant)).status,'not_found');
 assert.deepEqual(Object.keys(ok(await execute(VIEWER,'review-invitation',{code:inv.code},inv.tokenHash))),['membership']);
 assert.equal(ok(await execute(OWNER,'create-invitation',inv.fields,inv.tokenHash)).created,false);
 const g=await accept(inv);assert.equal(g.permissionRevision,2);assert.equal((await execute(VIEWER,'accept-invitation',{code:inv.code,expectedPermissionRevision:1},inv.tokenHash)).status,'not_found');assert.equal((await read(OTHER,g)).status,'not_found');
 const row=(await admin.query('SELECT * FROM safeathome_private.case_shares')).rows[0];assert.equal(row.invitation_hash,null);assert.ok(!JSON.stringify(row).includes(inv.code));
 const second=await invite(HELPER);await admin.query("UPDATE safeathome_private.case_shares SET invitation_expires_at=clock_timestamp()-interval '1 second' WHERE membership_id=$1",[second.grant.membershipId]);assert.equal((await execute(HELPER,'review-invitation',{code:second.code},second.tokenHash)).status,'not_found');
});
test('allowlist and forced RLS preserve raw owner case/photo/PDF isolation and deny recipient writes',async()=>{
 const inv=await invite(),g=await accept(inv),json=JSON.stringify(ok(await read(VIEWER,g)));
 for(const key of ['profile','annualIncomeUsd','evidenceIds','measurements','bytes','healthPlan','formAnswers'])assert.ok(!json.includes('"'+key+'"'));
 const c=await runtime.connect();try{await c.query('BEGIN');await c.query("SELECT set_config('safeathome.user_id',$1,true)",[VIEWER]);for(const table of ['cases','evidence','exports'])assert.equal((await c.query('SELECT * FROM safeathome_private.'+table)).rowCount,0);assert.equal((await c.query('SELECT * FROM safeathome_private.case_shares')).rowCount,1);assert.equal((await c.query("UPDATE safeathome_private.case_shares SET definition='{}'")).rowCount,0);await c.query('ROLLBACK');}finally{c.release();}
 assert.equal((await execute(VIEWER,'revoke-sharing',{caseId:g.caseId,invitationId:g.membershipId,expectedPermissionRevision:2})).status,'not_found');
});
test('helper-only notes retry exactly; scope edits invalidate old permission revisions',async()=>{
 const inv=await invite(HELPER,true),g=await accept(inv),note={membershipId:g.membershipId,expectedPermissionRevision:2,mutationId:randomUUID(),note:'Fictional progress note'};
 const first=ok(await execute(HELPER,'add-shared-note',note));assert.deepEqual(ok(await execute(HELPER,'add-shared-note',note)),first);assert.equal((await execute(HELPER,'add-shared-note',{...note,note:'Changed'})).status,'conflict');
 const changed=member(ok(await execute(OWNER,'change-sharing',{caseId:g.caseId,expectedCaseRevision:1,invitationId:g.membershipId,expectedPermissionRevision:2,role:'viewer',scope,expiresAt:null})));
 assert.equal((await read(HELPER,g)).status,'conflict');assert.equal((await execute(HELPER,'add-shared-note',{...note,mutationId:randomUUID(),expectedPermissionRevision:changed.permissionRevision})).status,'not_found');
});
test('revocation fences later writes and clears content; repeats are safe',async()=>{
 const inv=await invite(HELPER,true),g=await accept(inv),revoke={caseId:g.caseId,invitationId:g.membershipId,expectedPermissionRevision:2};
 const blocker=await admin.connect();await blocker.query('BEGIN');await blocker.query('SELECT singleton FROM safeathome_private.repository_quota FOR UPDATE');
 const revoking=execute(OWNER,'revoke-sharing',revoke);await new Promise(r=>setTimeout(r,30));const note=execute(HELPER,'add-shared-note',{membershipId:g.membershipId,expectedPermissionRevision:2,mutationId:randomUUID(),note:'Late note'});await blocker.query('COMMIT');blocker.release();
 assert.equal((await revoking).status,'ok');assert.equal((await note).status,'not_found');assert.equal((await read(HELPER,g)).status,'not_found');assert.equal((await execute(OWNER,'revoke-sharing',revoke)).status,'ok');
 const row=(await admin.query('SELECT * FROM safeathome_private.case_shares')).rows[0];assert.equal(row.projection,null);assert.deepEqual(row.notes,{events:[]});
});
test('case edits visibly stale projections; deletion previews bind grants and deletion cascades',async()=>{
 const inv=await invite(),g=await accept(inv),tokenHash=createHash('sha256').update('fictional preview').digest('hex');await cases.prepareAccountDeletion({userId:OWNER,tokenHash});await read(VIEWER,g);assert.equal((await cases.confirmAccountDeletion({userId:OWNER,tokenHash})).status,'changed');
 await admin.query("UPDATE safeathome_private.cases SET revision=2,snapshot=jsonb_set(snapshot,'{revision}','2') WHERE case_id=$1",[g.caseId]);assert.equal((ok(await read(VIEWER,g)).projection as {stale:boolean}).stale,true);
 assert.equal((await cases.deleteCaseIfCurrent({userId:OWNER,caseId:g.caseId,revision:2,expectedCatalogRevision:0})).status,'deleted');assert.equal((await read(VIEWER,g)).status,'not_found');assert.equal((await admin.query('SELECT * FROM safeathome_private.case_shares')).rowCount,0);
});
test('recipient deletion removes access only; audit is bounded and capacity includes grants',async()=>{
 const inv=await invite(),g=await accept(inv);for(let i=0;i<105;i++)await read(VIEWER,g);assert.equal((await admin.query('SELECT audit FROM safeathome_private.case_shares')).rows[0].audit.events.length,100);assert.equal((await readCapacityReport(admin)).rows.case_shares,1);
 const tokenHash=createHash('sha256').update('recipient deletion').digest('hex');await cases.prepareAccountDeletion({userId:VIEWER,tokenHash});assert.equal((await cases.confirmAccountDeletion({userId:VIEWER,tokenHash})).status,'confirmed');assert.equal((await admin.query('SELECT * FROM safeathome_private.case_shares')).rowCount,0);assert.equal((await admin.query('SELECT * FROM safeathome_private.cases')).rowCount,1);
});
test('backup validates grants; isolated restore quarantines invitations and memberships',async()=>{
 const inv=await invite();await accept(inv);const origin='https://fictional-sharing.supabase.co',archive=await captureDatabaseBackup(admin,origin);target=await TestPostgres.start();const targetAdmin=target.pool();await applyMigrations(targetAdmin);await restoreDatabaseBackup(targetAdmin,archive,origin);const row=(await targetAdmin.query('SELECT * FROM safeathome_private.case_shares')).rows[0];assert.equal(row.revoked,true);assert.equal(row.invitation_hash,null);assert.equal(row.projection,null);
});

test('active expiry and retention discard private content and reject reads/notes under RLS',async()=>{
 const inv=await invite(HELPER,true),g=await accept(inv);
 await admin.query("UPDATE safeathome_private.case_shares SET expires_at=clock_timestamp()-interval '1 second' WHERE membership_id=$1",[g.membershipId]);
 assert.equal((await read(HELPER,g)).status,'not_found');
 assert.equal((await execute(HELPER,'add-shared-note',{membershipId:g.membershipId,expectedPermissionRevision:2,mutationId:randomUUID(),note:'Expired'})).status,'not_found');
 const c=await runtime.connect();try{await c.query('BEGIN');await c.query("SELECT set_config('safeathome.user_id',$1,true)",[HELPER]);assert.equal((await c.query('SELECT * FROM safeathome_private.case_shares')).rowCount,0);await c.query('ROLLBACK');}finally{c.release();}
 await admin.query('SELECT * FROM safeathome_private.sweep_retention()');
 const row=(await admin.query('SELECT * FROM safeathome_private.case_shares')).rows[0];assert.equal(row.projection,null);assert.deepEqual(row.notes,{events:[]});
 assert.equal((ok(await execute(OWNER,'list-sharing',{caseId:g.caseId})).shares as CaseMembership[])[0].state,'expired');
});
test('owner operations reject viewer, helper and unrelated accounts; pending revocation prevents acceptance',async()=>{
 const inv=await invite(),g=inv.grant;
 const ownerRequests:[SharingRoute,Record<string,unknown>][]=[
  ['preview-sharing',{caseId:g.caseId,expectedCaseRevision:1,scope}],
  ['create-invitation',{...inv.fields,invitationId:randomUUID()}],['list-sharing',{caseId:g.caseId}],
  ['change-sharing',{caseId:g.caseId,expectedCaseRevision:1,invitationId:g.membershipId,expectedPermissionRevision:1,role:'helper',scope:{...scope,allowHelperNotes:true},expiresAt:null}],
  ['revoke-sharing',{caseId:g.caseId,invitationId:g.membershipId,expectedPermissionRevision:1}],
 ];
 for(const user of [VIEWER,HELPER,OTHER])for(const [route,fields]of ownerRequests)assert.equal((await execute(user,route,fields,route==='create-invitation'?inv.tokenHash:undefined)).status,'not_found',user+' '+route);
 ok(await execute(OWNER,'revoke-sharing',{caseId:g.caseId,invitationId:g.membershipId,expectedPermissionRevision:1}));
 assert.equal((await execute(VIEWER,'accept-invitation',{code:inv.code,expectedPermissionRevision:1},inv.tokenHash)).status,'not_found');
});
test('owner deletion purges all grants and stale grant/case revisions cannot republish',async()=>{
 const inv=await invite(),g=await accept(inv);
 assert.equal((await execute(OWNER,'change-sharing',{caseId:g.caseId,expectedCaseRevision:2,invitationId:g.membershipId,expectedPermissionRevision:2,role:'viewer',scope,expiresAt:null})).status,'conflict');
 const tokenHash=createHash('sha256').update('owner deletion').digest('hex');
 await cases.prepareAccountDeletion({userId:OWNER,tokenHash});assert.equal((await cases.confirmAccountDeletion({userId:OWNER,tokenHash})).status,'confirmed');
 assert.equal((await admin.query('SELECT * FROM safeathome_private.case_shares')).rowCount,0);assert.equal((await read(VIEWER,g)).status,'not_found');
});
test('sixteen retained grants and fifty notes bound storage; permission retries are idempotent',async()=>{
 const inv=await invite(HELPER,true),g=await accept(inv);
 const change={caseId:g.caseId,expectedCaseRevision:1,invitationId:g.membershipId,expectedPermissionRevision:2,role:'helper',scope:{...scope,allowHelperNotes:true},expiresAt:null};
 const first=ok(await execute(OWNER,'change-sharing',change));assert.deepEqual(ok(await execute(OWNER,'change-sharing',change)),first);
 for(let i=0;i<50;i++)ok(await execute(HELPER,'add-shared-note',{membershipId:g.membershipId,expectedPermissionRevision:3,mutationId:randomUUID(),note:'Fictional '+i}));
 assert.equal((await execute(HELPER,'add-shared-note',{membershipId:g.membershipId,expectedPermissionRevision:3,mutationId:randomUUID(),note:'Over limit'})).status,'quota_exceeded');
 for(let i=0;i<15;i++)ok(await execute(OWNER,'create-invitation',{...inv.fields,invitationId:randomUUID()},createHash('sha256').update('fictional-'+i).digest('hex')));
 assert.equal((await execute(OWNER,'create-invitation',{...inv.fields,invitationId:randomUUID()},createHash('sha256').update('over').digest('hex'))).status,'quota_exceeded');
 for(let group=0;group<3;group++){
   const snapshot=await create(cases);
   for(let i=0;i<16;i++)ok(await execute(OWNER,'create-invitation',{...inv.fields,caseId:snapshot.caseId,invitationId:randomUUID()},createHash('sha256').update('recipient-'+group+'-'+i).digest('hex')));
 }
 const another=await create(cases);
 assert.equal((await execute(OWNER,'create-invitation',{...inv.fields,caseId:another.caseId,invitationId:randomUUID()},createHash('sha256').update('recipient-over').digest('hex'))).status,'quota_exceeded');
 const db=await runtime.connect();try{
   await db.query('BEGIN');await db.query("SELECT set_config('safeathome.user_id',$1,true)",[HELPER]);
   const discovery=(await db.query("SELECT safeathome_private.shared_operation('list-shared-cases','{}') AS result")).rows[0].result;
   assert.equal(discovery.rows.length,1);
   for(const row of discovery.rows)for(const key of ['projection','notes','audit','invitation_hash','creation_key'])assert.equal(Object.hasOwn(row,key),false);
   await db.query('ROLLBACK');
 }finally{db.release();}

});
test('owner-typed labels: owner sees both, recipient only the owner label, others nothing; legacy shapes exact; revoke clears',async()=>{
 const snapshot=await create(cases),code=randomBytes(32).toString('base64url'),tokenHash=createHash('sha256').update(code).digest('hex');
 const fields={caseId:snapshot.caseId,expectedCaseRevision:snapshot.revision,invitationId:randomUUID(),recipientId:HELPER,role:'helper',scope:{...scope,allowHelperNotes:true},expiresAt:null,recipientLabel:'Fictional neighbor Ana',ownerLabel:'Fictional Sam'};
 const created=member(ok(await execute(OWNER,'create-invitation',fields,tokenHash)));assert.equal(Object.hasOwn(created,'recipientLabel'),false);
 assert.equal((await execute(OWNER,'create-invitation',{...fields,recipientLabel:'Changed'},tokenHash)).status,'conflict');
 assert.equal((await execute(OTHER,'review-invitation',{code,includeLabels:true},tokenHash)).status,'not_found');
 const reviewed=member(ok(await execute(HELPER,'review-invitation',{code,includeLabels:true},tokenHash)));assert.equal(reviewed.ownerLabel,'Fictional Sam');assert.equal(Object.hasOwn(reviewed,'recipientLabel'),false);
 assert.equal(Object.hasOwn(member(ok(await execute(HELPER,'review-invitation',{code},tokenHash))),'ownerLabel'),false);
 const g=member(ok(await execute(HELPER,'accept-invitation',{code,expectedPermissionRevision:1},tokenHash)));
 const ownerRow=(includeLabels?:true)=>execute(OWNER,'list-sharing',{caseId:g.caseId,...(includeLabels?{includeLabels}:{})}).then(r=>(ok(r).shares as CaseMembership[])[0]);
 const labelled=await ownerRow(true);assert.equal(labelled.recipientLabel,'Fictional neighbor Ana');assert.equal(labelled.ownerLabel,'Fictional Sam');
 const legacy=await ownerRow();assert.ok(!Object.hasOwn(legacy,'recipientLabel') && !Object.hasOwn(legacy,'ownerLabel'),'legacy shape stays exact');
 const mine=(user:string,includeLabels?:true)=>execute(user,'list-shared-cases',includeLabels?{includeLabels}:{}).then(r=>ok(r).memberships as CaseMembership[]);
 const shared=(await mine(HELPER,true))[0];assert.equal(shared.ownerLabel,'Fictional Sam');assert.equal(Object.hasOwn(shared,'recipientLabel'),false);
 assert.ok(!JSON.stringify(await mine(HELPER,true)).includes('neighbor Ana'));assert.ok(!Object.hasOwn((await mine(HELPER))[0],'ownerLabel'));
 for(const user of [VIEWER,OTHER]){assert.deepEqual(await mine(user,true),[]);assert.equal((await execute(user,'list-sharing',{caseId:g.caseId,includeLabels:true})).status,'not_found');}
 const changed=member(ok(await execute(OWNER,'change-sharing',{caseId:g.caseId,expectedCaseRevision:1,invitationId:g.membershipId,expectedPermissionRevision:2,role:'viewer',scope,expiresAt:null})));
 assert.equal((await ownerRow(true)).recipientLabel,'Fictional neighbor Ana');
 ok(await execute(OWNER,'revoke-sharing',{caseId:g.caseId,invitationId:g.membershipId,expectedPermissionRevision:changed.permissionRevision}));
 const revoked=await ownerRow(true);assert.ok(!Object.hasOwn(revoked,'recipientLabel') && !Object.hasOwn(revoked,'ownerLabel'));
 const row=(await admin.query('SELECT definition FROM safeathome_private.case_shares')).rows[0];assert.ok(!JSON.stringify(row).includes('Fictional'));
});
