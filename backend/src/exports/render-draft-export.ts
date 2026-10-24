import { intakeDefinition, parseSavedProgramIntake, type ProgramIntakeAppendix } from '../programs/intake.ts';
import { annotationsBound, parseAnnotations, type AnnotationRecord } from '../assessment/annotations.ts';
import { createHash } from 'node:crypto';
import { PDFDocument, StandardFonts, rgb, pushGraphicsState, popGraphicsState, translate, scale as imageScale,
  drawObject, type PDFFont, type PDFPage } from 'pdf-lib';
import type { CaseSnapshot, Finding } from '../types.ts';
import { renderDraftPreview } from '../forms/render-draft-preview.ts';
import type { FormPlanningContext, FormPreparationPlan } from '../forms/field-mapping.ts';
import { MAX_TEMPLATE_BYTES } from '../forms/template-artifact.ts';
import { MAX_SELECTED_EVIDENCE, type EvidenceAsset, type EvidenceDescriptor } from '../evidence/types.ts';
import { parseEvidenceDescriptor } from '../evidence/validation.ts';
import { exportEvidenceFitsBudget } from '../evidence/export-budget.ts';
import { MAX_SANITIZED_IMAGE_BYTES } from '../evidence/image-sanitizer.ts';
import { instantMicros } from '../packets.ts';
import { prepareEvidenceImageEmbeddings, EvidenceEmbeddingError } from './embed-evidence-image.ts';

export const MAX_DRAFT_EXPORT_BYTES = 32 * 1024 * 1024;
export const DRAFT_EXPORT_RENDERING_VERSION = 'draft-export-v1' as const;
const DRAFT_LABEL = 'INCOMPLETE DRAFT - NOT SUBMITTED';
const PAGE_WIDTH = 612;
const PAGE_HEIGHT = 824;
const MARGIN = 36;
const TEXT_WIDTH = PAGE_WIDTH - MARGIN * 2 - 3;
const FONT_SIZE = 10;
const LINE_HEIGHT = 14;

export type DraftExportRenderErrorCode = 'FORM_RENDER_ISSUES' | 'EVIDENCE_INVALID' | 'TEXT_UNSUPPORTED'
  | 'CONTENT_TOO_LARGE' | 'RENDER_FAILED';
export class DraftExportRenderError extends Error {
  readonly code: DraftExportRenderErrorCode;
  constructor(code: DraftExportRenderErrorCode = 'RENDER_FAILED') {
    const messages: Record<DraftExportRenderErrorCode, string> = {
      FORM_RENDER_ISSUES: 'Review form values that cannot be rendered before exporting.',
      EVIDENCE_INVALID: 'Reload and review the selected evidence before exporting.',
      TEXT_UNSUPPORTED: 'Some evidence text cannot be rendered accurately with the available font.',
      CONTENT_TOO_LARGE: 'The selected evidence exceeds the draft export size or page-layout limits.',
      RENDER_FAILED: 'The draft export could not be prepared.',
    };
    super(messages[code]); this.name = 'DraftExportRenderError'; this.code = code;
  }
}

export interface RenderedDraftExport {
  bytes: Uint8Array;
  plan: FormPreparationPlan;
  pageCount: number;
  sha256: string;
  byteLength: number;
  renderingVersion: typeof DRAFT_EXPORT_RENDERING_VERSION;
}

function check(condition: unknown, code: DraftExportRenderErrorCode = 'EVIDENCE_INVALID'): asserts condition {
  if (!condition) throw new DraftExportRenderError(code);
}

