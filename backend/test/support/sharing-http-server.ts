import { demoProgram } from '../../fixtures/demo-program.ts';
import { randomUUID } from 'node:crypto';
import { DisposablePostgres } from '../../tool/disposable-postgres.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { PostgresSharingRepository } from '../../src/sharing/postgres-sharing-repository.ts';
import { createMatchingServer } from '../../src/api/http-server.ts';
import { OWNER, create } from '../postgres/fixtures.ts';
const viewer='22222222-2222-4222-8222-222222222222',helper='33333333-3333-4333-8333-333333333333',other='44444444-4444-4444-8444-444444444444';
const cluster=await DisposablePostgres.start();
try {
 const admin=cluster.pool();await applyMigrations(admin);
 await admin.query('CREATE ROLE sharing_http_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
 const pool=cluster.pool('sharing_http_runtime'),cases=new PostgresCaseRepository(pool),sharing=new PostgresSharingRepository(pool,async()=>[demoProgram]);
 const snapshot=await create(cases),tokens:Record<string,string>={'fictional-owner-token':OWNER,'fictional-viewer-token':viewer,'fictional-helper-token':helper,'fictional-other-token':other};
 await cases.saveProgressForUser(OWNER,{schemaVersion:'3',caseId:snapshot.caseId,expectedCaseRevision:1,expectedProgressRevision:0,mutationId:randomUUID(),operation:{type:'put_task',expectedTaskRevision:0,task:{id:'fictional-http-task',programId:null,findingId:'fictional-finding',formId:null,title:'Fictional shared next step',kind:'room_review',state:'pending',responsiblePerson:null,dueOn:null,basedOnCaseRevision:1,basedOnRuleVersion:null,revision:1,sourceEventId:null}}},new Date().toISOString(),[demoProgram]);
 await cases.saveProgressForUser(OWNER,{schemaVersion:'3',caseId:snapshot.caseId,expectedCaseRevision:1,expectedProgressRevision:1,mutationId:randomUUID(),operation:{type:'track_program',programId:demoProgram.programId}},new Date().toISOString(),[demoProgram]);
 const authenticate=async(token:string)=>tokens[token]?{userId:tokens[token]}:null;
 const deps={authenticate,cases,now:()=>new Date(),loadRegistry:async()=>[]};
 const server=createMatchingServer(deps,undefined,undefined,undefined,undefined,undefined,{sharingDependencies:{authenticate,sharing,collaborationEnabled:true}});
 await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const address=server.address();if(!address||typeof address==='string')throw Error();
 process.stdout.write(JSON.stringify({origin:'http://127.0.0.1:'+address.port,caseId:snapshot.caseId,revision:snapshot.revision,programId:demoProgram.programId,viewer,helper,other})+'\n');
 await new Promise<void>(resolve=>{const stop=()=>{server.closeAllConnections();server.close(()=>resolve());};process.once('SIGTERM',stop);process.once('SIGINT',stop);});
}finally{await cluster.close();}
