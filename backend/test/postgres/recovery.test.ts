import assert from 'node:assert/strict';
import { createHash,randomUUID } from 'node:crypto';
import { after,before,beforeEach,test } from 'node:test';
import type { Pool } from 'pg';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { captureDatabaseBackup } from '../../src/storage/database-backup.ts';
import { captureRecoveryCheckpoint,prepareRecovery,promoteRecovery } from '../../src/storage/recovery.ts';
import { freezeRepository,thawRepository,repositoryIsOpen } from '../../src/storage/recovery-control.ts';
import { create,OWNER,OTHER,draft,imageInput } from './fixtures.ts';
import { seedSensitive, HELPER as SHARED_HELPER } from '../support/sensitive-fixture.ts';
import { createDurableServer } from '../../src/api/durable-server.ts';
const ORIGIN='https://fictional-recovery.supabase.co';
const hash=(s:string)=>createHash('sha256').update(s).digest('hex');
let source:TestPostgres,target:TestPostgres,admin:Pool,db:Pool,runtime:Pool,targetRuntime:Pool,repo:PostgresCaseRepository;
before(async()=>{
 [source,target]=await Promise.all([TestPostgres.start(),TestPostgres.start()]);admin=source.pool();db=target.pool();
 for(const pool of [admin,db]){await applyMigrations(pool);await pool.query('CREATE ROLE recovery_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');}
 runtime=source.pool('recovery_runtime');targetRuntime=target.pool('recovery_runtime');repo=new PostgresCaseRepository(runtime);
});
beforeEach(async()=>{for(const pool of [admin,db]){
 await pool.query("UPDATE safeathome_recovery.control SET state='open',staged=NULL,checkpoint_hash=NULL,promoted_target=NULL,generation=gen_random_uuid() WHERE singleton");
 await pool.query('GRANT USAGE ON SCHEMA safeathome_private TO safeathome_app');
 await pool.query('TRUNCATE safeathome_private.cases,safeathome_private.deleted_cases,safeathome_private.closed_accounts CASCADE; UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0');
}});
after(async()=>{await Promise.all([source?.close(),target?.close()]);});
test('frozen checkpoint blocks app writes, operator/worker writes, truncate and runtime metadata; thaw invalidates its proof',async()=>{
 const item=await create(repo),archive=await captureDatabaseBackup(admin,ORIGIN);
 await assert.rejects(captureRecoveryCheckpoint(admin,ORIGIN));
 await freezeRepository(admin);const cp=await captureRecoveryCheckpoint(admin,ORIGIN);
 assert.equal(await repositoryIsOpen(runtime),false);
 await assert.rejects(createDurableServer({pool:runtime,auth:{projectUrl:'https://abcdefghijklmnopqrst.supabase.co',publishableKey:'sb_publishable_fictional'}}));
 await assert.rejects(repo.createForUser(OWNER,draft()));
 await assert.rejects(admin.query('UPDATE safeathome_private.cases SET snapshot=snapshot'));
 await assert.rejects(admin.query('TRUNCATE safeathome_private.evidence'));
 await assert.rejects(runtime.query('SELECT * FROM safeathome_recovery.control'));
 await thawRepository(admin);assert.equal(await repositoryIsOpen(runtime),true);
 await assert.rejects(prepareRecovery(admin,db,archive,cp,ORIGIN));
 assert.equal((await db.query('SELECT count(*) FROM safeathome_private.cases')).rows[0].count,'0');
});
test('restrictive recovery policy fences cached reads and SECURITY DEFINER helper reads even if schema usage is regranted',async()=>{
 const fixture=await seedSensitive(runtime),client=await runtime.connect();
 try{
  await client.query("SELECT set_config('safeathome.user_id',$1,false)",[SHARED_HELPER]);
  const args=JSON.stringify({membershipId:fixture.membershipId,expectedPermissionRevision:2});
  const read=()=>client.query("SELECT safeathome_private.shared_operation('read-shared-case',$1::jsonb) AS result",[args]);
  assert.equal((await read()).rows[0].result.status,'ok');
  await client.query('PREPARE cached_case AS SELECT * FROM safeathome_private.case_shares');
  await freezeRepository(admin);
  await admin.query('GRANT USAGE ON SCHEMA safeathome_private TO safeathome_app');
  assert.equal((await client.query('EXECUTE cached_case')).rowCount,0);
  assert.equal((await read()).rows[0].result.status,'not_found');
 }finally{client.release();}
});
test('older backup retains only unchanged complete cases, carries later deletions/closures and permanently retires every unavailable ID',async()=>{
 const unchanged=await create(repo),corrected=await create(repo),erased=await create(repo),closed=await create(repo,OTHER);
 const photo=await imageInput(corrected);assert.equal((await repo.saveEvidenceIfCurrent(photo)).status,'saved');
 const archive=await captureDatabaseBackup(admin,ORIGIN);
 assert.equal((await repo.deleteEvidenceIfCurrent({userId:OWNER,caseId:corrected.caseId,revision:corrected.revision,
  expectedCatalogRevision:1,evidenceId:photo.evidenceId,expectedEvidenceRevision:1})).status,'deleted');
 assert.equal((await repo.deleteCaseIfCurrent({userId:OWNER,caseId:erased.caseId,revision:erased.revision,expectedCatalogRevision:0})).status,'deleted');
 const token=hash(randomUUID());await repo.prepareAccountDeletion({userId:OTHER,tokenHash:token});await repo.confirmAccountDeletion({userId:OTHER,tokenHash:token});
 const later=await create(repo);
 await freezeRepository(admin);const cp=await captureRecoveryCheckpoint(admin,ORIGIN);
 const prepared=await prepareRecovery(admin,db,archive,cp,ORIGIN);
 assert.equal(prepared.retainedCases,1);assert.equal(prepared.excludedOldCases,3);assert.equal(prepared.unavailableCurrentCases,2);
 assert.equal(await repositoryIsOpen(targetRuntime),false);
 await assert.rejects(targetRuntime.query('SELECT * FROM safeathome_private.cases'));
 await assert.rejects(new PostgresCaseRepository(targetRuntime).loadForUser(OWNER,unchanged.caseId));
 assert.equal((await db.query('SELECT count(*) FROM safeathome_private.evidence')).rows[0].count,'0','replaced/deleted photo bytes cannot return');
 assert.equal((await db.query('SELECT catalog_revision FROM safeathome_private.deleted_cases WHERE case_hash=$1',[hash(corrected.caseId)])).rows[0].catalog_revision,'2','retired IDs retain the current high-water mark');
 const result=await promoteRecovery(admin,db,cp,ORIGIN);assert.equal(result.sourceRetired,true);
 assert.equal(await repositoryIsOpen(runtime),false);await assert.rejects(thawRepository(admin));
 const recovered=new PostgresCaseRepository(targetRuntime);assert.deepEqual(await recovered.loadForUser(OWNER,unchanged.caseId),unchanged);
 for(const item of [corrected,erased,closed,later]){
  assert.equal(await recovered.loadForUser(OWNER,item.caseId),null);
  assert.equal((await recovered.createForUser(OWNER,draft(item.caseId))).status,'id_unavailable','stale mobile creates cannot recreate retired IDs');
 }
 const closure=(await db.query('SELECT owner_hash,receipt_hash FROM safeathome_private.closed_accounts')).rows[0];
 assert.equal(closure.owner_hash,hash(OTHER));assert.equal(closure.receipt_hash,null);
});
test('post-prepare operator mutation, wrong origin, edited or replaced checkpoint and same-database targets cannot promote',async()=>{
 await create(repo);const archive=await captureDatabaseBackup(admin,ORIGIN);await freezeRepository(admin);
 const cp=await captureRecoveryCheckpoint(admin,ORIGIN);
 await assert.rejects(prepareRecovery(admin,admin,archive,cp,ORIGIN));
 await assert.rejects(prepareRecovery(admin,db,archive,cp,'https://other.example'));
 const tampered=JSON.parse(cp.toString());tampered.heads[0].fingerprint='0'.repeat(64);
 await assert.rejects(prepareRecovery(admin,db,archive,Buffer.from(JSON.stringify(tampered)),ORIGIN));
 await prepareRecovery(admin,db,archive,cp,ORIGIN);
 await db.query('UPDATE safeathome_private.cases SET snapshot=snapshot');
 await assert.rejects(promoteRecovery(admin,db,cp,ORIGIN));assert.equal(await repositoryIsOpen(targetRuntime),false);
 assert.equal((await admin.query('SELECT state FROM safeathome_recovery.control')).rows[0].state,'frozen');
});
test('source loss or unavailable current proof never converts a recovered database into a live service',async()=>{
 await create(repo);const archive=await captureDatabaseBackup(admin,ORIGIN);await freezeRepository(admin);const cp=await captureRecoveryCheckpoint(admin,ORIGIN);
 await prepareRecovery(admin,db,archive,cp,ORIGIN);
 const missing={connect:async()=>{throw Error('unavailable');}} as unknown as Pool;
 await assert.rejects(promoteRecovery(missing,db,cp,ORIGIN));assert.equal(await repositoryIsOpen(targetRuntime),false);
 await captureRecoveryCheckpoint(admin,ORIGIN);
 await assert.rejects(promoteRecovery(admin,db,cp,ORIGIN));
});
test('failure after retiring the source keeps both sides closed; retry opens only the same staged target',async()=>{
 await create(repo);const archive=await captureDatabaseBackup(admin,ORIGIN);await freezeRepository(admin);const cp=await captureRecoveryCheckpoint(admin,ORIGIN);
 await prepareRecovery(admin,db,archive,cp,ORIGIN);
 const failedTarget={connect:async()=>{const client=await db.connect();return {
  query:(sql:any,values:any)=>{if(typeof sql==='string'&&sql.includes("SET state='open',staged=NULL"))throw Error('simulated target failure');return client.query(sql,values);},
  release:(broken:boolean)=>client.release(broken),
 };}} as unknown as Pool;
 await assert.rejects(promoteRecovery(admin,failedTarget,cp,ORIGIN));
 assert.equal(await repositoryIsOpen(runtime),false);assert.equal(await repositoryIsOpen(targetRuntime),false);
 assert.equal((await admin.query('SELECT state FROM safeathome_recovery.control')).rows[0].state,'retired');
 assert.equal((await promoteRecovery(admin,db,cp,ORIGIN)).targetOpen,true);
});
