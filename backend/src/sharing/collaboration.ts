import { createHash } from 'node:crypto';
import type { PoolClient } from 'pg';
import { canonicalJson, evidenceIdentifier, evidenceRevision } from '../evidence/validation.ts';
import { parseRequestUpdate, type RequestUpdate } from '../requests/tracking.ts';
import { TASK_STATES } from '../tracking/progress.ts';
import { check, object, uuid, instant } from './validation.ts';
import type { SharingResult } from './contracts.ts';

export const COLLABORATION_ROUTES = ['read-collaboration','configure-collaboration','update-shared-task','propose-shared-status','review-shared-status'] as const;
export type CollaborationRoute = typeof COLLABORATION_ROUTES[number];
export interface CollaborationScope { taskIds: string[]; allowTaskProgress: boolean; allowStatusProposals: boolean }
export interface TaskAssignment { taskId: string; membershipId: string; assigneeUserId: string }
export interface StatusProposal { id: string; membershipId: string; permissionRevision: number; caseRevision: number; programId: string;
  update: RequestUpdate; proposedBy: string; proposedAt: string; state: 'pending'|'accepted'|'rejected'; reviewedBy: string|null; reviewedAt: string|null }
export interface CollaborationRecord { schemaVersion: '3'; caseId: string; revision: number; assignments: TaskAssignment[]; proposals: StatusProposal[];
  events: {revision:number; mutationId:string; requestHash:string; type:string; actorId:string; membershipId:string; at:string}[] }
export interface CollaborationRequest { schemaVersion:'3'; membershipId?:string; expectedPermissionRevision?:number; expectedCaseRevision?:number;
  expectedProgressRevision?:number; expectedCollaborationRevision?:number; mutationId?:string; collaborationScope?:CollaborationScope;
  assignedTaskIds?:string[]; taskId?:string; expectedTaskRevision?:number; state?:typeof TASK_STATES[number]; programId?:string;
  update?:RequestUpdate; proposalId?:string; decision?:'accepted'|'rejected' }
