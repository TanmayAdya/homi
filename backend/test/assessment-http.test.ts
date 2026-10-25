import assert from 'node:assert/strict';
import test from 'node:test';
import type { AddressInfo } from 'node:net';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { createDemoFormArtifact } from '../fixtures/demo-form-template.ts';
import { demoProgram } from '../fixtures/demo-program.ts';
import { create, OWNER, OTHER } from './postgres/fixtures.ts';
import { caseFingerprint } from '../src/evidence/validation.ts';

test('real HTTP v2 assessment uses ownership, exact retry, strict v1 snapshot and versioned form routing',async t=>{
 const cases=new MemoryCaseRepository([]),snapshot=await create(cases),form=await createDemoFormArtifact(demoProgram.programId);
 const deps={cases,authenticate:async(token:string)=>token==='alice'?{userId:OWNER}:token==='bob'?{userId:OTHER}:null,
  now:()=>new Date(),loadRegistry:async()=>[demoProgram],loadFormTemplate:async()=>form,allowDemoPrograms:true};
 const server=createMatchingServer(deps,deps,deps,deps,deps,undefined,{assessmentDependencies:deps,programIntakeDependencies:deps});
 await new Promise<void>(resolve=>server.listen(0,'127.0.0.1',resolve));
 t.after(()=>new Promise<void>(resolve=>{server.close(()=>resolve());server.closeAllConnections();}));
 const endpoint=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;
 const post=(route:string,body:unknown,token='alice')=>fetch(`${endpoint}${route}`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify(body)});
 const read={schemaVersion:'2',caseId:snapshot.caseId};
 const response=await post('/v2/read-assessment',read);assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'no-store');
 const state=await response.json();assert.equal(state.case.schemaVersion,'1');assert.equal(state.assessment.assessmentRevision,0);
 assert.equal((await post('/v2/read-assessment',read,'bob')).status,404);
 const {revision,...draft}=snapshot;
 const save={schemaVersion:'2',caseId:snapshot.caseId,expectedCaseRevision:1,expectedCaseFingerprint:caseFingerprint(snapshot),expectedCatalogRevision:0,expectedAssessmentRevision:0,
 mutationId:'http-assessment-save',draft,metadata:{measurements:[],reviews:[{findingId:'fictional-finding',state:'confirmed',note:null}]}};
 const written=await post('/v2/save-assessment',save);assert.equal(written.status,200);const stored=await written.json();assert.equal(stored.case.revision,2);
 assert.deepEqual(await (await post('/v2/save-assessment',save)).json(),stored);
 assert.equal((await post('/v2/save-assessment',{...save,metadata:{...save.metadata,history:[]}})).status,400);
 const formRead=await post('/v2/read-form-answers',{schemaVersion:'2',caseId:snapshot.caseId,expectedCaseRevision:2,programId:demoProgram.programId});
 assert.equal(formRead.status,200);const formBody=await formRead.json();assert.equal(formBody.schemaVersion,'2');assert.ok(Array.isArray(formBody.fieldDefinitions));
 const intake=await post('/v2/read-program-intake',{schemaVersion:'2',caseId:snapshot.caseId,expectedCaseRevision:2,programId:'hpsm-eaa'});
 assert.equal(intake.status,200);assert.equal((await intake.json()).saved,null);
});
