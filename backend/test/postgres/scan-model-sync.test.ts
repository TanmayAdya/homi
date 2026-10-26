import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID,createHash} from 'node:crypto';
import {before,beforeEach,after,test} from 'node:test';
import type {Pool} from 'pg';
import {TestPostgres} from './harness.ts';
import {applyMigrations} from '../../src/storage/migrate.ts';
import {PostgresCaseRepository} from '../../src/storage/postgres-case-repository.ts';
import {captureDatabaseBackup,restoreDatabaseBackup,validateDatabaseBackup} from '../../src/storage/database-backup.ts';
import {readCapacityReport} from '../../src/storage/capacity-report.ts';
import {OWNER,OTHER,create} from './fixtures.ts';
import type {ScanSave} from '../../src/assessment/scan-model.ts';
let cluster:TestPostgres,target:TestPostgres,admin:Pool,runtime:Pool,repo:PostgresCaseRepository;
const fixture=JSON.parse(readFileSync(new URL('../../../contracts/v3/fixtures/scan-model-sync.json',import.meta.url),'utf8'))[0];
const at='2026-10-24T18:00:00.000Z';
before(async()=>{cluster=await TestPostgres.start();admin=cluster.pool();await applyMigrations(admin);await admin.query('CREATE ROLE scan_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');runtime=cluster.pool('scan_runtime');repo=new PostgresCaseRepository(runtime);});
beforeEach(async()=>{await admin.query(`TRUNCATE safeathome_private.cases,safeathome_private.deleted_cases,safeathome_private.closed_accounts,safeathome_private.account_deletion_previews,safeathome_private.auth_deletion_jobs CASCADE;UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0`);});
after(async()=>{await target?.close();await cluster?.close();});
function request(caseId:string):ScanSave {
 const review=JSON.parse(fixture.request.reviewJson);review.caseId=caseId;
 const reviewJson=JSON.stringify(review).replace('"transform":[1,0,0,0','"transform":[1.0,0.0,-0.0,0.0');
 return {...fixture.request,caseId,mutationId:randomUUID(),reviewJson};
}
test('real RLS, independent clients, concurrent compare-and-swap and exact retries retain original model bytes',async()=>{
 const {caseId}=await create(repo),a=request(caseId),b={...request(caseId),reviewJson:null};
 const second=new PostgresCaseRepository(runtime);
 assert.equal((await runtime.query('SELECT * FROM safeathome_private.case_scan_models')).rowCount,0);
 const results=await Promise.all([repo.saveScanModelForUser(OWNER,a,at),second.saveScanModelForUser(OWNER,b,at)]);
 assert.deepEqual(results.map(r=>r.status).sort(),['found','model_conflict']);
 const winner=results.findIndex(r=>r.status==='found'),saved=await second.saveScanModelForUser(OWNER,[a,b][winner],at);
 assert.equal(saved.status,'found');if(saved.status==='found')assert.equal(saved.state.reviewJson,[a,b][winner].reviewJson);
 assert.equal((await repo.readScanModelForUser(OTHER,caseId,null)).status,'not_found');
 assert.equal((await repo.saveScanModelForUser(OTHER,a,at)).status,'not_found');
 assert.equal((await runtime.query('SELECT * FROM safeathome_private.case_scan_models')).rowCount,0);
});
test('model writes count against private storage and invalidate account-deletion preview without changing the case revision',async()=>{
 const {caseId}=await create(repo),tokenHash=createHash('sha256').update(randomUUID()).digest('hex');
 await repo.prepareAccountDeletion({userId:OWNER,tokenHash});
 const req=request(caseId);assert.equal((await repo.saveScanModelForUser(OWNER,req,at)).status,'found');
 const count=Number((await admin.query('SELECT stored_bytes FROM safeathome_private.repository_quota')).rows[0].stored_bytes);assert.ok(count>req.reviewJson!.length);
 const report=await readCapacityReport(admin);assert.equal(report.rows.case_scan_models,1);assert.equal(report.quota.consistent,true);assert.equal(report.quota.observed.binaryBytes,count);
 assert.deepEqual(await repo.confirmAccountDeletion({userId:OWNER,tokenHash}),{status:'changed'});
 assert.equal((await repo.loadForUser(OWNER,caseId))?.revision,1);
 assert.equal((await repo.deleteCaseIfCurrent({userId:OWNER,caseId,revision:1,expectedCatalogRevision:0})).status,'deleted');
 assert.equal((await admin.query('SELECT * FROM safeathome_private.case_scan_models')).rowCount,0);
 assert.equal(Number((await admin.query('SELECT stored_bytes FROM safeathome_private.repository_quota')).rows[0].stored_bytes),0);
});
test('named-room models and legacy models restore after database restart and private backup; legacy archives normalize absent model tables',async()=>{
 const {caseId}=await create(repo),legacy=request(caseId),roomId='fictional-bedroom';
 await repo.saveHomeSafetyForUser(OWNER,{schemaVersion:'3',caseId,expectedCaseRevision:1,expectedSafetyRevision:0,mutationId:randomUUID(),operation:{type:'add_room',room:{id:roomId,type:'bedroom',name:'Fictional bedroom'}}},at);
 const namedReview={...JSON.parse(legacy.reviewJson!),version:2,roomId,roomType:'bedroom'};
 const named={...request(caseId),roomId,reviewJson:JSON.stringify(namedReview)};
 await repo.saveScanModelForUser(OWNER,legacy,at);await repo.saveScanModelForUser(OWNER,named,at);
 const expected=await repo.readScanModelForUser(OWNER,caseId,roomId),origin='https://fictional-model.supabase.co';
 const archive=await captureDatabaseBackup(admin,origin);await cluster.restart();
 admin=cluster.pool();runtime=cluster.pool('scan_runtime');repo=new PostgresCaseRepository(runtime);
 assert.deepEqual(await repo.readScanModelForUser(OWNER,caseId,roomId),expected);
 target=await TestPostgres.start();const targetAdmin=target.pool();await applyMigrations(targetAdmin);await restoreDatabaseBackup(targetAdmin,archive,origin);
 await targetAdmin.query('CREATE ROLE restored_scan LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
 const restored=new PostgresCaseRepository(targetAdmin);
 assert.deepEqual(await restored.readScanModelForUser(OWNER,caseId,roomId),expected);
 const restoredLegacy=await restored.readScanModelForUser(OWNER,caseId,null);if(restoredLegacy.status==='found')assert.equal(restoredLegacy.state.reviewJson,legacy.reviewJson);
 const old=JSON.parse(archive.toString('utf8'));old.migrations=old.migrations.slice(0,10);
 delete old.tables.case_scan_models;delete old.tables.share_sensitive;
 for(const row of old.tables.case_shares){delete row.sensitive_scope;delete row.recipient_email_hash;delete row.invited_email;}
 old.tables.repository_quota[0].stored_bytes='0';
 assert.equal((await validateDatabaseBackup(Buffer.from(JSON.stringify(old)),origin)).sourceRows.case_scan_models,0);
});
test('storage limit refuses growth without replacing a model, then deletion remains possible',async()=>{
 const {caseId}=await create(repo),req=request(caseId);await repo.saveScanModelForUser(OWNER,req,at);
 const prior=await repo.readScanModelForUser(OWNER,caseId,null);
 await admin.query('UPDATE safeathome_private.repository_quota SET stored_bytes=67108864');
 const altered=JSON.parse(req.reviewJson!);altered.scene.sourceVersion+=' longer';
 assert.equal((await repo.saveScanModelForUser(OWNER,{...req,expectedModelRevision:1,mutationId:randomUUID(),reviewJson:JSON.stringify(altered)},at)).status,'limit');
 assert.deepEqual(await repo.readScanModelForUser(OWNER,caseId,null),prior);
 assert.equal((await repo.saveScanModelForUser(OWNER,{...req,expectedModelRevision:1,mutationId:randomUUID(),reviewJson:null},at)).status,'found');
});
