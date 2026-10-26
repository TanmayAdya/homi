import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID,createHash} from 'node:crypto';
import {before,after,beforeEach,test} from 'node:test';
import type {Pool} from 'pg';
import {TestPostgres} from './harness.ts';
import {applyMigrations} from '../../src/storage/migrate.ts';
import {PostgresCaseRepository} from '../../src/storage/postgres-case-repository.ts';
import {captureDatabaseBackup,restoreDatabaseBackup,validateDatabaseBackup} from '../../src/storage/database-backup.ts';
import {readCapacityReport} from '../../src/storage/capacity-report.ts';
import {OWNER,OTHER,create} from './fixtures.ts';
import {type HomeSave} from '../../src/assessment/home-model.ts';
let cluster:TestPostgres,admin:Pool,runtime:Pool,repo:PostgresCaseRepository;
const f=JSON.parse(readFileSync(new URL('../../../contracts/v3/fixtures/home-model-sync.json',import.meta.url),'utf8'))[0];
const at='2026-10-25T18:00:00.000Z';
before(async()=>{cluster=await TestPostgres.start();admin=cluster.pool();await applyMigrations(admin);await admin.query('CREATE ROLE home_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');runtime=cluster.pool('home_runtime');repo=new PostgresCaseRepository(runtime);});
beforeEach(async()=>{await admin.query('TRUNCATE safeathome_private.cases,safeathome_private.deleted_cases,safeathome_private.closed_accounts,safeathome_private.account_deletion_previews,safeathome_private.auth_deletion_jobs CASCADE;UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0');});
after(async()=>{await cluster?.close();});
async function seed():Promise<HomeSave>{const {caseId}=await create(repo);for(const [i,id] of ['room-1','room-2'].entries())assert.equal((await repo.saveHomeSafetyForUser(OWNER,{schemaVersion:'3',caseId,expectedCaseRevision:1,expectedSafetyRevision:i,mutationId:randomUUID(),operation:{type:'add_room',room:{id,type:'bedroom',name:null}}},at)).status,'found');const b=JSON.parse(f.request.bundleJson);b.caseId=caseId;b.model.caseId=caseId;return {...f.request,caseId,mutationId:randomUUID(),bundleJson:JSON.stringify(b)};}
test('RLS and concurrent revisions isolate owner layouts and retain exact bytes',async()=>{
 const input=await seed(),second=new PostgresCaseRepository(runtime);
 const results=await Promise.all([repo.saveHomeModelForUser(OWNER,input,at),second.saveHomeModelForUser(OWNER,{...input,mutationId:randomUUID(),bundleJson:null},at)]);
 assert.deepEqual(results.map(r=>r.status).sort(),['found','model_conflict']);
 assert.equal((await runtime.query('SELECT * FROM safeathome_private.case_scan_models')).rowCount,0);
 assert.equal((await repo.readHomeModelForUser(OTHER,input.caseId)).status,'not_found');assert.equal((await repo.saveHomeModelForUser(OTHER,input,at)).status,'not_found');
 assert.equal((await readCapacityReport(admin)).quota.consistent,true);
});
test('restart and quarantined backup restore recover home bundle; corrupted source bindings are rejected',async()=>{
 const input=await seed();await repo.saveHomeModelForUser(OWNER,input,at);const expected=await repo.readHomeModelForUser(OWNER,input.caseId),origin='https://fictional-home.supabase.co';
 const backup=await captureDatabaseBackup(admin,origin);assert.equal((await validateDatabaseBackup(backup,origin)).sourceRows.case_scan_models,1);
 await cluster.restart();admin=cluster.pool();runtime=cluster.pool('home_runtime');repo=new PostgresCaseRepository(runtime);assert.deepEqual(await repo.readHomeModelForUser(OWNER,input.caseId),expected);
 const target=await TestPostgres.start();try{const db=target.pool();await applyMigrations(db);await restoreDatabaseBackup(db,backup,origin);assert.equal((await db.query("SELECT record FROM safeathome_private.case_scan_models WHERE room_key='home'")).rows[0].record.toString(),(await admin.query("SELECT record FROM safeathome_private.case_scan_models WHERE room_key='home'")).rows[0].record.toString());}finally{await target.close();}
 const tampered=JSON.parse(backup.toString()),record=JSON.parse(Buffer.from(tampered.tables.case_scan_models[0].record,'base64').toString());const bundle=JSON.parse(record.bundleJson);bundle.model.rooms[1].fingerprint='f'.repeat(64);record.bundleJson=JSON.stringify(bundle);tampered.tables.case_scan_models[0].record=Buffer.from(JSON.stringify(record)).toString('base64');await assert.rejects(validateDatabaseBackup(Buffer.from(JSON.stringify(tampered)),origin));
});
test('room deletion removes all assembly geometry, quota shrinks, and acknowledged old uploads cannot recreate it',async()=>{
 const input=await seed();await repo.saveHomeModelForUser(OWNER,input,at);
 for(const [i,operation] of [{type:'archive_room' as const,roomId:'room-1'},{type:'delete_room' as const,roomId:'room-1',expectedModelRevision:0}].entries())assert.equal((await repo.saveHomeSafetyForUser(OWNER,{schemaVersion:'3',caseId:input.caseId,expectedCaseRevision:1,expectedSafetyRevision:i+2,mutationId:randomUUID(),operation},at)).status,'found');
 const retry=await repo.saveHomeModelForUser(OWNER,input,at);assert.equal(retry.status,'found');if(retry.status==='found'){assert.equal(retry.state.bundleJson,null);assert.equal(retry.state.modelRevision,2);}
 assert.equal((await readCapacityReport(admin)).quota.consistent,true);
 assert.ok(Number((await admin.query('SELECT stored_bytes FROM safeathome_private.repository_quota')).rows[0].stored_bytes)<1024);
 const origin='https://fictional-home.supabase.co';await validateDatabaseBackup(await captureDatabaseBackup(admin,origin),origin);
});
test('account-deletion preview observes model changes, case deletion removes all bytes, quota limits preserve prior copies',async()=>{
 const input=await seed(),tokenHash=createHash('sha256').update(randomUUID()).digest('hex');await repo.prepareAccountDeletion({userId:OWNER,tokenHash});await repo.saveHomeModelForUser(OWNER,input,at);assert.deepEqual(await repo.confirmAccountDeletion({userId:OWNER,tokenHash}),{status:'changed'});
 await admin.query('UPDATE safeathome_private.repository_quota SET stored_bytes=67108864');const bundle=JSON.parse(input.bundleJson!);bundle.model.rooms[1].pose.x=12.125;
 assert.equal((await repo.saveHomeModelForUser(OWNER,{...input,bundleJson:JSON.stringify(bundle),expectedModelRevision:1,mutationId:randomUUID()},at)).status,'limit');
 const size=Number((await admin.query('SELECT sum(octet_length(record)) AS bytes FROM safeathome_private.case_scan_models')).rows[0].bytes);await admin.query('UPDATE safeathome_private.repository_quota SET stored_bytes=$1',[size]);
 assert.equal((await repo.deleteCaseIfCurrent({userId:OWNER,caseId:input.caseId,revision:1,expectedCatalogRevision:0})).status,'deleted');assert.equal((await readCapacityReport(admin)).quota.consistent,true);assert.equal((await admin.query('SELECT record FROM safeathome_private.case_scan_models')).rowCount,0);
});
