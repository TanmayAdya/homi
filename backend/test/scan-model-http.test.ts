import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {request} from 'node:http';
import type {AddressInfo} from 'node:net';
import test,{type TestContext} from 'node:test';
import {createMatchingServer,MAX_REQUEST_BYTES} from '../src/api/http-server.ts';
import {MemoryCaseRepository} from '../src/api/memory-case-repository.ts';
import {MAX_SCAN_MODEL_BYTES} from '../src/assessment/scan-model.ts';
import {draft} from './postgres/fixtures.ts';
const fixture=JSON.parse(readFileSync(new URL('../../contracts/v3/fixtures/scan-model-sync.json',import.meta.url),'utf8'))[0];
async function start(t:TestContext,enabled=true,authenticate?:(token:string)=>Promise<{userId:string}|null>){
 const cases=new MemoryCaseRepository([{userId:'alice',snapshot:{...draft(fixture.request.caseId),revision:1}}]);
 const deps={cases,now:()=>new Date('2026-10-24T18:00:00.000Z'),loadRegistry:async()=>[],authenticate:authenticate??(async(token:string)=>['alice','bob'].includes(token)?{userId:token}:null)};
 const server=createMatchingServer(deps,undefined,undefined,undefined,undefined,undefined,{hosted:true,...(enabled?{scanModelDependencies:deps}:{})});
 await new Promise<void>(resolve=>server.listen(0,'127.0.0.1',resolve));
 t.after(()=>new Promise<void>((resolve,reject)=>{server.close(e=>e?reject(e):resolve());server.closeAllConnections();}));
 const base=`http://127.0.0.1:${(server.address() as AddressInfo).port}`;
 const send=(route:string,body:unknown,token='alice')=>fetch(base+route,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(body)});
 return {base,send,cases};
}
test('model endpoints are opt-in, owner-only, no-store and strict about methods and routes',async t=>{
 const disabled=await start(t,false);assert.equal((await disabled.send('/v3/read-scan-model',{})).status,404);
 const {base,send}=await start(t),read={schemaVersion:'3',caseId:fixture.request.caseId,roomId:null};
 const saved=await send('/v3/save-scan-model',fixture.request);assert.equal(saved.status,200);assert.equal(saved.headers.get('cache-control'),'no-store');
 assert.equal((await send('/v3/read-scan-model',read,'bob')).status,404);
 assert.equal((await send('/v3/save-scan-model',fixture.request,'bob')).status,404);
 assert.equal((await send('/v3/read-scan-model',{...read,ownerId:'alice'})).status,400);
 assert.equal((await send('/v3/read-scan-model/',read)).status,404);
 assert.equal((await fetch(base+'/v3/read-scan-model')).status,405);
});
test('larger model request limit is isolated; invalid token is rejected before an unfinished body',async t=>{
 const {base,send}=await start(t);
 assert.equal((await send('/v3/save-scan-model',{padding:'x'.repeat(MAX_SCAN_MODEL_BYTES)})).status,413);
 assert.equal((await send('/v3/read-scan-model',{padding:'x'.repeat(MAX_REQUEST_BYTES)})).status,413);
 const status=await new Promise<number>((resolve,reject)=>{
  const req=request(base+'/v3/save-scan-model',{method:'POST',headers:{Authorization:'Bearer invalid','Content-Type':'application/json','Content-Length':MAX_SCAN_MODEL_BYTES}},res=>{res.resume();res.on('end',()=>{resolve(res.statusCode!);req.destroy();});});
  req.on('error',reject);req.setTimeout(2000,()=>{req.destroy();reject(new Error('Unauthenticated model body was buffered.'));});req.flushHeaders();
 });assert.equal(status,401);
});
test('upload reauthenticates after buffering and refuses an owner changed under the same token',async t=>{
 let calls=0;
 const {send,cases}=await start(t,true,async()=>({userId:++calls===1?'alice':'bob'}));
 assert.equal((await send('/v3/save-scan-model',fixture.request)).status,503);
 const state=await cases.readScanModelForUser('alice',fixture.request.caseId,null);assert.equal(state.status,'found');if(state.status==='found')assert.equal(state.state.modelRevision,0);
 assert.equal(calls,2);
});
