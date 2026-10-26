import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { PDFDocument } from 'pdf-lib';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleHomeSafety } from '../src/api/home-safety.ts';
import { draft } from './postgres/fixtures.ts';
import { reportLines, renderHomeSafetyReport } from '../src/assessment/home-safety-report.ts';
import { STEADI_CATALOG, type SafetyOperation } from '../src/assessment/home-safety.ts';
async function setup() {
 const caseId=randomUUID(),owner='fictional-owner';
 const cases=new MemoryCaseRepository([{userId:owner,snapshot:{...draft(caseId),revision:1}}]);
 const deps={cases,authenticate:async(token:string)=>token===owner?{userId:owner}:token==='other'?{userId:'other'}:null,now:()=>new Date('2026-10-25T12:00:00.000Z')};
 async function save(operation:SafetyOperation){const read=await cases.readHomeSafetyForUser(owner,caseId);if(read.status!=='found')throw Error();const request={schemaVersion:'3' as const,caseId,expectedCaseRevision:read.state.case.revision,expectedSafetyRevision:read.state.safety.revision,mutationId:randomUUID(),operation};return {request,result:await cases.saveHomeSafetyForUser(owner,request,deps.now().toISOString())};}
 await save({type:'add_room',room:{id:'room-one',type:'bathroom',name:'Fictional first bathroom'}});
 await save({type:'add_room',room:{id:'room-two',type:'bathroom',name:'Fictional second bathroom'}});
 return {caseId,owner,cases,deps,save};
}
const questionId=STEADI_CATALOG.questions.find(q=>q.rooms.includes('bathroom'))!.id;
test('notes preserve unknown answers and originals; exact retries, stale bindings and forged references are checked',async()=>{
 const h=await setup(),op:Extract<SafetyOperation,{type:'annotate_answer'}>={type:'annotate_answer',roomId:'room-one',questionId,answerRevision:0,note:'Fictional private note',expectedCatalogRevision:0,evidence:[]};
 const first=await h.save(op);assert.equal(first.result.status,'found');assert.equal((await h.cases.saveHomeSafetyForUser(h.owner,first.request,h.deps.now().toISOString())).status,'found');
 assert.equal((await h.save({...op,evidence:[{evidenceId:'not-owned',expectedEvidenceRevision:1}]})).result.status,'evidence_conflict');
 assert.equal((await h.save({...op,answerRevision:1})).result.status,'invalid_operation');await h.save({...op,note:'Fictional corrected note'});
 const read=await h.cases.readHomeSafetyForUser(h.owner,h.caseId);if(read.status!=='found')throw Error();
 assert.equal(read.state.case.revision,1);assert.equal(read.state.safety.document.answers.length,0);assert.equal(read.state.safety.history.length,4);assert.equal((read.state.safety.history[2].operation as any).note,'Fictional private note');
});
test('reports are owner only, revision bound, complete and opt-in for notes; a rendering race rejects stale bytes',async()=>{
 const h=await setup();await h.save({type:'annotate_answer',roomId:'room-one',questionId,answerRevision:0,note:'Fictional private note',expectedCatalogRevision:0,evidence:[]});
 const request={schemaVersion:'3',caseId:h.caseId,expectedCaseRevision:1,expectedSafetyRevision:3,expectedCatalogRevision:0,includeNotes:false,includeEvidenceReferences:false};
 const send=(body:unknown,token=h.owner)=>handleHomeSafety({body,bearerToken:token},h.deps,'export-home-safety');
 assert.equal((await send({...request,extra:true})).status,400);assert.equal((await send(request,'invalid')).status,401);assert.equal((await send(request,'other')).status,404);assert.equal((await send({...request,expectedSafetyRevision:2})).status,409);
 const result=await send(request);assert.equal(result.status,200);const body=result.body as any;
 assert.equal((await PDFDocument.load(Buffer.from(body.pdfBase64,'base64'))).getPageCount(),body.pageCount);assert.equal(result.headers['Cache-Control'],'no-store');
 const state=await h.cases.readHomeSafetyForUser(h.owner,h.caseId),evidence=await h.cases.readEvidenceCatalogForUser(h.owner,h.caseId);if(state.status!=='found'||evidence.status!=='found')throw Error();
 const lines=reportLines(state.state,evidence.catalog,h.deps.now().toISOString(),false,false).join('\n');assert.ok(lines.includes('[room-one]')&&lines.includes('[room-two]')&&lines.includes('Answer: unanswered'));assert.ok(!lines.includes('Fictional private note'));assert.ok(reportLines(state.state,evidence.catalog,h.deps.now().toISOString(),true,false).join('\n').includes('Fictional private note'));
 const original=h.cases.readHomeSafetyForUser.bind(h.cases);let reads=0;
 h.cases.readHomeSafetyForUser=async(user,id)=>{reads++;if(reads===2)await h.save({type:'rename_room',roomId:'room-one',name:'Changed during rendering'});return original(user,id);};
 assert.equal((await send(request)).status,409);
});
test('report renderer preserves supported text and fails on unsupported characters or excessive pages',async()=>{
 const report=await renderHomeSafetyReport(['Fictional bathroom report','中文房间','Unknown answers remain unknown.']);assert.equal((await PDFDocument.load(report.bytes)).getPageCount(),1);
 await assert.rejects(renderHomeSafetyReport(['Unsupported\u0001text']),/REPORT_UNSUPPORTED_TEXT/);await assert.rejects(renderHomeSafetyReport(Array.from({length:6000},()=>'')),/REPORT_LIMIT/);
});
