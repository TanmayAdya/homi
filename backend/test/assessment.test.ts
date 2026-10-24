import assert from 'node:assert/strict';
import test from 'node:test';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { parseAssessmentSave, type AssessmentSave } from '../src/assessment/metadata.ts';
import { caseFingerprint } from '../src/evidence/validation.ts';
import { draft, imageInput, OWNER, OTHER, iso, create } from './postgres/fixtures.ts';
import { parseAnnotationRequest } from '../src/assessment/annotations.ts';

export function assessmentInput(snapshot: ReturnType<typeof draft>&{revision:number},catalog=0):AssessmentSave {
 const {revision,...replacement}=structuredClone(snapshot);
 replacement.findings[0].measurements=[{type:'clear width',value:254,unit:'mm',method:'manual',confirmed:true}];
 return {schemaVersion:'2',caseId:snapshot.caseId,expectedCaseRevision:revision,expectedCaseFingerprint:caseFingerprint(snapshot),expectedCatalogRevision:catalog,expectedAssessmentRevision:0,mutationId:'mutation-0001',draft:replacement,
 metadata:{measurements:[{findingId:'fictional-finding',type:'clear width',originalText:'10',originalUnit:'in',decimalSeparator:'point',source:'manual',recorder:'self',recordedAt:null}],reviews:[{findingId:'fictional-finding',state:'confirmed',note:null}]}};
}
test('assessment save is atomic, owner scoped and exact retry survives later case edits',async()=>{
 const repo=new MemoryCaseRepository([]),snapshot=await create(repo),input=assessmentInput(structuredClone(snapshot));
 input.expectedCaseFingerprint=caseFingerprint(snapshot);
 assert.equal((await repo.saveAssessmentForUser(OTHER,input,iso())).status,'not_found');
 const result=await repo.saveAssessmentForUser(OWNER,input,iso());assert.equal(result.status,'found');if(result.status!=='found')return;
 assert.equal(result.state.case.revision,2);assert.equal(result.state.assessment.history.length,1);assert.equal(result.state.assessment.metadata.measurements[0].originalUnit,'in');
 const later={...input.draft,profile:{...input.draft.profile,city:'Changed'}};
 assert.equal((await repo.replaceIfCurrent(OWNER,snapshot.caseId,2,later)).status,'saved');
 const retry=await repo.saveAssessmentForUser(OWNER,input,iso());assert.equal(retry.status,'found');if(retry.status==='found'){
  assert.equal(retry.state.case.revision,3);assert.equal(retry.state.assessment.caseRevision,2);assert.equal(retry.state.acknowledgedMutationId,input.mutationId);assert.equal(retry.state.assessment.history.length,1);
 }
 assert.equal((await repo.saveAssessmentForUser(OWNER,{...input,metadata:{...input.metadata,reviews:[{findingId:'fictional-finding',state:'confirmed',note:'Different'}]}},iso())).status,'mutation_conflict');
});
test('original units must agree with millimetres and metadata cannot smuggle history or duplicate keys',()=>{
 const snapshot={...draft(),revision:1},input=assessmentInput(snapshot);
 for(const bad of [{...input,history:[]},{...input,metadata:{...input.metadata,measurements:[...input.metadata.measurements,...input.metadata.measurements]}},
  {...input,metadata:{...input.metadata,measurements:[{...input.metadata.measurements[0],originalText:'999'}]}}])assert.throws(()=>parseAssessmentSave(bad));
});
test('annotations bind canonical pixels, owner and revisions, clear on replacement and retain counter',async()=>{
 const repo=new MemoryCaseRepository([]),snapshot=await create(repo),image=await imageInput(snapshot);
 const saved=await repo.saveEvidenceIfCurrent(image);assert.equal(saved.status,'saved');if(saved.status!=='saved')return;
 const d=saved.asset.descriptor,request={schemaVersion:'2' as const,caseId:snapshot.caseId,expectedCaseRevision:1,expectedCatalogRevision:1,evidenceId:d.evidenceId,expectedEvidenceRevision:1};
 const read=await repo.readAnnotationsForUser(OWNER,request);assert.equal(read.status,'found');
 const write={...request,expectedAnnotationRevision:0,expectedImageSha256:d.sha256,expectedImageWidth:d.width,expectedImageHeight:d.height,
 marks:[{id:'mark',rect:[100000,100000,300000,300000] as [number,number,number,number],label:'Observed area'}],reviewedForExport:true};
 assert.equal((await repo.saveAnnotationsForUser(OTHER,write,iso())).status,'not_found');
 assert.equal((await repo.saveAnnotationsForUser(OWNER,{...write,expectedImageSha256:'0'.repeat(64)},iso())).status,'evidence_conflict');
 const annotation=await repo.saveAnnotationsForUser(OWNER,write,iso());assert.equal(annotation.status,'found');if(annotation.status!=='found')return;
 assert.equal(annotation.state.catalogRevision,2);assert.equal(annotation.state.annotation.reviewedBy,OWNER);
 assert.equal((await repo.saveAnnotationsForUser(OWNER,write,iso())).status,'evidence_conflict');
 assert.equal((await repo.saveEvidenceIfCurrent({...image,expectedCatalogRevision:2,expectedEvidenceRevision:1,preparedAt:iso()})).status,'saved');
 const replaced=await repo.readAnnotationsForUser(OWNER,{...request,expectedCatalogRevision:3,expectedEvidenceRevision:2});assert.equal(replaced.status,'found');if(replaced.status==='found'){
 assert.equal(replaced.state.annotation.annotationRevision,2);assert.deepEqual(replaced.state.annotation.marks,[]);assert.equal(replaced.state.annotation.reviewState,'needs_review');assert.equal(replaced.state.annotation.evidenceRevision,2);
 }
 assert.throws(()=>parseAnnotationRequest({...write,marks:[{...write.marks[0],rect:[900000,0,200000,200000]}]},true));
});
