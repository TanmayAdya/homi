import type { HomeModelRepository } from './home-model.ts';
import { ROOM_TYPES, type RoomInstance } from './home-safety.ts';
import { createHash } from 'node:crypto';
import { canonicalJson, evidenceIdentifier, evidenceInstant } from '../evidence/validation.ts';

export const MAX_SCAN_MODEL_BYTES = 768 * 1024;
export const MAX_SCAN_SCENE_BYTES = 512 * 1024;
export type JsonObject = Record<string, unknown>;
const kinds = ['wall','door','opening','window','floor','bathtub','toilet','sink','storage','furniture','unknown'];
const difficulties = ['enteringBathroom','bathing','toiletTransfer','sinkUse','movingAround'];
const warnings = ['curved_surfaces_approximated','geometry_omitted','depth_unavailable','depth_partial','tracking_limited','count_limit'];
const uuidPattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;
const hash = (v: unknown) => createHash('sha256').update(canonicalJson(v)).digest('hex');
const invalid = (): never => { throw new Error('Invalid private scan model.'); };
function check(v: unknown): asserts v { if (!v) invalid(); }
function object(v: unknown, keys: string[]): JsonObject {
  check(v !== null && typeof v === 'object' && !Array.isArray(v));
  check(Object.keys(v).length === keys.length && Object.keys(v).every(k => keys.includes(k)));
  return v as JsonObject;
}
function list(v: unknown, max: number): unknown[] { check(Array.isArray(v) && v.length <= max); return v; }
function text(v: unknown, max: number): string {
  check(typeof v === 'string' && v.length > 0 && v.length <= max && v.trim() === v && !/[\x00-\x1f\x7f-\x9f\ud800-\udfff\u2028\u2029]/u.test(v)); return v;
}
function choice(v: unknown, values: string[]): string { check(typeof v === 'string' && values.includes(v)); return v; }
function number(v: unknown, min: number, max: number): number { check(typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max); return v; }
function integer(v: unknown, min = 0): number { const n = number(v,min,Number.MAX_SAFE_INTEGER); check(Number.isSafeInteger(n)); return n; }
function vector(v: unknown, n: number, min: number, max: number): number[] { const a=list(v,n); check(a.length===n); return a.map(x=>number(x,min,max)); }
function uuid(v: unknown): string { const id=text(v,36); check(uuidPattern.test(id)); return id; }
function instant(v: unknown): string { check(evidenceInstant(v)); return v as string; }
function strings(v: unknown, max: number): string[] { const a=list(v,max).map(x=>text(x,128)); check(new Set(a).size===a.length); return a; }

