import { createHash } from 'node:crypto';
import { canonicalJson, evidenceIdentifier, evidenceInstant } from '../evidence/validation.ts';
import { parseScanScene, type JsonObject, type ScanFailure } from './scan-model.ts';
import { ROOM_TYPES, type RoomInstance } from './home-safety.ts';

export const MAX_HOME_BUNDLE_BYTES = 2 * 1024 * 1024;
export const MAX_HOME_MODEL_BYTES = 3 * 1024 * 1024;
const digest = (s: string) => createHash('sha256').update(s).digest('hex');
const hashPattern = /^[a-f0-9]{64}$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function check(value: unknown): asserts value { if (!value) throw new Error('Invalid connected home model.'); }
function object(value: unknown, keys?: string[]): JsonObject {
  check(value !== null && typeof value === 'object' && !Array.isArray(value));
  if (keys) check(Object.keys(value).length === keys.length && keys.every(k => Object.hasOwn(value, k)));
  return value as JsonObject;
}
function integer(value: unknown, min = 0): asserts value is number { check(Number.isSafeInteger(value) && Number(value) >= min); }
interface Placement { roomId:string; fingerprint:string; parentId:string|null; parentFingerprint:string|null; baselineFingerprint:string|null; pose:{x:number;y:number;z:number;yaw:number}; reviewed:true }
export interface HomeBundle { version:1; caseId:string; model:JsonObject & {rooms:Placement[]}; sources:Record<string,string>; roomTypes:Record<string,string> }
export function parseHomeBundle(raw: unknown, caseId: string): HomeBundle {
  check(typeof raw === 'string' && Buffer.byteLength(raw) <= MAX_HOME_BUNDLE_BYTES);
  const b = object(JSON.parse(raw), ['version','caseId','model','sources','roomTypes']);
  check(b.version === 1 && b.caseId === caseId);
  const m = object(b.model, ['version','caseId','method','referenceRoomId','rooms','captures','mergedScene']);
  check(m.version === 1 && m.caseId === caseId && ['reviewed_alignment','roomplan_shared_frame','arcore_shared_frame'].includes(String(m.method)));
  check(Array.isArray(m.rooms) && m.rooms.length >= 1 && m.rooms.length <= 32);
  const rooms = m.rooms.map(value => {
    const r = object(value, ['roomId','fingerprint','parentId','parentFingerprint','baselineFingerprint','pose','reviewed']);
    check(evidenceIdentifier(r.roomId) && hashPattern.test(String(r.fingerprint)) && r.reviewed === true);
    check(r.parentId === null ? r.parentFingerprint === null : evidenceIdentifier(r.parentId) && hashPattern.test(String(r.parentFingerprint)));
    check(r.baselineFingerprint === null || hashPattern.test(String(r.baselineFingerprint)));
    const p = object(r.pose, ['x','y','z','yaw']);
    for (const k of ['x','y','z','yaw']) check(typeof p[k] === 'number' && Number.isFinite(p[k]) && Math.abs(p[k] as number) <= (k === 'yaw' ? 180 : 100));
    return r as unknown as Placement;
  });
  const ids = new Set(rooms.map(r => r.roomId)); check(ids.size === rooms.length);
  const types = object(b.roomTypes); check(Object.keys(types).length === ids.size && Object.entries(types).every(([id,t]) => ids.has(id) && ROOM_TYPES.includes(t as RoomInstance['type']) && t !== 'outdoorPaths'));
  const root = rooms.find(r => r.roomId === m.referenceRoomId);
  const identity = (p: Placement['pose']) => p.x === 0 && p.y === 0 && p.z === 0 && p.yaw === 0;
  check(root && root.parentId === null && identity(root.pose));
  const global = (r:Placement, seen = new Set<string>()):Placement['pose'] => {
    check(!seen.has(r.roomId)); seen.add(r.roomId);
    if (r.parentId === null) { check(r === root); return r.pose; }
    const parent = rooms.find(v => v.roomId === r.parentId); check(parent && parent.fingerprint === r.parentFingerprint);
    const p = global(parent, seen), angle=p.yaw*Math.PI/180;
    const pose={x:p.x+Math.cos(angle)*r.pose.x+Math.sin(angle)*r.pose.z,y:p.y+r.pose.y,z:p.z-Math.sin(angle)*r.pose.x+Math.cos(angle)*r.pose.z,yaw:((p.yaw+r.pose.yaw+540)%360)-180};
    check([pose.x,pose.y,pose.z].every(v=>Math.abs(v)<=100));return pose;
  };
  rooms.forEach(r=>global(r));
  const sources=object(b.sources),captures=object(m.captures),shared=m.method!=='reviewed_alignment',source=m.method==='arcore_shared_frame'?'arcore':'roomplan';
  check(Object.keys(sources).every(id=>ids.has(id)));
  const scene = (raw:unknown, expected?:string) => {
    check(typeof raw==='string' && Buffer.byteLength(raw)<=512*1024 && (expected===undefined || digest(raw)===expected));
    return parseScanScene(JSON.parse(raw));
  };
  let elements=0,points=0;
  if(shared) {
    check(rooms.length>=2 && rooms.length<=8 && Object.keys(captures).length===rooms.length && rooms.every(r=>identity(r.pose)));
    check(scene(m.mergedScene).source===source);
  } else check(Object.keys(captures).length===0 && m.mergedScene===null && rooms.every(r=>r.baselineFingerprint===null));
  for(const r of rooms) {
    const baseline=shared?r.baselineFingerprint:r.fingerprint;
    if(baseline===null)check(!Object.hasOwn(sources,r.roomId));else scene(sources[r.roomId],baseline);
    const s=shared?scene(captures[r.roomId],r.fingerprint):scene(sources[r.roomId],r.fingerprint);
    if(shared)check(s.source===source);
    elements+=(s.elements as unknown[]).length;points+=(s.points as unknown[]).length;
  }
  check(Object.keys(sources).length===rooms.filter(r=>!shared || r.baselineFingerprint!==null).length && elements<=2048 && points<=8192);
  return b as unknown as HomeBundle;
}
export function homeRoomsValid(bundleJson:string|null,caseId:string,rooms:RoomInstance[],allowArchived=false):boolean {
  if(bundleJson===null)return true;
  const b=parseHomeBundle(bundleJson,caseId);
  return b.model.rooms.every(r=>rooms.some(v=>v.id===r.roomId && (allowArchived || !v.archived) && v.type===b.roomTypes[r.roomId]));
}
export interface HomeRead {schemaVersion:'3';caseId:string}
export interface HomeSave extends HomeRead {expectedCaseRevision:number;expectedModelRevision:number;mutationId:string;bundleJson:string|null}
export interface HomeRecord extends HomeRead {revision:number;bundleJson:string|null;updatedAt:string;updatedBy:string;receipts:{mutationId:string;requestHash:string;revision:number}[]}
export interface HomeState extends HomeRead {caseRevision:number;modelRevision:number;bundleJson:string|null;bundleSha256:string|null;updatedAt:string|null;updatedBy:string|null;acknowledgedMutationId:string|null}
export type HomeResult={status:'found';state:HomeState}|ScanFailure;
export interface HomeModelRepository {
 readHomeModelForUser(userId:string,caseId:string):Promise<HomeResult>;
 saveHomeModelForUser(userId:string,input:HomeSave,at:string):Promise<HomeResult>;
}
export function parseHomeRequest(raw:unknown,saving:boolean):HomeRead|HomeSave {
 const r=object(raw,['schemaVersion','caseId',...(saving?['expectedCaseRevision','expectedModelRevision','mutationId','bundleJson']:[])]);
 check(r.schemaVersion==='3' && evidenceIdentifier(r.caseId));
 if(saving){integer(r.expectedCaseRevision,1);integer(r.expectedModelRevision);check(typeof r.mutationId==='string' && uuidPattern.test(r.mutationId));if(r.bundleJson!==null)parseHomeBundle(r.bundleJson,r.caseId as string);}
 return structuredClone(r) as unknown as HomeRead|HomeSave;
}
export function decodeHomeRecord(bytes:Uint8Array):HomeRecord {
 check(bytes.byteLength<=MAX_HOME_MODEL_BYTES);
 const r=object(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)),['schemaVersion','caseId','revision','bundleJson','updatedAt','updatedBy','receipts']);
 check(r.schemaVersion==='3' && evidenceIdentifier(r.caseId) && evidenceIdentifier(r.updatedBy) && evidenceInstant(r.updatedAt));integer(r.revision,1);
 if(r.bundleJson!==null)parseHomeBundle(r.bundleJson,r.caseId as string);
 check(Array.isArray(r.receipts) && r.receipts.length>=1 && r.receipts.length<=64);
 const ids=new Set<string>();let previous=0;
 for(const raw of r.receipts){const receipt=object(raw,['mutationId','requestHash','revision']);integer(receipt.revision,1);check(receipt.revision>previous && receipt.revision<=r.revision && typeof receipt.mutationId==='string' && uuidPattern.test(receipt.mutationId) && !ids.has(receipt.mutationId) && hashPattern.test(String(receipt.requestHash)));ids.add(receipt.mutationId);previous=receipt.revision;}
 return r as unknown as HomeRecord;
}
export function homeState(caseId:string,caseRevision:number,r:HomeRecord|null,ack:string|null=null):HomeState {
 return {schemaVersion:'3',caseId,caseRevision,modelRevision:r?.revision??0,bundleJson:r?.bundleJson??null,bundleSha256:r?.bundleJson==null?null:digest(r.bundleJson),updatedAt:r?.updatedAt??null,updatedBy:r?.updatedBy??null,acknowledgedMutationId:ack};
}
export function changeHomeModel(prior:HomeRecord|null,input:HomeSave,userId:string,caseRevision:number,at:string):ScanFailure|{status:'changed'|'retry';record:HomeRecord} {
 const requestHash=digest(canonicalJson(input)),receipt=prior?.receipts.find(r=>r.mutationId===input.mutationId);
 if(receipt)return receipt.requestHash===requestHash?{status:'retry',record:prior!}:{status:'mutation_conflict'};
 if(input.expectedCaseRevision!==caseRevision)return {status:'conflict'};
 if(input.expectedModelRevision!==(prior?.revision??0))return {status:'model_conflict'};
 const revision=(prior?.revision??0)+1;
 const record:HomeRecord={schemaVersion:'3',caseId:input.caseId,revision,bundleJson:input.bundleJson,updatedBy:userId,updatedAt:at,receipts:[...(prior?.receipts??[]),{mutationId:input.mutationId,requestHash,revision}].slice(-64)};
 try{return {status:'changed',record:decodeHomeRecord(Buffer.from(JSON.stringify(record)))};}catch{return {status:'limit'};}
}
export function purgeHomeRoom(record:HomeRecord,roomId:string,userId:string,at:string):HomeRecord {
 if(record.bundleJson===null || !parseHomeBundle(record.bundleJson,record.caseId).model.rooms.some(r=>r.roomId===roomId))return record;
 return {...record,bundleJson:null,revision:record.revision+1,updatedAt:at,updatedBy:userId};
}
