import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { parseCollaborationRequest,parseCollaborationScope,type CollaborationRoute } from '../src/sharing/collaboration.ts';
import { parseSharingRequest,SHARING_ROUTES } from '../src/sharing/contracts.ts';
const fixtures=JSON.parse(readFileSync(new URL('../../contracts/v3/fixtures/sharing-collaboration.json',import.meta.url),'utf8'));
test('all five additive collaboration endpoints have strict typed requests',()=>{
 for(const fixture of fixtures){assert.ok(SHARING_ROUTES.includes(fixture.route));assert.deepEqual(parseCollaborationRequest(fixture.route,fixture.request),fixture.request);assert.deepEqual(parseSharingRequest(fixture.route,fixture.request),fixture.request);}
});
test('client-supplied roles, assignees, private fields, state expansion and stale/missing revisions fail closed',()=>{
 const find=(route:CollaborationRoute)=>fixtures.find((f:any)=>f.route===route).request;
 for(const [route,change]of [
  ['update-shared-task',{expectedTaskRevision:null}],['update-shared-task',{state:'approved'}],['update-shared-task',{title:'Injected title'}],
  ['configure-collaboration',{assigneeUserId:'other-user'}],['propose-shared-status',{ownerId:'owner'}],
  ['configure-collaboration',{collaborationScope:{taskIds:[],allowTaskProgress:true,allowStatusProposals:true,photos:true}}],
  ['configure-collaboration',{collaborationScope:{taskIds:[],allowTaskProgress:false,allowStatusProposals:false},assignedTaskIds:['unselected']}],
  ['review-shared-status',{decision:'submitted'}],
 ] as [CollaborationRoute,Record<string,unknown>][])assert.throws(()=>parseCollaborationRequest(route,{...find(route),...change}));
 assert.throws(()=>parseCollaborationScope({taskIds:['same','same'],allowTaskProgress:false,allowStatusProposals:false}));
});

test('collaboration write routes stay off until the trusted tracking/sharing gate is enabled',async()=>{
 const {handleSharing}=await import('../src/api/sharing.ts');let executed=false;
 const fixture=fixtures.find((f:any)=>f.route==='read-collaboration');
 const dependencies={authenticate:async()=>({userId:'33333333-3333-4333-8333-333333333333'}),sharing:{async execute(){executed=true;return {status:'ok' as const,data:{}};}}};
 const denied=await handleSharing({body:fixture.request,bearerToken:'fictional-token'},dependencies,fixture.route);
 assert.equal(denied.status,404);assert.equal(executed,false);
 const enabled=await handleSharing({body:fixture.request,bearerToken:'fictional-token'},{...dependencies,collaborationEnabled:true},fixture.route);
 assert.equal(enabled.status,200);assert.equal(executed,true);
});
