import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument, PDFArray, PDFRawStream, decodePDFRawStream } from 'pdf-lib';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { createDemoFormArtifact } from '../fixtures/demo-form-template.ts';
import { demoProgram } from '../fixtures/demo-program.ts';
import { createFormAnswerContext } from '../src/forms/form-answers.ts';
import { handleDraftExport } from '../src/api/draft-export.ts';
import { parseExportArtifactMetadata, parseStoredExportArtifactMetadata } from '../src/exports/validation.ts';
import { create, imageInput, OWNER, OTHER, iso } from './postgres/fixtures.ts';
import type { ExportArtifactMetadata } from '../src/exports/types.ts';

test('annotation-aware PDF has strict v2 metadata, survives retry/download, blocks v1 omission and invalidates on edit',async()=>{
 const repo=new MemoryCaseRepository([]),snapshot=await create(repo),image=await repo.saveEvidenceIfCurrent(await imageInput(snapshot));
 assert.equal(image.status,'saved');if(image.status!=='saved')return;const d=image.asset.descriptor;
 const now=new Date(),form=await createDemoFormArtifact(demoProgram.programId);
 const deps={cases:repo,authenticate:async(token:string)=>token==='alice'?{userId:OWNER}:token==='bob'?{userId:OTHER}:null,
  now:()=>now,loadRegistry:async()=>[{...demoProgram,recheckAfter:null}],loadFormTemplate:async()=>form,allowDemoPrograms:true};
 const annotationRequest={schemaVersion:'2' as const,caseId:snapshot.caseId,expectedCaseRevision:1,expectedCatalogRevision:1,evidenceId:d.evidenceId,expectedEvidenceRevision:1,
  expectedAnnotationRevision:0,expectedImageSha256:d.sha256,expectedImageWidth:d.width,expectedImageHeight:d.height,marks:[{id:'rectangle-1',rect:[100000,200000,300000,400000] as [number,number,number,number],label:'Raised threshold'}],reviewedForExport:true};
 const saved=await repo.saveAnnotationsForUser(OWNER,annotationRequest,now.toISOString());assert.equal(saved.status,'found');
 const request={schemaVersion:'2',caseId:snapshot.caseId,expectedCaseRevision:1,programId:demoProgram.programId,
  expectedFormContextId:createFormAnswerContext(form.template).formContextId,expectedAnswerRevision:0,expectedEvidenceCatalogRevision:2,generationKey:'annotated-export-1',
  selectedEvidence:[{evidenceId:d.evidenceId,expectedEvidenceRevision:1,expectedAnnotationRevision:1,reviewedForExport:true}]};
 const call=(body:unknown,version:1|2=2,route:'create-draft-export'|'download-draft-export'='create-draft-export',token='alice')=>handleDraftExport({body,bearerToken:token},deps,route,version);
 const v1={...request,schemaVersion:'1',selectedEvidence:[{evidenceId:d.evidenceId,expectedEvidenceRevision:1,reviewedForExport:true}]};
 const blocked=await call(v1,1);assert.equal(blocked.status,409);assert.ok('error'in blocked.body);assert.equal(blocked.body.error.code,'ANNOTATIONS_REQUIRE_V2');
 const exported=await call(request);assert.equal(exported.status,200,JSON.stringify(exported.body));const metadata=exported.body as ExportArtifactMetadata;
 assert.equal(metadata.schemaVersion,'2');assert.equal(metadata.selectedEvidence[0].annotationRevision,1);assert.equal(metadata.renderingVersion,'draft-export-annotations-v2');
 assert.throws(()=>parseExportArtifactMetadata(metadata));assert.deepEqual(parseStoredExportArtifactMetadata(metadata),metadata);
 assert.deepEqual((await call(request)).body,metadata);
 const download={schemaVersion:'2',caseId:snapshot.caseId,expectedCaseRevision:1,artifactId:metadata.artifactId};
 assert.equal((await call(download,2,'download-draft-export','bob')).status,404);
 const binary=await call(download,2,'download-draft-export');assert.equal(binary.status,200,JSON.stringify(binary.body));assert.ok(binary.body instanceof Uint8Array);
 const pdf=await PDFDocument.load(binary.body);assert.equal(pdf.getPageCount(),2);
 const content=pdf.getPage(1).node.Contents();
 const operators=(content instanceof PDFArray?content.asArray():[content]).map(ref=>{const stream=pdf.context.lookup(ref);assert.ok(stream instanceof PDFRawStream);return Buffer.from(decodePDFRawStream(stream).decode()).toString('latin1');}).join('\n');
 assert.ok(operators.includes(Buffer.from('1: Raised threshold').toString('hex').toUpperCase()),'Reviewed label must be in PDF page content.');
 assert.match(operators,/0\.7 0\.08 0\.08 RG/, 'Overlay stroke must be rendered, not merely stored in metadata.');
 assert.match(operators,/1\.5 w/);
 assert.equal(pdf.getPage(1).node.Annots()?.size()??0,0,'Overlays are PDF page vectors, never externally active PDF annotations.');
 assert.equal((await repo.saveAnnotationsForUser(OWNER,{...annotationRequest,expectedCatalogRevision:2,expectedAnnotationRevision:1,marks:[]},iso())).status,'found');
 assert.equal((await call(download,2,'download-draft-export')).status,409);
});
