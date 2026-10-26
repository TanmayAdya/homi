import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { handleSharing } from '../src/api/sharing.ts';
import { parseSharingRequest, parseScope, projectCase, type SharingRepository } from '../src/sharing/contracts.ts';
import { createSupabaseAuthenticator } from '../src/auth/supabase-auth.ts';
const recipientId='22222222-2222-4222-8222-222222222222';
const scope={findingIds:[],programIds:[],allowHelperNotes:false};
test('strict sharing requests deny injected authority, unknown categories and viewer writes',()=>{
 const request={schemaVersion:'3',caseId:'fictional-case',expectedCaseRevision:1,invitationId:recipientId,recipientId,role:'viewer',scope,expiresAt:null};
 assert.deepEqual(parseSharingRequest('create-invitation',request),request);
 for(const change of [{ownerId:recipientId},{scope:{...scope,photos:true}},{scope:{...scope,allowHelperNotes:true}},{role:'owner'},{expiresAt:'tomorrow'}])assert.throws(()=>parseSharingRequest('create-invitation',{...request,...change}));
 assert.throws(()=>parseScope({...scope,findingIds:['same','same']}));
 assert.throws(()=>parseSharingRequest('add-shared-note',{schemaVersion:'3',membershipId:recipientId,expectedPermissionRevision:1,mutationId:recipientId,note:'\nprivate'}));
});
test('projection allowlist contains only selected observations and reported progress',()=>{
 const snapshot={schemaVersion:'1' as const,caseId:'fictional-case',revision:1,profile:{city:'Private city',county:null,healthPlan:'Private health',tenure:null,ageYears:null,householdSize:null,annualIncomeUsd:100,ownerConsentReported:null},unresolvedFields:[],findings:[{id:'first',room:'bathroom' as const,observation:'Fictional step',reviewState:'confirmed' as const,evidenceIds:['secret-photo'],measurements:[]},{id:'second',room:'entrance' as const,observation:'Unselected private text',reviewState:'needs_review' as const,evidenceIds:[],measurements:[]}]};
 const result=projectCase(snapshot,{...scope,findingIds:['first'],programIds:['selected-program']},[{programId:'selected-program',events:[{status:'preparing',occurredOn:'2026-10-24'}]}],'2026-10-24T00:00:00.000Z');
 assert.deepEqual(result.findings,[{id:'first',room:'bathroom',observation:'Fictional step',reviewState:'confirmed'}]);assert.deepEqual(result.programs,[{programId:'selected-program',status:'preparing',occurredOn:'2026-10-24',provenance:'user_reported'}]);
 assert.ok(!JSON.stringify(result).includes('Private'));assert.ok(!JSON.stringify(result).includes('Unselected'));assert.ok(!JSON.stringify(result).includes('secret-photo'));
 assert.deepEqual(projectCase(snapshot,scope,[],'2026-10-24T00:00:00.000Z').findings,[]);
});
test('sharing auth requires provider-confirmed identity and ignores client metadata',async()=>{
 const config={projectUrl:'https://fictional.supabase.co',publishableKey:'sb_publishable_fictional'};
 const user={id:recipientId,role:'authenticated',user_metadata:{email_verified:true,role:'owner'}};
 for(const patch of [{},{is_anonymous:true,email_confirmed_at:'2026-10-24T00:00:00Z'},{email_confirmed_at:'invalid'}]){
  const auth=createSupabaseAuthenticator(config,async()=>new Response(JSON.stringify({...user,...patch}),{headers:{'Content-Type':'application/json'}}),true);assert.equal(await auth('token'),null);
 }
 for(const patch of [{email_confirmed_at:'2026-10-24T00:00:00Z'},{phone_confirmed_at:'2026-10-24T00:00:00Z'}]){
  const auth=createSupabaseAuthenticator(config,async()=>new Response(JSON.stringify({...user,...patch}),{headers:{'Content-Type':'application/json'}}),true);assert.deepEqual(await auth('token'),{userId:recipientId});
 }
});
test('handler hashes invitation secrets, returns code only once and never sends messages',async()=>{
 let created=true,hash='';
 const sharing:SharingRepository={async execute(_user,_route,_request,tokenHash){hash=tokenHash!;return {status:'ok',data:{created,membership:{}}};}};
 const deps={authenticate:async()=>({userId:recipientId}),sharing};
 const input={schemaVersion:'3',caseId:'case',expectedCaseRevision:1,invitationId:recipientId,recipientId,role:'viewer',scope,expiresAt:null};
 const response=await handleSharing({body:input,bearerToken:'token'},deps,'create-invitation');assert.equal(response.status,200);assert.match(hash,/^[a-f0-9]{64}$/);
 assert.ok('invitationCode' in response.body && typeof response.body.invitationCode==='string' && /^[A-Za-z0-9_-]{43}$/.test(response.body.invitationCode));
 created=false;const retry=await handleSharing({body:input,bearerToken:'token'},deps,'create-invitation');assert.ok('invitationCode' in retry.body && retry.body.invitationCode===null);
});
test('HTTP routes use the sharing authenticator, enforce body/method/auth boundaries, and are default absent',async()=>{
 let verified=0,raw=0,operations=0;
 const authenticate=async()=>{raw++;return {userId:recipientId};};
 const dependencies={authenticate,cases:new MemoryCaseRepository([]),now:()=>new Date(),loadRegistry:async()=>[]};
 const server=createMatchingServer(dependencies,undefined,undefined,undefined,undefined,undefined,{hosted:true,sharingDependencies:{authenticate:async(token)=>{verified++;return token==='verified'?{userId:recipientId}:null;},sharing:{async execute(){operations++;return {status:'ok',data:{memberships:[]}};}}}});
 await new Promise<void>(resolve=>server.listen(0,'127.0.0.1',resolve));const address=server.address();if(!address||typeof address==='string')throw Error();const url='http://127.0.0.1:'+address.port+'/v3/list-shared-cases';
 try{
  const post=(token:string,body:unknown)=>fetch(url,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(body)});
  assert.equal((await fetch(url)).status,405);assert.equal((await post('unverified',{schemaVersion:'3'})).status,401);
  assert.equal((await post('verified',{schemaVersion:'3',ownerId:recipientId})).status,400);
  const response=await post('verified',{schemaVersion:'3'});assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'no-store');assert.deepEqual(await response.json(),{schemaVersion:'3',memberships:[]});
  assert.equal(raw,0);assert.equal(operations,1);assert.equal(verified,3);
 }finally{await new Promise<void>(resolve=>server.close(()=>resolve()));}
 const disabled=createMatchingServer(dependencies);await new Promise<void>(r=>disabled.listen(0,'127.0.0.1',r));const a=disabled.address();if(!a||typeof a==='string')throw Error();try{assert.equal((await fetch('http://127.0.0.1:'+a.port+'/v3/list-shared-cases',{method:'POST'})).status,404);}finally{await new Promise<void>(r=>disabled.close(()=>r()));}
});
test('owner-typed labels are optional, bounded and only opted into on list/review routes',async()=>{
 const {readFileSync}=await import('node:fs');
 for(const fixture of JSON.parse(readFileSync(new URL('../../contracts/v3/fixtures/sharing-labels.json',import.meta.url),'utf8')))assert.deepEqual(parseSharingRequest(fixture.route,fixture.request),fixture.request);
 const request={schemaVersion:'3',caseId:'fictional-case',expectedCaseRevision:1,invitationId:recipientId,recipientId,role:'viewer',scope,expiresAt:null};
 assert.deepEqual(parseSharingRequest('create-invitation',{...request,recipientLabel:'Fictional Ana'}),{...request,recipientLabel:'Fictional Ana'});
 for(const bad of ['',' padded','x'.repeat(81),'new\nline','‮flip',null,7])for(const key of ['recipientLabel','ownerLabel'])assert.throws(()=>parseSharingRequest('create-invitation',{...request,[key]:bad}),String(bad));
 assert.throws(()=>parseSharingRequest('change-sharing',{schemaVersion:'3',caseId:'fictional-case',expectedCaseRevision:1,invitationId:recipientId,expectedPermissionRevision:1,role:'viewer',scope,expiresAt:null,recipientLabel:'Fictional Ana'}));
 assert.deepEqual(parseSharingRequest('list-shared-cases',{schemaVersion:'3',includeLabels:true}),{schemaVersion:'3',includeLabels:true});
 for(const value of [false,'true',null])assert.throws(()=>parseSharingRequest('list-shared-cases',{schemaVersion:'3',includeLabels:value}));
 assert.throws(()=>parseSharingRequest('read-shared-case',{schemaVersion:'3',membershipId:recipientId,expectedPermissionRevision:1,includeLabels:true}));
 assert.throws(()=>parseSharingRequest('list-shared-cases',null));
});