export async function renderDraftExport(
  snapshotInput: CaseSnapshot, templateInput: unknown, templateBytesInput: Uint8Array,
  planningContextInput: FormPlanningContext, answersInput: unknown,
  evidenceAssetsInput: ReadonlyArray<EvidenceAsset>,
  annotationInput?:ReadonlyArray<AnnotationRecord>,
  intakeInput?: ProgramIntakeAppendix,
): Promise<RenderedDraftExport> {
  try {
    check(templateBytesInput instanceof Uint8Array && templateBytesInput.byteLength >= 8
      && templateBytesInput.byteLength <= MAX_TEMPLATE_BYTES, 'RENDER_FAILED');
    check(Array.isArray(evidenceAssetsInput) && evidenceAssetsInput.length <= MAX_SELECTED_EVIDENCE);
    const intake = intakeInput === undefined ? undefined : structuredClone(intakeInput);
    if (intake) {
      const definition = intakeDefinition(planningContextInput.programId);
      check(definition !== null && JSON.stringify(definition) === JSON.stringify(intake.definition));
      if (intake.saved) {
        intake.saved = parseSavedProgramIntake(intake.saved);
        check(intake.saved.caseId === snapshotInput.caseId && intake.saved.caseRevision <= snapshotInput.revision &&
          intake.saved.programId === planningContextInput.programId && instantMicros(intake.saved.updatedAt) <= instantMicros(planningContextInput.plannedAt));
      }
    }
    const annotations=annotationInput?.map(parseAnnotations);
    check(annotations===undefined||annotations.length===evidenceAssetsInput.length);
    const descriptors: EvidenceDescriptor[] = [];
    for (const asset of evidenceAssetsInput) {
      check(asset !== null && typeof asset === 'object' && asset.bytes instanceof Uint8Array);
      check(asset.bytes.byteLength <= MAX_SANITIZED_IMAGE_BYTES, 'CONTENT_TOO_LARGE');
      const descriptor = parseEvidenceDescriptor(asset.descriptor);
      check(asset.bytes.byteLength === descriptor.byteLength);
      descriptors.push(descriptor);
    }
    check(exportEvidenceFitsBudget(descriptors), 'CONTENT_TOO_LARGE');
    const snapshot = structuredClone(snapshotInput);
    const template = structuredClone(templateInput);
    const templateBytes = Uint8Array.from(templateBytesInput);
    const context = structuredClone(planningContextInput);
    const answers = structuredClone(answersInput);
    const preparingEvidence = prepareEvidenceImageEmbeddings(evidenceAssetsInput);
    evidenceAssetsInput = [];
    const evidence = await preparingEvidence;
    const selected = new Set<string>();
    for (const asset of evidence) {
      const descriptor = asset.descriptor;
      check(descriptor.caseId === snapshot.caseId && !selected.has(descriptor.evidenceId));
      selected.add(descriptor.evidenceId);
      const finding = snapshot.findings.find(finding => finding.id === descriptor.findingId);
      check(finding?.reviewState === 'confirmed' && finding.evidenceIds.includes(descriptor.evidenceId));
      check(instantMicros(descriptor.preparedAt) <= instantMicros(context.plannedAt));
    }
    const preview = await renderDraftPreview(snapshot, template, templateBytes, context, answers);
    check(preview.renderIssues.length === 0, 'FORM_RENDER_ISSUES');
    check(preview.bytes.byteLength <= MAX_DRAFT_EXPORT_BYTES, 'CONTENT_TOO_LARGE');
    const document = await PDFDocument.load(preview.bytes, { updateMetadata: false });
    const font = await document.embedFont(StandardFonts.Helvetica);
    const bold = await document.embedFont(StandardFonts.HelveticaBold);
    let compressedImageBytes = 0;
    for (let index = 0; index < evidence.length; index++) {
      const asset = evidence[index];
      const finding = snapshot.findings.find(finding => finding.id === asset.descriptor.findingId)!;
      const lines = captionLines(finding, asset.descriptor, font);
      const imageTop = 735 - lines.length * LINE_HEIGHT - 16;
      const imageBottom = 68;
      check(imageTop - imageBottom >= 180, 'CONTENT_TOO_LARGE');
      const page = document.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
      draftBanner(page, bold);
      page.drawText(`Reviewed evidence ${index + 1} of ${evidence.length}`, { x: MARGIN, y: 762, size: 14, font: bold });
      lines.forEach((line, lineIndex) => page.drawText(line, { x: MARGIN, y: 735 - lineIndex * LINE_HEIGHT, size: FONT_SIZE, font }));
      const image = await asset.embed(document, MAX_DRAFT_EXPORT_BYTES - compressedImageBytes);
      compressedImageBytes += image.compressedBytes;
      check(image.width === asset.descriptor.width && image.height === asset.descriptor.height);
      const scale = Math.min((PAGE_WIDTH - MARGIN * 2) / image.width, (imageTop - imageBottom) / image.height);
      const width = image.width * scale; const height = image.height * scale;
      const imageName = page.node.newXObject('Evidence', image.ref);
      page.pushOperators(pushGraphicsState(), translate((PAGE_WIDTH - width) / 2,
        imageBottom + (imageTop - imageBottom - height) / 2), imageScale(width, height), drawObject(imageName), popGraphicsState());
      if(annotations){
        const a=annotations[index];check(annotationsBound(a,asset.descriptor));
        const left=(PAGE_WIDTH-width)/2,bottom=imageBottom+(imageTop-imageBottom-height)/2;
        for(const [markIndex,mark] of a.marks.entries()){
          const [nx,ny,nw,nh]=mark.rect,x=left+nx/1e6*width,y=bottom+(1-(ny+nh)/1e6)*height;
          page.drawRectangle({x,y,width:nw/1e6*width,height:nh/1e6*height,borderColor:rgb(0.7,0.08,0.08),borderWidth:1.5});
          const label=`${markIndex+1}${mark.label ? ': '+mark.label:''}`;
          let encoded;try{encoded=font.encodeText(label);}catch{throw new DraftExportRenderError('TEXT_UNSUPPORTED');}
          void encoded;
          const size=8,labelWidth=font.widthOfTextAtSize(label,size);
          check(labelWidth<=width-4,'CONTENT_TOO_LARGE');
          const lx=Math.min(x+2,left+width-labelWidth-2),ly=Math.max(bottom+2,Math.min(bottom+height-10,y+nh/1e6*height-10));
          page.drawRectangle({x:lx-1,y:ly-1,width:labelWidth+2,height:10,color:rgb(1,1,1)});
          page.drawText(label,{x:lx,y:ly,size,font,color:rgb(0.7,0.08,0.08)});
        }
      }
      page.drawText('Image shown to fit this page; do not measure physical dimensions from this print.',
        { x: MARGIN, y: 48, size: 8, font });
      page.drawText('Reviewed observation only; not a clinical determination or program approval.',
        { x: MARGIN, y: 35, size: 8, font });
    }
    if (intake) appendProgramIntake(document, intake, snapshot.revision, font, bold);
    document.setTitle('Incomplete draft with reviewed evidence - not submitted');
    const bytes = await document.save();
    check(bytes.byteLength <= MAX_DRAFT_EXPORT_BYTES, 'CONTENT_TOO_LARGE');
    return { bytes, plan: preview.plan, pageCount: document.getPageCount(), byteLength: bytes.byteLength,
      sha256: createHash('sha256').update(bytes).digest('hex'), renderingVersion: DRAFT_EXPORT_RENDERING_VERSION };
  } catch (error) {
    if (error instanceof DraftExportRenderError) throw error;
    if (error instanceof EvidenceEmbeddingError) throw new DraftExportRenderError(
      error.code === 'EMBED_FAILED' ? 'RENDER_FAILED' : error.code);
    throw new DraftExportRenderError();
  }
}

