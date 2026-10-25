import { exact, check, hash } from './metadata.ts';
import { evidenceIdentifier as id, evidenceRevision as revision, evidenceInstant as instant } from '../evidence/validation.ts';
import type { EvidenceDescriptor } from '../evidence/types.ts';
export interface AnnotationMark { id:string; rect:[number,number,number,number]; label:string }
export interface AnnotationRecord {
  schemaVersion:'2'; caseId:string;evidenceId:string;annotationRevision:number;evidenceRevision:number;
  imageSha256:string;imageWidth:number;imageHeight:number;coordinateSpace:'normalized-top-left-1e6';marks:AnnotationMark[];
  reviewState:'needs_review'|'reviewed';reviewedCaseRevision:number|null;reviewedAt:string|null;reviewedBy:string|null;
}
export interface AnnotationRead {schemaVersion:'2';caseId:string;expectedCaseRevision:number;expectedCatalogRevision:number;evidenceId:string;expectedEvidenceRevision:number}
export interface AnnotationSave extends AnnotationRead {expectedAnnotationRevision:number;expectedImageSha256:string;expectedImageWidth:number;expectedImageHeight:number;marks:AnnotationMark[];reviewedForExport:boolean}
export interface AnnotationState {schemaVersion:'2';caseId:string;caseRevision:number;catalogRevision:number;annotation:AnnotationRecord}
export type AnnotationResult={status:'found';state:AnnotationState}|{status:'not_found'|'conflict'|'evidence_conflict'|'annotation_conflict'};
export interface AnnotationRepository {
  readAnnotationsForUser(userId:string,input:AnnotationRead):Promise<AnnotationResult>;
  saveAnnotationsForUser(userId:string,input:AnnotationSave,at:string):Promise<AnnotationResult>;
}
export function parseMarks(value:unknown):AnnotationMark[] {
  check(Array.isArray(value)&&value.length<=20); const ids=new Set<string>();let labels=0;
  for(const m of value) {
    check(exact(m,['id','rect','label'])&&id(m.id)&&!ids.has(m.id)&&Array.isArray(m.rect)&&m.rect.length===4
      &&m.rect.every(n=>Number.isSafeInteger(n)&&n>=0&&n<=1000000)&&m.rect[2]>0&&m.rect[3]>0
      &&m.rect[0]+m.rect[2]<=1000000&&m.rect[1]+m.rect[3]<=1000000
      &&typeof m.label==='string'&&[...m.label].length<=80&&!/[\u0000-\u001f\u007f-\u009f]/.test(m.label));
    ids.add(m.id);labels += [...m.label].length;
  }
  check(labels<=800&&Buffer.byteLength(JSON.stringify(value))<=12*1024);return structuredClone(value) as AnnotationMark[];
}
export function parseAnnotationRequest(value:unknown,save:boolean):AnnotationRead|AnnotationSave {
  check(exact(value,['schemaVersion','caseId','expectedCaseRevision','expectedCatalogRevision','evidenceId','expectedEvidenceRevision',
    ...(save?['expectedAnnotationRevision','expectedImageSha256','expectedImageWidth','expectedImageHeight','marks','reviewedForExport']:[])])
    &&value.schemaVersion==='2'&&id(value.caseId)&&id(value.evidenceId)&&revision(value.expectedCaseRevision)
    &&revision(value.expectedCatalogRevision,true)&&revision(value.expectedEvidenceRevision));
  if(save)check(revision(value.expectedAnnotationRevision,true)&&typeof value.expectedImageSha256==='string'&&/^[a-f0-9]{64}$/.test(value.expectedImageSha256)
    &&revision(value.expectedImageWidth)&&value.expectedImageWidth<=8192&&revision(value.expectedImageHeight)&&value.expectedImageHeight<=8192
    &&typeof value.reviewedForExport==='boolean'&&parseMarks(value.marks));
  return structuredClone(value) as unknown as AnnotationRead|AnnotationSave;
}
export function emptyAnnotations(d:EvidenceDescriptor,annotationRevision=0):AnnotationRecord {
  return {schemaVersion:'2',caseId:d.caseId,evidenceId:d.evidenceId,annotationRevision,evidenceRevision:d.evidenceRevision,
    imageSha256:d.sha256,imageWidth:d.width,imageHeight:d.height,coordinateSpace:'normalized-top-left-1e6',marks:[],
    reviewState:'needs_review',reviewedCaseRevision:null,reviewedAt:null,reviewedBy:null};
}
export function parseAnnotations(value:unknown):AnnotationRecord {
  check(exact(value,['schemaVersion','caseId','evidenceId','annotationRevision','evidenceRevision','imageSha256','imageWidth','imageHeight','coordinateSpace','marks',
    'reviewState','reviewedCaseRevision','reviewedAt','reviewedBy'])&&value.schemaVersion==='2'&&id(value.caseId)&&id(value.evidenceId)
    &&revision(value.annotationRevision,true)&&revision(value.evidenceRevision)&&typeof value.imageSha256==='string'&&/^[a-f0-9]{64}$/.test(value.imageSha256)
    &&revision(value.imageWidth)&&value.imageWidth<=8192&&revision(value.imageHeight)&&value.imageHeight<=8192&&value.coordinateSpace==='normalized-top-left-1e6'
    &&['needs_review','reviewed'].includes(value.reviewState));parseMarks(value.marks);
  if(value.reviewState==='reviewed')check(revision(value.reviewedCaseRevision)&&instant(value.reviewedAt)&&id(value.reviewedBy));
  else check(value.reviewedCaseRevision===null&&value.reviewedAt===null&&value.reviewedBy===null);
  return structuredClone(value) as AnnotationRecord;
}
export function annotationsBound(a:AnnotationRecord,d:EvidenceDescriptor):boolean {
  return a.caseId===d.caseId&&a.evidenceId===d.evidenceId&&a.evidenceRevision===d.evidenceRevision
    &&a.imageSha256===d.sha256&&a.imageWidth===d.width&&a.imageHeight===d.height;
}
export function changedAnnotations(d:EvidenceDescriptor,prior:AnnotationRecord|undefined,input:AnnotationSave,userId:string,at:string):AnnotationRecord {
  return parseAnnotations({...emptyAnnotations(d,(prior?.annotationRevision??0)+1),marks:parseMarks(input.marks),
    reviewState:input.reviewedForExport?'reviewed':'needs_review',reviewedCaseRevision:input.reviewedForExport?input.expectedCaseRevision:null,
    reviewedAt:input.reviewedForExport?at:null,reviewedBy:input.reviewedForExport?userId:null});
}
export const annotationHash=(a:AnnotationRecord)=>hash(a);
