import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID,createHash} from 'node:crypto';
import test from 'node:test';
import {parseHomeRequest,parseHomeBundle,decodeHomeRecord,MAX_HOME_BUNDLE_BYTES,type HomeSave} from '../src/assessment/home-model.ts';
import {MemoryCaseRepository} from '../src/api/memory-case-repository.ts';
import {handleScanModel} from '../src/api/scan-model.ts';
import {draft} from './postgres/fixtures.ts';
const fixtures=JSON.parse(readFileSync(new URL('../../contracts/v3/fixtures/home-model-sync.json',import.meta.url),'utf8'));
const at='2026-10-25T18:00:00.000Z',caseId=fixtures[0].request.caseId;
function request(i=0):HomeSave{return structuredClone(fixtures[i].request);}
async function seed(){const r=new MemoryCaseRepository([{userId:'alice',snapshot:{...draft(caseId),revision:1}}]);for(const [i,id] of ['room-1','room-2'].entries())await r.saveHomeSafetyForUser('alice',{schemaVersion:'3',caseId,expectedCaseRevision:1,expectedSafetyRevision:i,mutationId:randomUUID(),operation:{type:'add_room',room:{id,type:'bedroom',name:null}}},at);return r;}
test('Dart fixture geometry and fingerprints survive all aligned and shared-frame sources',async()=>{
 for(const [i,f] of fixtures.entries()){
  const r=await seed(),input=request(i);assert.deepEqual(parseHomeRequest(input,true),input,f.name);
  const saved=await r.saveHomeModelForUser('alice',input,at);assert.equal(saved.status,'found',f.name);
  if(saved.status==='found'){assert.equal(saved.state.bundleJson,input.bundleJson);assert.equal(saved.state.bundleSha256,createHash('sha256').update(input.bundleJson!).digest('hex'));}
 }
});
test('owner isolation, concurrent revisions, exact retries and removal preserve device intent',async()=>{
 const r=await seed(),input=request();
 assert.equal((await r.readHomeModelForUser('bob',caseId)).status,'not_found');assert.equal((await r.saveHomeModelForUser('bob',input,at)).status,'not_found');
 assert.equal((await r.saveHomeModelForUser('alice',{...input,expectedCaseRevision:2},at)).status,'conflict');
 assert.equal((await r.saveHomeModelForUser('alice',input,at)).status,'found');
 assert.equal((await r.saveHomeModelForUser('alice',{...input,mutationId:randomUUID()},at)).status,'model_conflict');
 assert.equal((await r.saveHomeModelForUser('alice',{...input,bundleJson:null},at)).status,'mutation_conflict');
 assert.equal((await r.saveHomeModelForUser('alice',{...input,bundleJson:null,mutationId:randomUUID(),expectedModelRevision:1},at)).status,'found');
 const retry=await r.saveHomeModelForUser('alice',input,at);assert.equal(retry.status,'found');if(retry.status==='found'){assert.equal(retry.state.bundleJson,null);assert.equal(retry.state.modelRevision,2);}
});
test('strict bundles reject cycles, unreviewed placements, swapped sources, unknown rooms, private payloads and excessive size',async()=>{
 const input=request(),original=JSON.parse(input.bundleJson!);
 const mutations=[(b:any)=>b.model.rooms[1].parentId='room-2',(b:any)=>b.model.rooms[1].reviewed=false,(b:any)=>b.model.rooms[0].pose.yaw=2,(b:any)=>b.sources['room-2']=b.sources['room-1'],(b:any)=>b.model.rooms[1].parentFingerprint='0'.repeat(64),(b:any)=>b.roomTypes['room-1']='outdoorPaths',(b:any)=>b.image='private image',(b:any)=>b.model.rooms[1].pose.x=101,(b:any)=>b.sources['extra']=b.sources['room-1']];
 for(const mutate of mutations){const b=structuredClone(original);mutate(b);assert.throws(()=>parseHomeBundle(JSON.stringify(b),caseId));}
 assert.throws(()=>parseHomeBundle('x'.repeat(MAX_HOME_BUNDLE_BYTES+1),caseId));assert.throws(()=>decodeHomeRecord(Buffer.from([255])));
 const r=new MemoryCaseRepository([{userId:'alice',snapshot:{...draft(caseId),revision:1}}]);assert.equal((await r.saveHomeModelForUser('alice',input,at)).status,'conflict');
});
test('permanent room deletion erases assembly geometry and old retries acknowledge the tombstone',async()=>{
 const r=await seed(),input=request();await r.saveHomeModelForUser('alice',input,at);
 const op=async(operation:any,rev:number)=>r.saveHomeSafetyForUser('alice',{schemaVersion:'3',caseId,expectedCaseRevision:1,expectedSafetyRevision:rev,mutationId:randomUUID(),operation},at);
 assert.equal((await op({type:'archive_room',roomId:'room-1'},2)).status,'found');
 assert.equal((await op({type:'delete_room',roomId:'room-1',expectedModelRevision:0},3)).status,'found');
 const state=await r.saveHomeModelForUser('alice',input,at);assert.equal(state.status,'found');if(state.status==='found'){assert.equal(state.state.bundleJson,null);assert.equal(state.state.modelRevision,2);}
 assert.equal((await r.saveHomeModelForUser('alice',{...input,mutationId:randomUUID(),expectedModelRevision:2},at)).status,'conflict');
});
test('home endpoints keep private responses no-store and reject invalid auth/body without leaking fields',async()=>{
 const cases=await seed(),deps={cases,authenticate:async(token:string)=>token==='alice'?{userId:'alice'}:null,now:()=>new Date(at)};
 const saved=await handleScanModel({body:request(),bearerToken:'alice'},deps,'save-home-model');assert.equal(saved.status,200);assert.equal(saved.headers['Cache-Control'],'no-store');
 assert.equal((await handleScanModel({body:request(),bearerToken:'invalid'},deps,'save-home-model')).status,401);
 const malformed=await handleScanModel({body:{...request(),bundleJson:'PRIVATE_BAD'},bearerToken:'alice'},deps,'save-home-model');assert.equal(malformed.status,400);assert.ok(!JSON.stringify(malformed).includes('PRIVATE_BAD'));
});