function draftBanner(page: PDFPage, font: PDFFont): void {
  page.drawRectangle({ x: 0, y: PAGE_HEIGHT - 32, width: PAGE_WIDTH, height: 32, color: rgb(1, 0.94, 0.78) });
  page.drawText(DRAFT_LABEL, { x: 18, y: PAGE_HEIGHT - 21, font, size: 11, color: rgb(0.35, 0.12, 0) });
}

function captionLines(finding: Finding, descriptor: EvidenceDescriptor, font: PDFFont): string[] {
  check(finding.observation.length <= 1200 && finding.measurements.length <= 8, 'CONTENT_TOO_LARGE');
  const room = { bathroom: 'Bathroom', entrance: 'Entrance', other: 'Other room' }[finding.room];
  const sections = [
    `Room: ${room}. Finding review: confirmed.`,
    `Observation: ${finding.observation}`,
    `Captured: ${descriptor.capturedAt ?? 'Unknown; no capture time supplied'}.`,
    `Prepared: ${descriptor.preparedAt}. Image: ${descriptor.width} x ${descriptor.height} pixels.`,
  ];
  if (finding.measurements.length === 0) sections.push('Measurements: none supplied; physical dimensions remain unknown.');
  else {
    sections.push('Measurements (recorded separately from the image):');
    for (const measurement of finding.measurements) {
      check(measurement.type.length <= 80, 'CONTENT_TOO_LARGE');
      sections.push(`${measurement.type}: ${measurement.value} ${measurement.unit}; method: ${measurement.method}; review: ${measurement.confirmed ? 'confirmed' : 'not confirmed'}.`);
    }
  }
  return sections.flatMap(section => wrapExact(section, font));
}