export function parseScanScene(raw: unknown): JsonObject {
  const version = (raw as JsonObject | null)?.schemaVersion;
  check(version===1 || version===2);
  const scene=object(raw,['schemaVersion','scanId','source','sourceVersion','capturedAt','units','coordinateSystem','coverage','truncated','warnings','elements','points',...(version===2?['measurements']:[])]);
  uuid(scene.scanId); const source=choice(scene.source,['roomplan','arcore','arkit']);
  check((version===2)===(source==='arkit'));
  text(scene.sourceVersion,80); instant(scene.capturedAt);
  check(scene.units==='m' && scene.coordinateSystem==='right_handed_y_up' && scene.coverage==='partial' && typeof scene.truncated==='boolean');
  const ws=list(scene.warnings,16); ws.forEach(w=>choice(w,warnings));
  const elements=list(scene.elements,256), ids=new Set<string>();
  for (const raw of elements) {
    const e=object(raw,['id','kind','nativeCategory','dimensions','transform','classificationConfidence']);
    const id=text(e.id,80); check(!ids.has(id)); ids.add(id);
    const kind=choice(e.kind,kinds), category=text(e.nativeCategory,64), d=vector(e.dimensions,3,0,30), m=vector(e.transform,16,-50,50);
    check(d.filter(x=>x>0).length>=2);
    const confidence=choice(e.classificationConfidence,['low','medium','high','unknown']);
    check(Math.abs(m[3])<=.0001 && Math.abs(m[7])<=.0001 && Math.abs(m[11])<=.0001 && Math.abs(m[15]-1)<=.0001);
    const dot=(a:number,b:number)=>m[a]*m[b]+m[a+1]*m[b+1]+m[a+2]*m[b+2];
    for (const a of [0,4,8]) check(Math.abs(Math.sqrt(dot(a,a))-1)<=.01);
    check(Math.abs(dot(0,4))<=.01 && Math.abs(dot(0,8))<=.01 && Math.abs(dot(4,8))<=.01);
    const determinant=m[0]*(m[5]*m[10]-m[6]*m[9])-m[4]*(m[1]*m[10]-m[2]*m[9])+m[8]*(m[1]*m[6]-m[2]*m[5]); check(Math.abs(determinant-1)<=.03);
    for (const x of [-d[0]/2,d[0]/2]) for (const y of [-d[1]/2,d[1]/2]) for (const z of [-d[2]/2,d[2]/2]) {
      for (let axis=0;axis<3;axis++) check(Math.abs(m[axis]*x+m[4+axis]*y+m[8+axis]*z+m[12+axis])<=50);
    }
    if (source!=='roomplan') {
      check(kind==='unknown' && confidence==='unknown' && d[1]===0);
      choice(category,source==='arkit'?['horizontal','vertical']:['horizontal_upward','horizontal_downward','vertical']);
    }
  }
  const points=list(scene.points,4096);
  for(const raw of points) { const point=list(raw,4); check(point.length===4); vector(point.slice(0,3),3,-50,50); number(point[3],0,1); }
  if(version===2) {
    check(points.length===0 && ws.includes('depth_unavailable'));
    const ids=new Set<string>();
    for(const raw of list(scene.measurements,20)) {
      const m=object(raw,['id','start','end']), id=uuid(m.id); check(!ids.has(id));ids.add(id);
      const start=vector(m.start,3,-50,50),end=vector(m.end,3,-50,50),distance=Math.hypot(...start.map((x,i)=>end[i]-x)); check(distance>=.02 && distance<=10);
    }
  }
  check(elements.length>0 || points.length>0);
  check(Buffer.byteLength(JSON.stringify(scene))<=MAX_SCAN_SCENE_BYTES);
  return structuredClone(scene);
}
export function parseScanReview(raw: unknown, caseId: string, roomId: string|null = null): JsonObject {
  const review=object(raw,['version','caseId','scene','pendingScanId','reviewed','labels','difficulties','dismissed',...(roomId===null?[]:['roomId','roomType'])]);
  check(review.version===(roomId===null?1:2) && review.caseId===caseId && review.pendingScanId===null);
  if(roomId!==null){check(review.roomId===roomId);choice(review.roomType,[...ROOM_TYPES]);}
  const scene=parseScanScene(review.scene), ids=new Set((scene.elements as JsonObject[]).map(e=>e.id));
  const reviewed=strings(review.reviewed,256); check(reviewed.every(id=>ids.has(id)));
  const labels=review.labels; check(labels!==null && typeof labels==='object' && !Array.isArray(labels) && Object.keys(labels).length<=256);
  for(const [id,kind] of Object.entries(labels)) { check(ids.has(id));choice(kind,kinds); }
  strings(review.difficulties,5).forEach(d=>choice(d,difficulties));
  check(strings(review.dismissed,256).every(id=>/^[a-zA-Z0-9_.:-]{1,128}$/.test(id)));
  const result={...structuredClone(review),scene};
  check(Buffer.byteLength(JSON.stringify(result))<=MAX_SCAN_MODEL_BYTES-16384);
  return result;
}
export function parseReviewJson(raw:unknown,caseId:string,roomId:string|null):string {
 check(typeof raw==='string' && Buffer.byteLength(raw)<=MAX_SCAN_MODEL_BYTES-16384);
 parseScanReview(JSON.parse(raw),caseId,roomId);
 return raw;
}
export interface ScanRead { schemaVersion:'3'; caseId:string; roomId:string|null }
export interface ScanSave extends ScanRead { expectedCaseRevision:number; expectedModelRevision:number; mutationId:string; reviewJson:string|null }
export interface ScanModelRecord { schemaVersion:'3'; caseId:string; roomId:string|null; revision:number; reviewJson:string|null; updatedAt:string; updatedBy:string; receipts:{mutationId:string;requestHash:string;revision:number}[] }
export interface ScanModelState { schemaVersion:'3'; caseId:string; roomId:string|null; caseRevision:number; modelRevision:number; reviewJson:string|null; reviewSha256:string|null; updatedAt:string|null; updatedBy:string|null; acknowledgedMutationId:string|null }
export type ScanFailure={status:'not_found'|'conflict'|'model_conflict'|'mutation_conflict'|'limit'};
export type ScanResult={status:'found';state:ScanModelState}|ScanFailure;
export interface ScanModelRepository extends HomeModelRepository {
 readScanModelForUser(userId:string,caseId:string,roomId:string|null):Promise<ScanResult>;
 saveScanModelForUser(userId:string,input:ScanSave,at:string):Promise<ScanResult>;
}
export function parseScanRequest(raw:unknown,saving:boolean):ScanRead|ScanSave {
 const r=object(raw,['schemaVersion','caseId','roomId',...(saving?['expectedCaseRevision','expectedModelRevision','mutationId','reviewJson']:[])]);
 check(r.schemaVersion==='3' && evidenceIdentifier(r.caseId) && (r.roomId===null || evidenceIdentifier(r.roomId)));
 if(!saving)return structuredClone(r) as unknown as ScanRead;
 integer(r.expectedCaseRevision,1);integer(r.expectedModelRevision);uuid(r.mutationId);
 return {...structuredClone(r),reviewJson:r.reviewJson===null?null:parseReviewJson(r.reviewJson,r.caseId as string,r.roomId as string|null)} as unknown as ScanSave;
}
export function parseScanRecord(raw:unknown):ScanModelRecord {
 const r=object(raw,['schemaVersion','caseId','roomId','revision','reviewJson','updatedAt','updatedBy','receipts']);
 check(r.schemaVersion==='3' && evidenceIdentifier(r.caseId) && (r.roomId===null || evidenceIdentifier(r.roomId)));integer(r.revision,1);instant(r.updatedAt);check(evidenceIdentifier(r.updatedBy));
 if(r.reviewJson!==null)parseReviewJson(r.reviewJson,r.caseId as string,r.roomId as string|null);
 const ids=new Set<string>();let previous=0;
 for(const raw of list(r.receipts,64)) {
  const receipt=object(raw,['mutationId','requestHash','revision']),id=uuid(receipt.mutationId),rev=integer(receipt.revision,1);
  check(!ids.has(id) && rev===previous+1 || previous===0 && !ids.has(id)); ids.add(id); previous=rev;
  check(rev<=Number(r.revision) && typeof receipt.requestHash==='string' && /^[a-f0-9]{64}$/.test(receipt.requestHash));
 }
 check(previous===r.revision && ids.size===Math.min(Number(r.revision),64));
 check(Buffer.byteLength(JSON.stringify(r))<=MAX_SCAN_MODEL_BYTES);
 return structuredClone(r) as unknown as ScanModelRecord;
}
export function decodeScanRecord(bytes:Uint8Array):ScanModelRecord {
 check(bytes.byteLength<=MAX_SCAN_MODEL_BYTES);
 return parseScanRecord(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)));
}
export function scanState(caseId:string,roomId:string|null,caseRevision:number,record:ScanModelRecord|null,ack:string|null=null):ScanModelState {
 return {schemaVersion:'3',caseId,roomId,caseRevision,modelRevision:record?.revision??0,reviewJson:record?.reviewJson??null,reviewSha256:record?.reviewJson==null?null:createHash('sha256').update(record.reviewJson).digest('hex'),updatedAt:record?.updatedAt??null,updatedBy:record?.updatedBy??null,acknowledgedMutationId:ack};
}
export function changeScanModel(prior:ScanModelRecord|null,input:ScanSave,userId:string,caseRevision:number,at:string):ScanFailure|{status:'changed'|'retry';record:ScanModelRecord} {
 const requestHash=hash(input),receipt=prior?.receipts.find(r=>r.mutationId===input.mutationId);
 if(receipt)return receipt.requestHash===requestHash?{status:'retry',record:prior!}:{status:'mutation_conflict'};
 if(input.expectedCaseRevision!==caseRevision)return {status:'conflict'};
 if(input.expectedModelRevision!==(prior?.revision??0))return {status:'model_conflict'};
 const revision=(prior?.revision??0)+1;
 const record:ScanModelRecord={schemaVersion:'3',caseId:input.caseId,roomId:input.roomId,revision,reviewJson:input.reviewJson,updatedBy:userId,updatedAt:at,
 receipts:[...(prior?.receipts??[]),{mutationId:input.mutationId,requestHash,revision}].slice(-64)};
 try{return {status:'changed',record:parseScanRecord(record)};}catch{return {status:'limit'};}
}

export const scanModelKey = (roomId:string|null) => roomId===null?'legacy':`room:${roomId}`;
export function scanRoomValid(roomId:string|null,reviewJson:string|null,rooms:RoomInstance[]):boolean {
 if(roomId===null)return true;
 const room=rooms.find(r=>r.id===roomId);
 return room!==undefined && (reviewJson===null || !room.archived && JSON.parse(reviewJson).roomType===room.type);
}
