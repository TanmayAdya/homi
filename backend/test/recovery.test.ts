import assert from 'node:assert/strict';
import test from 'node:test';
import { parseRecoveryArguments } from '../tool/recovery.ts';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';

const project='https://abcdefghijklmnopqrst.supabase.co';
const common=['--project',project],keys=['--private-key','/private/keys/recovery.pem','--checkpoint','/private/archives/checkpoint.sah-backup'];
test('recovery CLI is explicit, bounded, has no caller SQL and cannot silently select or overwrite a live target',()=>{
 assert.deepEqual(parseRecoveryArguments([]),{action:'help'});
 for(const action of ['status','freeze','thaw'])assert.equal(parseRecoveryArguments([action,...common]).action,action);
 assert.equal(parseRecoveryArguments(['checkpoint',...common,'--public-key','/private/public/key.pub','--checkpoint','/private/archives/checkpoint.sah-backup']).action,'checkpoint');
 assert.equal(parseRecoveryArguments(['prepare',...common,...keys,'--archive','/private/archives/old.sah-backup']).action,'prepare');
 assert.equal(parseRecoveryArguments(['promote',...common,...keys,'--acknowledge','exclude-changed-cases']).action,'promote');
 for(const args of [['promote',...common,...keys],['prepare',...common,...keys],['status',...common,'--target','production'],
  ['freeze',...common,...common],['execute','--sql','DROP TABLE cases'],['checkpoint',...common,'--public-key','/private/public/key.pub','--checkpoint','/private/public/checkpoint.sah-backup'],
  ['prepare',...common,...keys,'--archive','/private/archives/checkpoint.sah-backup'],['thaw','--project',project+'/']])assert.throws(()=>parseRecoveryArguments(args));
});
test('HTTP recovery gate denies every data path before authentication or body processing and hides probe failures',async()=>{
 let auth=0,available=false,fail=false;
 const deps={authenticate:async()=>{auth++;return null;},cases:new MemoryCaseRepository([]),loadRegistry:async()=>[],now:()=>new Date()};
 const server=createMatchingServer(deps,undefined,undefined,undefined,undefined,undefined,{repositoryAvailable:async()=>{if(fail)throw Error('private database detail');return available;}});
 await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const address=server.address();if(!address||typeof address==='string')throw Error();
 const origin='http://127.0.0.1:'+address.port;
 try{
  for(const path of ['/v1/read-case','/v1/save-case','/v3/read-shared-case','/v3/read-sensitive-sharing','/invite']){
   const response=await fetch(origin+path,{method:'POST',headers:{Authorization:'Bearer fictional'},body:'unparsed private bytes'});
   assert.equal(response.status,503);assert.equal(response.headers.get('cache-control'),'no-store');assert.equal(response.headers.get('retry-after'),'60');
  }
  assert.equal(auth,0);fail=true;const unavailable=await fetch(origin+'/v1/match-case');assert.equal(unavailable.status,503);
  assert.ok(!(await unavailable.text()).includes('private database detail'));
  fail=false;available=true;assert.equal((await fetch(origin+'/v1/match-case')).status,405);
 }finally{server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));}
});
