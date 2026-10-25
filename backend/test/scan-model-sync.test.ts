import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID,createHash } from 'node:crypto';
import test from 'node:test';
import { parseScanRequest,parseScanReview,parseScanScene,decodeScanRecord,type ScanSave } from '../src/assessment/scan-model.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleScanModel } from '../src/api/scan-model.ts';
import { draft } from './postgres/fixtures.ts';
const fixtures=JSON.parse(readFileSync(new URL('../../contracts/v3/fixtures/scan-model-sync.json',import.meta.url),'utf8'));
const at='2026-10-24T18:00:00.000Z',caseId=fixtures[0].request.caseId;
function request(index=0):ScanSave{return structuredClone(fixtures[index].request);}
const repo=()=>new MemoryCaseRepository([{userId:'alice',snapshot:{...draft(caseId),revision:1}}]);
async function room(r:MemoryCaseRepository,id:string,revision:number){await r.saveHomeSafetyForUser('alice',{schemaVersion:'3',caseId,expectedCaseRevision:1,expectedSafetyRevision:revision,mutationId:randomUUID(),operation:{type:'add_room',room:{id,type:'bedroom',name:'Fictional room'}}},at);}
test('all native source fixtures retain exact JSON, negative zero and checksum across account restore',async()=>{
 const r=repo();await room(r,'room-1',0);await room(r,'room-2',1);
 for(let i=0;i<fixtures.length;i++){
  const req=request(i);assert.deepEqual(parseScanRequest(req,true),req);
  const saved=await r.saveScanModelForUser('alice',req,at);assert.equal(saved.status,'found');if(saved.status!=='found')throw Error();
  assert.equal(saved.state.reviewJson,req.reviewJson);assert.match(saved.state.reviewJson!,/-0\.0/);
  assert.equal(saved.state.reviewSha256,createHash('sha256').update(req.reviewJson!).digest('hex'));
  const copy=await r.readScanModelForUser('alice',caseId,req.roomId);assert.equal(copy.status,'found');if(copy.status==='found')assert.equal(copy.state.reviewJson,req.reviewJson);
 }
});
test('owner isolation, case/model revisions, retry identity and tombstones never silently overwrite',async()=>{
 const r=repo(),req=request();
 assert.equal((await r.readScanModelForUser('bob',caseId,null)).status,'not_found');
 assert.equal((await r.saveScanModelForUser('bob',req,at)).status,'not_found');
 assert.equal((await r.saveScanModelForUser('alice',{...req,expectedCaseRevision:2},at)).status,'conflict');
 const saved=await r.saveScanModelForUser('alice',req,at);assert.equal(saved.status,'found');
 assert.equal((await r.saveScanModelForUser('alice',req,at)).status,'found');
 assert.equal((await r.saveScanModelForUser('alice',{...req,reviewJson:null},at)).status,'mutation_conflict');
 assert.equal((await r.saveScanModelForUser('alice',{...req,mutationId:randomUUID()},at)).status,'model_conflict');
 const removed=await r.saveScanModelForUser('alice',{...req,mutationId:randomUUID(),expectedModelRevision:1,reviewJson:null},at);assert.equal(removed.status,'found');
 const retry=await r.saveScanModelForUser('alice',req,at);assert.equal(retry.status,'found');if(retry.status==='found'){assert.equal(retry.state.reviewJson,null);assert.equal(retry.state.modelRevision,2);}
 assert.equal((await r.loadForUser('alice',caseId))?.revision,1);
});
test('wrong/missing rooms and exhausted private storage preserve existing models',async()=>{
 const r=repo();assert.equal((await r.saveScanModelForUser('alice',request(1),at)).status,'not_found');
 const limited=new MemoryCaseRepository([{userId:'alice',snapshot:{...draft(caseId),revision:1}}],{maxBytes:0,maxAssets:0,maxArtifacts:0});
 assert.equal((await limited.saveScanModelForUser('alice',request(),at)).status,'limit');
 const read=await limited.readScanModelForUser('alice',caseId,null);if(read.status==='found')assert.equal(read.state.modelRevision,0);
});
test('strict geometry, provenance, room and pending capture boundaries reject malformed uploads',()=>{
 const original=JSON.parse(request().reviewJson!);
 const mutations=[
  (r:any)=>r.scene.image='data:private', (r:any)=>r.pendingScanId=randomUUID(),(r:any)=>r.reviewed=['missing'],
  (r:any)=>r.labels={missing:'wall'},(r:any)=>r.scene.elements[0].transform[0]=2,
  (r:any)=>r.scene.elements[0].transform[12]=50,(r:any)=>r.scene.points=[[0,0,0,2]],
  (r:any)=>r.scene.source='arcore',(r:any)=>r.scene.coverage='complete',
  (r:any)=>r.scene.elements[0].dimensions=[1,0,0],(r:any)=>r.scene.elements[0].transform[15]=0,
 ];
 for(const mutate of mutations){const value=structuredClone(original);mutate(value);assert.throws(()=>parseScanReview(value,caseId));}
 assert.throws(()=>parseScanRequest({...request(),ownerId:'bob'},true));
 assert.throws(()=>parseScanRequest({...request(1),roomId:'wrong'},true));
 assert.throws(()=>parseScanScene({...original.scene,points:Array(4097).fill([0,0,0,1])}));
 assert.throws(()=>decodeScanRecord(Buffer.from([255])));
});
test('API authenticates, returns owner-only no-store responses and does not expose payload errors',async()=>{
 const r=repo(),deps={cases:r,authenticate:async(token:string)=>token==='alice'?{userId:'alice'}:null,now:()=>new Date(at)};
 const success=await handleScanModel({body:request(),bearerToken:'alice'},deps,'save-scan-model');assert.equal(success.status,200);assert.equal(success.headers['Cache-Control'],'no-store');
 const denied=await handleScanModel({body:request(),bearerToken:'invalid'},deps,'save-scan-model');assert.equal(denied.status,401);
 const malformed=await handleScanModel({body:{...request(),reviewJson:'PRIVATE_MALFORMED'},bearerToken:'alice'},deps,'save-scan-model');assert.equal(malformed.status,400);assert.ok(!JSON.stringify(malformed).includes('PRIVATE_MALFORMED'));
});