export const emptyCollaborationScope = ():CollaborationScope => ({taskIds:[],allowTaskProgress:false,allowStatusProposals:false});
export function parseCollaborationScope(value:unknown):CollaborationScope {
  object(value,['taskIds','allowTaskProgress','allowStatusProposals']);
  check(Array.isArray(value.taskIds) && value.taskIds.length<=32 && value.taskIds.every(evidenceIdentifier) && new Set(value.taskIds).size===value.taskIds.length
    && typeof value.allowTaskProgress==='boolean' && typeof value.allowStatusProposals==='boolean');
  return structuredClone(value) as unknown as CollaborationScope;
}
const keys:Record<CollaborationRoute,string[]> = {
  'read-collaboration':[],
  'configure-collaboration':['expectedCaseRevision','expectedProgressRevision','expectedCollaborationRevision','mutationId','collaborationScope','assignedTaskIds'],
  'update-shared-task':['expectedCaseRevision','expectedCollaborationRevision','mutationId','taskId','expectedTaskRevision','state'],
  'propose-shared-status':['expectedCaseRevision','expectedCollaborationRevision','mutationId','programId','update'],
  'review-shared-status':['expectedCaseRevision','expectedProgressRevision','expectedCollaborationRevision','mutationId','proposalId','decision'],
};
export function parseCollaborationRequest(route:CollaborationRoute,value:unknown):CollaborationRequest {
  object(value,['schemaVersion','membershipId','expectedPermissionRevision',...keys[route]]);
  check(value.schemaVersion==='3' && uuid(value.membershipId) && evidenceRevision(value.expectedPermissionRevision));
  for(const key of ['expectedCaseRevision','expectedTaskRevision']) if(key in value) check(evidenceRevision(value[key]));
  for(const key of ['expectedProgressRevision','expectedCollaborationRevision']) if(key in value) check(evidenceRevision(value[key],true));
  for(const key of ['mutationId','proposalId']) if(key in value)check(uuid(value[key]));
  for(const key of ['programId','taskId']) if(key in value)check(evidenceIdentifier(value[key]));
  if(route==='configure-collaboration') {
    const scope=parseCollaborationScope(value.collaborationScope);
    check(Array.isArray(value.assignedTaskIds) && value.assignedTaskIds.length<=32 && value.assignedTaskIds.every(v=>typeof v==='string' && scope.taskIds.includes(v)) && new Set(value.assignedTaskIds).size===value.assignedTaskIds.length);
    check(scope.allowTaskProgress || value.assignedTaskIds.length===0);
  }
  if(route==='update-shared-task')check(TASK_STATES.includes(value.state as typeof TASK_STATES[number]));
  if(route==='propose-shared-status')parseRequestUpdate(value.update);
  if(route==='review-shared-status')check(['accepted','rejected'].includes(String(value.decision)));
  return structuredClone(value) as unknown as CollaborationRequest;
}
export function parseCollaborationRecord(value:unknown):CollaborationRecord {
  object(value,['schemaVersion','caseId','revision','assignments','proposals','events']);
  check(value.schemaVersion==='3' && evidenceIdentifier(value.caseId) && evidenceRevision(value.revision,true)
    && Array.isArray(value.assignments) && value.assignments.length<=128 && Array.isArray(value.proposals) && value.proposals.length<=64
    && Array.isArray(value.events) && value.events.length<=256 && value.events.length===value.revision);
  for(const assignment of value.assignments){object(assignment,['taskId','membershipId','assigneeUserId']);check(evidenceIdentifier(assignment.taskId) && uuid(assignment.membershipId) && uuid(assignment.assigneeUserId));}
  for(const proposal of value.proposals){object(proposal,['id','membershipId','permissionRevision','caseRevision','programId','update','proposedBy','proposedAt','state','reviewedBy','reviewedAt']);
    check(uuid(proposal.id) && uuid(proposal.membershipId) && evidenceRevision(proposal.permissionRevision) && evidenceRevision(proposal.caseRevision) && evidenceIdentifier(proposal.programId)
      && uuid(proposal.proposedBy) && instant(proposal.proposedAt) && ['pending','accepted','rejected'].includes(String(proposal.state)));
    parseRequestUpdate(proposal.update);
    check(proposal.state==='pending' ? proposal.reviewedBy===null && proposal.reviewedAt===null : evidenceIdentifier(proposal.reviewedBy) && instant(proposal.reviewedAt));
  }
  for(const [i,event]of value.events.entries()){object(event,['revision','mutationId','requestHash','type','actorId','membershipId','at']);check(event.revision===i+1 && uuid(event.mutationId)
    && typeof event.requestHash==='string' && /^[a-f0-9]{64}$/.test(event.requestHash) && COLLABORATION_ROUTES.includes(event.type as CollaborationRoute) && evidenceIdentifier(event.actorId) && uuid(event.membershipId) && instant(event.at));}
  check(new Set(value.assignments.map(v=>v.taskId)).size===value.assignments.length && new Set(value.proposals.map(v=>v.id)).size===value.proposals.length
    && new Set(value.events.map(v=>v.mutationId)).size===value.events.length && Buffer.byteLength(JSON.stringify(value))<=196608);
  return structuredClone(value) as unknown as CollaborationRecord;
}
export async function executeCollaboration(client:PoolClient,route:CollaborationRoute,input:CollaborationRequest,ruleVersions:Record<string,string>):Promise<SharingResult>{
  const requestHash=createHash('sha256').update(canonicalJson(input)).digest('hex');
  const result=(await client.query('SELECT safeathome_private.collaboration_operation($1,$2::jsonb,$3::jsonb) AS result',
    [route,JSON.stringify({...input,requestHash}),JSON.stringify(ruleVersions)])).rows[0].result;
  check(['ok','not_found','conflict','quota_exceeded','invalid_request'].includes(result.status));
  return result.status==='ok'?{status:'ok',data:result.data}:{status:result.status};
}

export function parsePublishedTask(value:unknown,includeAccess=true) {
  object(value,['id','programId','findingId','title','kind','state','responsiblePerson','dueOn','revision',...(includeAccess?['assigneeUserId','needsReview']:[])]);
  check(evidenceIdentifier(value.id) && typeof value.title==='string' && value.title.length>0 && value.title.length<=200
    && TASK_STATES.includes(value.state as typeof TASK_STATES[number]) && ['profile','room_review','documents','contact','draft_review','follow_up','other'].includes(String(value.kind))
    && evidenceRevision(value.revision) && (value.programId===null || evidenceIdentifier(value.programId))
    && (value.findingId===null || evidenceIdentifier(value.findingId)) && (value.responsiblePerson===null || typeof value.responsiblePerson==='string' && value.responsiblePerson.length<=100)
    && (value.dueOn===null || typeof value.dueOn==='string' && /^\d{4}-\d\d-\d\d$/.test(value.dueOn)));
  if(includeAccess)check((value.assigneeUserId===null || uuid(value.assigneeUserId)) && typeof value.needsReview==='boolean');
  return structuredClone(value);
}
export function validateCollaborationScopeRecord(value:unknown){
  object(value,['taskIds','allowTaskProgress','allowStatusProposals','taskSnapshots']);
  const {taskSnapshots,...scope}=value; const parsed=parseCollaborationScope(scope);
  check(Array.isArray(taskSnapshots) && taskSnapshots.length===parsed.taskIds.length && Buffer.byteLength(JSON.stringify(value))<=49152);
  for(const snapshot of taskSnapshots){object(snapshot,['task','definitionHash']);const task=parsePublishedTask(snapshot.task,false);
    check(parsed.taskIds.includes(String(task.id)) && typeof snapshot.definitionHash==='string' && /^[a-f0-9]{64}$/.test(snapshot.definitionHash));}
  check(new Set(taskSnapshots.map(t=>(t.task as Record<string,unknown>).id)).size===taskSnapshots.length);
}
