import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import { setTimeout as delay } from 'node:timers/promises';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { seedSensitive, OWNER, HELPER, VIEWER, OTHER } from '../support/sensitive-fixture.ts';
import { PostgresSharingRepository } from '../../src/sharing/postgres-sharing-repository.ts';
import { handleSharing } from '../../src/api/sharing.ts';
import { captureDatabaseBackup, validateDatabaseBackup, restoreDatabaseBackup } from '../../src/storage/database-backup.ts';
import { invitationEmailHash } from '../../src/auth/invitation-email.ts';
let cluster:TestPostgres,admin:Pool,runtime:Pool;
before(async()=>{cluster=await TestPostgres.start();admin=cluster.pool();await applyMigrations(admin);
  await admin.query('CREATE ROLE email_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');runtime=cluster.pool('email_runtime');});
after(async()=>{await cluster?.close();});
beforeEach(async()=>{await admin.query('TRUNCATE safeathome_private.cases CASCADE; UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0');});
const email='helper@fictional.example';
function dependencies(s:Awaited<ReturnType<typeof seedSensitive>>){return {simpleInvitationsEnabled:true,sharing:s.shares,
  authenticate:async(token:string)=> token==='owner'?{userId:OWNER,verifiedEmail:'owner@fictional.example'}:
    token==='helper'?{userId:VIEWER,verifiedEmail:email}:token==='unverified'?{userId:VIEWER}:
    token==='other'?{userId:OTHER,verifiedEmail:'other@fictional.example'}:null};}