function wrapExact(text: string, font: PDFFont): string[] {
  check(!/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/u.test(text), 'TEXT_UNSUPPORTED');
  const lines: string[] = [];
  for (const paragraph of text.split('\n')) {
    let line = ''; let width = 0;
    for (const character of paragraph) {
      let advance: number;
      try { font.encodeText(character); advance = font.widthOfTextAtSize(character, FONT_SIZE); }
      catch { throw new DraftExportRenderError('TEXT_UNSUPPORTED'); }
      if (width + advance > TEXT_WIDTH && line.length > 0) { lines.push(line); line = ''; width = 0; }
      line += character; width += advance;
    }
    lines.push(line);
  }
  return lines;
}

function appendProgramIntake(document: PDFDocument, intake: ProgramIntakeAppendix, caseRevision: number, font: PDFFont, bold: PDFFont): void {
  const { definition, saved } = intake;
  const sections = [
    'PROGRAM PREPARATION - REPORTED FACTS ONLY',
    definition.programId === 'rtp-home-repair' ? 'App-generated worksheet; not an official RTP application.' : 'Supplemental preparation worksheet; not a clinical determination.',
    saved === null ? 'No program-specific answers have been saved. Every question remains unknown.'
      : `Reported answers saved ${saved.updatedAt}, case revision ${saved.caseRevision}; this draft uses case revision ${caseRevision}.`,
    ...(saved !== null && saved.caseRevision !== caseRevision ? ['The case changed after these answers were saved. Review them against this draft before use.'] : []),
    'These answers are unverified reports. No consent, professional assessment, submission or approval is inferred.',
    `Questionnaire version: ${definition.questionnaireVersion}`,
  ];
  for (const question of definition.questions) {
    const answer = saved?.answers.find(a => a.key === question.key);
    const value = answer?.value;
    const display = value === null || value === undefined ? 'Unknown / not provided' : typeof value === 'boolean' ? (value ? 'Reported Yes' : 'Reported No')
      : typeof value === 'number' ? `Reported USD ${value.toFixed(2)}` : `Reported: ${value}`;
    sections.push('', question.label, display, question.description);
  }
  const cost = saved?.answers.find(a => a.key === 'estimatedCostUsd')?.value;
  if (definition.programId === 'hpsm-eaa' && typeof cost === 'number' && cost > 7500) {
    sections.push('', 'EXCEPTION REVIEW: Reported cost is above $7,500. Prepare the HPSM exception request and obtain plan review; this is not an automatic rejection.');
  }
  const lines = sections.flatMap(section => wrapExact(section, font));
  check(lines.length <= 300, 'CONTENT_TOO_LARGE');
  let page: PDFPage | undefined, y = 0;
  for (const line of lines) {
    if (page === undefined || y < 64) {
      page = document.addPage([PAGE_WIDTH, PAGE_HEIGHT]); draftBanner(page, bold); y = 762;
      page.drawText('Program preparation worksheet', { x: MARGIN, y, size: 14, font: bold }); y -= 30;
      page.drawText('Review all reported facts; requirements and intake remain subject to program confirmation.', { x: MARGIN, y: 35, size: 8, font });
    }
    page.drawText(line, { x: MARGIN, y, size: FONT_SIZE, font }); y -= LINE_HEIGHT;
  }
}
