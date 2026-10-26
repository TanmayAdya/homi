import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {before,beforeEach,after,test} from 'node:test';
import type {Pool} from 'pg';
import {TestPostgres} from './harness.ts';
import {OWNER,OTHER,create} from './fixtures.ts';
import {applyMigrations} from '../../src/storage/migrate.ts';
import {PostgresCaseRepository} from '../../src/storage/postgres-case-repository.ts';
import {parseSafetyOperation,type HomeSafetySave,type SafetyOperation} from '../../src/assessment/home-safety.ts';
import {reportLines} from '../../src/assessment/home-safety-report.ts';
import {captureDatabaseBackup,restoreDatabaseBackup} from '../../src/storage/database-backup.ts';
import {readCapacityReport} from '../../src/storage/capacity-report.ts';
import type {ScanSave} from '../../src/assessment/scan-model.ts';
let cluster:TestPostgres,admin:Pool,runtime:Pool,repo:PostgresCaseRepository;
const at='2026-10-25T18:00:00.000Z',roomId='fictional-bedroom';
before(async()=>{cluster=await TestPostgres.start();admin=cluster.pool();await applyMigrations(admin);await admin.query('CREATE ROLE room_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');runtime=cluster.pool('room_runtime');repo=new PostgresCaseRepository(runtime);});
beforeEach(async()=>{await admin.query('TRUNCATE safeathome_private.cases,safeathome_private.deleted_cases,safeathome_private.closed_accounts,safeathome_private.account_deletion_previews,safeathome_private.auth_deletion_jobs CASCADE;UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0');});
after(async()=>{await cluster?.close();});
const request=(caseId:string,operation:SafetyOperation,rev:number):HomeSafetySave=>({schemaVersion:'3',caseId,operation,expectedCaseRevision:1,expectedSafetyRevision:rev,mutationId:randomUUID()});
async function seed(){
 const snapshot=await create(repo),caseId=snapshot.caseId;
 await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'add_room',room:{id:roomId,type:'bedroom',name:'Fictional bedroom'}},0),at);
 await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'assign_finding',roomId,findingId:'fictional-finding'},1),at);
 const fixture=JSON.parse(readFileSync(new URL('../../../contracts/v3/fixtures/scan-model-sync.json',import.meta.url),'utf8'))[1];
 const review={...JSON.parse(fixture.request.reviewJson),caseId,roomId};
 const model:ScanSave={...fixture.request,caseId,roomId,mutationId:randomUUID(),reviewJson:JSON.stringify(review)};
 assert.equal((await repo.saveScanModelForUser(OWNER,model,at)).status,'found');
 const task={id:randomUUID(),programId:null,findingId:'fictional-finding',formId:null,title:'Fictional linked next step',kind:'room_review' as const,state:'pending' as const,responsiblePerson:null,dueOn:'2026-11-01',basedOnCaseRevision:1,basedOnRuleVersion:null,revision:1,sourceEventId:null};
 assert.equal((await repo.saveProgressForUser(OWNER,{schemaVersion:'3',caseId,expectedCaseRevision:1,expectedProgressRevision:0,mutationId:randomUUID(),operation:{type:'put_task',expectedTaskRevision:0,task}},at,[])).status,'found');
 return {snapshot,caseId,model};
}
async function state(caseId:string){const s=await repo.readHomeSafetyForUser(OWNER,caseId);assert.equal(s.status,'found');if(s.status!=='found')throw Error();return s.state;}
test('archive and restore preserve model, findings and tasks; permanent deletion is atomic and never recreates a retired room',async()=>{
 const {snapshot,caseId,model}=await seed(),progress=await repo.readProgressForUser(OWNER,caseId),initial=await repo.readScanModelForUser(OWNER,caseId,roomId);
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'delete_room',roomId,expectedModelRevision:1},2),at)).status,'invalid_operation');
 const archive=request(caseId,{type:'archive_room',roomId},2);
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,archive,at)).status,'found');
 assert.equal((await state(caseId)).safety.document.rooms[0].archived,true);
 assert.deepEqual(await repo.readScanModelForUser(OWNER,caseId,roomId),initial);
 assert.equal((await repo.saveHomeSafetyForUser(OTHER,request(caseId,{type:'restore_room',roomId},3),at)).status,'not_found');
 assert.equal((await repo.saveScanModelForUser(OWNER,{...model,mutationId:randomUUID(),expectedModelRevision:1},at)).status,'not_found');
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'answer',roomId,questionId:'bedroom.path',value:'yes'},3),at)).status,'invalid_operation');
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'restore_room',roomId},3),at)).status,'found');
 assert.equal(Object.hasOwn((await state(caseId)).safety.document.rooms[0],'archived'),false);
 await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'archive_room',roomId},4),at);
 const deletion=request(caseId,{type:'delete_room',roomId,expectedModelRevision:1},5);
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,deletion,at)).status,'found');
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,deletion,at)).status,'found');
 const saved=await state(caseId);assert.deepEqual(saved.case,snapshot);assert.deepEqual(saved.safety.document.rooms,[]);assert.deepEqual(saved.safety.document.findingRooms,[]);
 assert.deepEqual(await repo.readProgressForUser(OWNER,caseId),progress);
 assert.equal((await admin.query('SELECT record FROM safeathome_private.case_scan_models')).rowCount,0);
 assert.equal((await readCapacityReport(admin)).quota.observed.binaryBytes,0);
 assert.notEqual((await repo.saveScanModelForUser(OWNER,model,at)).status,'found');
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'add_room',room:{id:roomId,type:'bedroom',name:'Cannot resurrect'}},6),at)).status,'invalid_operation');
});
test('changed account model revision refuses deletion and retains checklist and geometry until reconfirmed',async()=>{
 const {caseId,model}=await seed();await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'archive_room',roomId},2),at);
 await repo.saveScanModelForUser(OWNER,{...model,mutationId:randomUUID(),expectedModelRevision:1,reviewJson:null},at);
 const before=await state(caseId);
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'delete_room',roomId,expectedModelRevision:1},3),at)).status,'safety_conflict');
 assert.deepEqual(await state(caseId),before);
 assert.equal((await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'delete_room',roomId,expectedModelRevision:2},3),at)).status,'found');
 assert.equal((await readCapacityReport(admin)).quota.consistent,true);
});
test('archived rooms remain labelled in reports and private backups and survive a process restart',async()=>{
 const {caseId}=await seed();await repo.saveHomeSafetyForUser(OWNER,request(caseId,{type:'archive_room',roomId},2),at);
 const expected=await state(caseId),origin='https://fictional-room-archive.supabase.co';
 assert.ok(reportLines(expected,{schemaVersion:'1',caseId,caseRevision:1,catalogRevision:0,evidence:[]},at,false,false).some(l=>l.includes('room status: archived')));
 const archive=await captureDatabaseBackup(admin,origin);await cluster.restart();admin=cluster.pool();runtime=cluster.pool('room_runtime');repo=new PostgresCaseRepository(runtime);assert.deepEqual(await state(caseId),expected);
 const target=await TestPostgres.start();try{const db=target.pool();await applyMigrations(db);await restoreDatabaseBackup(db,archive,origin);await db.query('CREATE ROLE restored_room LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');const restored=new PostgresCaseRepository(db);assert.deepEqual(await restored.readHomeSafetyForUser(OWNER,caseId),{status:'found',state:expected});}finally{await target.close();}
});
test('strict room lifecycle contracts reject ambiguous archive values and malformed delete revisions',()=>{
 for(const operation of [{type:'delete_room',roomId,expectedModelRevision:-1},{type:'delete_room',roomId},{type:'archive_room',roomId,deleteFindings:true},{type:'add_room',room:{id:roomId,type:'bedroom',name:null,archived:true}}])assert.throws(()=>parseSafetyOperation(operation));
});