async function invite(id=randomUUID()){
 const s=await seedSensitive(runtime),deps=dependencies(s);
 const fields={schemaVersion:'3',caseId:s.caseId,expectedCaseRevision:2,invitationId:id,recipientEmail:'  Helper@Fictional.Example  ',
   role:'helper',scope:{findingIds:['fictional-finding'],programIds:['scfhp-eaa'],allowHelperNotes:false},expiresAt:new Date(Date.now()+86400000).toISOString()};
 const response=await handleSharing({bearerToken:'owner',body:fields},deps,'create-email-invitation');assert.equal(response.status,200,JSON.stringify(response));
 const data=response.body as any;return {s,deps,fields,code:data.invitationCode as string,membership:data.membership};
}
test('owner uses email without lookup/UUID; only the verified mailbox can review/accept; forwarding and placeholder UUID bypass fail',async()=>{
 const i=await invite(OTHER),body={schemaVersion:'3',code:i.code};
 const row=(await admin.query('SELECT recipient_id,recipient_email_hash FROM safeathome_private.case_shares WHERE membership_id=$1',[OTHER])).rows[0];
 assert.equal(row.recipient_email_hash,invitationEmailHash(email));
 const listed=await handleSharing({bearerToken:'owner',body:{schemaVersion:'3',caseId:i.s.caseId}},i.deps,'list-email-sharing');
 assert.equal((listed.body as any).shares.find((r:any)=>r.membershipId===OTHER).invitedEmail,email);
 const oldList=await handleSharing({bearerToken:'owner',body:{schemaVersion:'3',caseId:i.s.caseId}},i.deps,'list-sharing');
 assert.ok(!(oldList.body as any).shares.some((r:any)=>Object.hasOwn(r,'invitedEmail')),'legacy response shape stays exact');
 assert.equal((await handleSharing({bearerToken:'helper',body:{schemaVersion:'3',caseId:i.s.caseId}},i.deps,'list-email-sharing')).status,404);
 for(const token of ['other','unverified','owner']){
  assert.equal((await handleSharing({bearerToken:token,body},i.deps,'review-invitation')).status,404);
  assert.equal((await handleSharing({bearerToken:token,body:{...body,expectedPermissionRevision:1}},i.deps,'accept-invitation')).status,404);
 }
 const review=await handleSharing({bearerToken:'helper',body},i.deps,'review-invitation');assert.equal(review.status,200);
 assert.deepEqual(Object.keys(review.body).sort(),['membership','schemaVersion']);
 assert.equal((review.body as any).membership.recipientId,VIEWER);
 assert.equal((await admin.query('SELECT recipient_id FROM safeathome_private.case_shares WHERE membership_id=$1',[OTHER])).rows[0].recipient_id,OTHER,'preview does not claim the invitation');
 const accepted=await handleSharing({bearerToken:'helper',body:{...body,expectedPermissionRevision:1}},i.deps,'accept-invitation');assert.equal(accepted.status,200);
 assert.equal((accepted.body as any).membership.permissionRevision,2);
 const saved=(await admin.query('SELECT recipient_id,recipient_email_hash,invitation_hash FROM safeathome_private.case_shares WHERE membership_id=$1',[OTHER])).rows[0];
 assert.deepEqual(saved,{recipient_id:VIEWER,recipient_email_hash:null,invitation_hash:null});
 assert.equal((await handleSharing({bearerToken:'helper',body:{...body,expectedPermissionRevision:1}},i.deps,'accept-invitation')).status,404);
 assert.equal((await i.s.shares.execute(VIEWER,'read-shared-case',{schemaVersion:'3',membershipId:OTHER,expectedPermissionRevision:2})).status,'ok');
 assert.equal((await i.s.shares.sensitive(VIEWER,'read-sensitive-sharing',{schemaVersion:'3',membershipId:OTHER,expectedPermissionRevision:2})).status,'not_found');
 const client=await runtime.connect();try{await client.query('BEGIN');await client.query("SELECT set_config('safeathome.user_id',$1,true)",[VIEWER]);
  for(const table of ['cases','evidence','program_intake','share_sensitive'])assert.equal((await client.query(`SELECT 1 FROM safeathome_private.${table}`)).rowCount,0);
  await assert.rejects(client.query("SELECT safeathome_private.shared_operation_uuid('review-invitation','{}')"));
 }finally{await client.query('ROLLBACK');client.release();}
});
test('creation retry preserves one invite; altered identity/forged authority fail and default-off disables the new route',async()=>{
 const i=await invite();
 const retry=await handleSharing({bearerToken:'owner',body:i.fields},i.deps,'create-email-invitation');assert.equal(retry.status,200);assert.equal((retry.body as any).invitationCode,null);
 assert.equal((await handleSharing({bearerToken:'owner',body:{...i.fields,recipientEmail:'different@fictional.example'}},i.deps,'create-email-invitation')).status,409);
 for(const extra of ['recipientId','verifiedEmail','ownerId','recipientEmailHash'])assert.equal((await handleSharing({bearerToken:'owner',body:{...i.fields,[extra]:'forged'}},i.deps,'create-email-invitation')).status,400);
 assert.equal((await handleSharing({bearerToken:'owner',body:i.fields},{...i.deps,simpleInvitationsEnabled:false},'create-email-invitation')).status,404);
 assert.equal((await i.s.shares.execute(HELPER,'list-shared-cases',{schemaVersion:'3'})).status,'ok','existing UUID-bound invitation path remains usable');
});
test('revocation, pending source invalidation and expiry deny redemption after waiting for locks',async()=>{
 const i=await invite();
 await i.s.shares.execute(OWNER,'revoke-sharing',{schemaVersion:'3',caseId:i.s.caseId,invitationId:i.fields.invitationId,expectedPermissionRevision:1});
 assert.equal((await handleSharing({bearerToken:'helper',body:{schemaVersion:'3',code:i.code}},i.deps,'review-invitation')).status,404);
 assert.equal((await admin.query('SELECT recipient_email_hash FROM safeathome_private.case_shares WHERE membership_id=$1',[i.fields.invitationId])).rows[0].recipient_email_hash,null);
 const e=await invite(), waiting=new PostgresSharingRepository(cluster.pool('email_runtime','email-waiting'));
 const lock=await admin.connect();let result:ReturnType<typeof waiting.execute>|undefined;
 try{
  await lock.query('BEGIN');await lock.query('SELECT 1 FROM safeathome_private.repository_quota FOR UPDATE');
  const hash=(await admin.query('SELECT invitation_hash FROM safeathome_private.case_shares WHERE membership_id=$1',[e.fields.invitationId])).rows[0].invitation_hash;
  result=waiting.execute(VIEWER,'accept-invitation',{schemaVersion:'3',code:e.code,expectedPermissionRevision:1},hash,email);
  const deadline=Date.now()+3000;
  while(!(await admin.query("SELECT 1 FROM pg_stat_activity WHERE application_name='email-waiting' AND wait_event_type='Lock'")).rowCount){assert.ok(Date.now()<deadline);await delay(10);}
  await lock.query("UPDATE safeathome_private.case_shares SET invitation_expires_at=clock_timestamp()-interval '1 second' WHERE membership_id=$1",[e.fields.invitationId]);
  await lock.query('COMMIT');assert.equal((await result).status,'not_found');
 }finally{await lock.query('ROLLBACK');lock.release();await result;}
 const stale=await invite();await admin.query('UPDATE safeathome_private.case_shares SET projection=NULL WHERE membership_id=$1',[stale.fields.invitationId]);
 assert.equal((await handleSharing({bearerToken:'helper',body:{schemaVersion:'3',code:stale.code}},stale.deps,'review-invitation')).status,404);
});
test('backup validates email binding, old twelve-migration archives normalize it, quarantine erases all redeemable capabilities',async()=>{
 await invite();const origin='https://fictional-email.supabase.co',archive=await captureDatabaseBackup(admin,origin),old=JSON.parse(archive.toString());
 old.migrations=old.migrations.slice(0,12);for(const row of old.tables.case_shares){delete row.recipient_email_hash;delete row.invited_email;}
 await validateDatabaseBackup(Buffer.from(JSON.stringify(old)),origin);
 const corrupt=JSON.parse(archive.toString());corrupt.tables.case_shares[0].recipient_email_hash='raw@email.example';
 await assert.rejects(validateDatabaseBackup(Buffer.from(JSON.stringify(corrupt)),origin));
 const target=await TestPostgres.start();try{const db=target.pool();await applyMigrations(db);await restoreDatabaseBackup(db,archive,origin);
  assert.equal((await db.query('SELECT 1 FROM safeathome_private.case_shares WHERE NOT revoked OR recipient_email_hash IS NOT NULL OR invitation_hash IS NOT NULL OR invited_email IS NOT NULL')).rowCount,0);
 }finally{await target.close();}
});
