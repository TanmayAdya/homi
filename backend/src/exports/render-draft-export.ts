import { intakeDefinition, parseSavedProgramIntake, type ProgramIntakeAppendix } from '../programs/intake.ts';
import { annotationsBound, parseAnnotations, type AnnotationRecord } from '../assessment/annotations.ts';
import { createHash } from 'node:crypto';
import { PDFArray, PDFDict, PDFDocument, PDFName, PDFNumber, PDFRawStream, PDFRef, StandardFonts, rgb, pushGraphicsState, popGraphicsState, translate, scale as imageScale,
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
import { embedReviewedTextFont, ReviewedTextFontSession, type ReviewedTextFont } from '../pdf/reviewed-text-font.ts';

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
    const layers = await renderTextLayers(snapshot, template, templateBytes, context, answers,
      evidence.map(asset => asset.descriptor), annotations, intake);
    const document = await PDFDocument.load(layers.bytes, { updateMetadata: false });
    check(document.getPageCount() === layers.pageCount && layers.placements.length === evidence.length, 'RENDER_FAILED');
    let compressedImageBytes = 0;
    for (const [index, asset] of evidence.entries()) {
      const placement = layers.placements[index];
      const binding = checkedEvidenceSlot(document, placement, index);
      check(placement.width === asset.descriptor.width && placement.height === asset.descriptor.height, 'RENDER_FAILED');
      const image = await asset.embed(document, MAX_DRAFT_EXPORT_BYTES - compressedImageBytes);
      compressedImageBytes += image.compressedBytes;
      check(image.width === placement.width && image.height === placement.height);
      binding.resources.set(PDFName.of(placement.resourceName), image.ref);
      document.context.delete(binding.placeholder);
    }
    check(!document.context.enumerateIndirectObjects().some(([, object]) =>
      object instanceof PDFRawStream && object.dict.has(PDFName.of('SafeAtHomeEvidenceSlot'))), 'RENDER_FAILED');
    const bytes = await document.save();
    check(bytes.byteLength <= MAX_DRAFT_EXPORT_BYTES, 'CONTENT_TOO_LARGE');
    return { bytes, plan: layers.plan, pageCount: document.getPageCount(), byteLength: bytes.byteLength,
      sha256: createHash('sha256').update(bytes).digest('hex'), renderingVersion: DRAFT_EXPORT_RENDERING_VERSION };
  } catch (error) {
    if (error instanceof DraftExportRenderError) throw error;
    if (error instanceof EvidenceEmbeddingError) throw new DraftExportRenderError(
      error.code === 'EMBED_FAILED' ? 'RENDER_FAILED' : error.code);
    throw new DraftExportRenderError();
  }
}

interface EvidencePlacement {
  pageIndex: number; resourceName: string; objectNumber: number; generationNumber: number;
  width: number; height: number;
}
interface SerializedTextLayers {
  bytes: Uint8Array; plan: FormPreparationPlan; pageCount: number; placements: EvidencePlacement[];
}

async function renderTextLayers(
  snapshot: CaseSnapshot, template: unknown, templateBytes: Uint8Array,
  context: FormPlanningContext, answers: unknown, descriptors: readonly EvidenceDescriptor[],
  annotations: readonly AnnotationRecord[] | undefined, intake: ProgramIntakeAppendix | undefined,
): Promise<SerializedTextLayers> {
  const fontSession = new ReviewedTextFontSession();
  const preview = await renderDraftPreview(snapshot, template, templateBytes, context, answers, fontSession);
  check(preview.renderIssues.length === 0, 'FORM_RENDER_ISSUES');
  check(preview.bytes.byteLength <= MAX_DRAFT_EXPORT_BYTES, 'CONTENT_TOO_LARGE');
  const document = await PDFDocument.load(preview.bytes, { updateMetadata: false });
  const captions = descriptors.map(descriptor => captionSections(snapshot.findings.find(finding => finding.id === descriptor.findingId)!, descriptor));
  const intakeSections = intake ? programIntakeSections(intake, snapshot.revision) : [];
  const textFont = await embedReviewedTextFont(document, [...captions.flat(), ...intakeSections,
    ...(annotations?.flatMap(annotation => annotation.marks.map((mark, index) => annotationLabel(index, mark.label))) ?? [])], fontSession, 'appendix');
  const font = textFont.font;
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const placements: EvidencePlacement[] = [];
  for (let index = 0; index < descriptors.length; index++) {
    const descriptor = descriptors[index];
    const lines = captions[index].flatMap(section => wrapExact(section, textFont));
    const imageTop = 735 - lines.length * LINE_HEIGHT - 16;
    const imageBottom = 68;
    check(imageTop - imageBottom >= 180, 'CONTENT_TOO_LARGE');
    const page = document.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
    draftBanner(page, bold);
    page.drawText(`Reviewed evidence ${index + 1} of ${descriptors.length}`, { x: MARGIN, y: 762, size: 14, font: bold });
    lines.forEach((line, lineIndex) => drawBodyLine(page, line, 735 - lineIndex * LINE_HEIGHT, textFont));
    const scale = Math.min((PAGE_WIDTH - MARGIN * 2) / descriptor.width, (imageTop - imageBottom) / descriptor.height);
    const width = descriptor.width * scale; const height = descriptor.height * scale;
    const placeholder = document.context.register(document.context.stream(new Uint8Array(), {
      Type: 'XObject', Subtype: 'Form', BBox: [0, 0, 1, 1], Resources: {}, SafeAtHomeEvidenceSlot: index,
    }));
    const imageName = page.node.newXObject('Evidence', placeholder);
    placements.push({ pageIndex: document.getPageCount() - 1, resourceName: imageName.decodeText(),
      objectNumber: placeholder.objectNumber, generationNumber: placeholder.generationNumber,
      width: descriptor.width, height: descriptor.height });
    page.pushOperators(pushGraphicsState(), translate((PAGE_WIDTH - width) / 2,
      imageBottom + (imageTop - imageBottom - height) / 2), imageScale(width, height), drawObject(imageName), popGraphicsState());
    if(annotations){
      const a=annotations[index];check(annotationsBound(a,descriptor));
      const left=(PAGE_WIDTH-width)/2,bottom=imageBottom+(imageTop-imageBottom-height)/2;
      for(const [markIndex,mark] of a.marks.entries()){
        const [nx,ny,nw,nh]=mark.rect,x=left+nx/1e6*width,y=bottom+(1-(ny+nh)/1e6)*height;
        page.drawRectangle({x,y,width:nw/1e6*width,height:nh/1e6*height,borderColor:rgb(0.7,0.08,0.08),borderWidth:1.5});
        const label=annotationLabel(markIndex,mark.label);
        check(textFont.supports(label),'TEXT_UNSUPPORTED');
        const size=8,ink=textFont.inkBounds(label);
        const labelLeft=Math.min(0,ink.left)*size,labelRight=Math.max(font.widthOfTextAtSize(label,size),ink.right*size);
        const labelBottom=Math.min(0,ink.bottom)*size,labelTop=Math.max(size,ink.top*size);
        const labelWidth=labelRight-labelLeft,labelHeight=labelTop-labelBottom;
        check(labelWidth<=width-4&&labelHeight<=height-4,'CONTENT_TOO_LARGE');
        const inkX=Math.max(left+2,Math.min(x+2,left+width-labelWidth-2));
        const inkY=Math.max(bottom+2,Math.min(bottom+height-labelHeight-2,y+nh/1e6*height-labelHeight-2));
        const lx=inkX-labelLeft,ly=inkY-labelBottom;
        page.drawRectangle({x:inkX-1,y:inkY-1,width:labelWidth+2,height:labelHeight+2,color:rgb(1,1,1)});
        page.drawText(label,{x:lx,y:ly,size,font,color:rgb(0.7,0.08,0.08)});
      }
    }
    page.drawText('Image shown to fit this page; do not measure physical dimensions from this print.',
      { x: MARGIN, y: 48, size: 8, font });
    page.drawText('Reviewed observation only; not a clinical determination or program approval.',
      { x: MARGIN, y: 35, size: 8, font });
  }
  if (intake) appendProgramIntake(document, intakeSections, textFont, bold);
  document.setTitle('Incomplete draft with reviewed evidence - not submitted');
  const bytes = await document.save();
  check(bytes.byteLength <= MAX_DRAFT_EXPORT_BYTES, 'CONTENT_TOO_LARGE');
  return { bytes, plan: preview.plan, pageCount: document.getPageCount(), placements };
}

function checkedEvidenceSlot(document: PDFDocument, placement: EvidencePlacement, index: number): {
  resources: PDFDict; placeholder: PDFRef;
} {
  check(Number.isSafeInteger(placement.pageIndex) && placement.pageIndex >= 0
    && placement.pageIndex < document.getPageCount(), 'RENDER_FAILED');
  const page = document.getPage(placement.pageIndex);
  const resources = page.node.Resources()?.lookup(PDFName.of('XObject'));
  check(resources instanceof PDFDict, 'RENDER_FAILED');
  const placeholder = resources.get(PDFName.of(placement.resourceName));
  check(placeholder instanceof PDFRef && placeholder.objectNumber === placement.objectNumber
    && placeholder.generationNumber === placement.generationNumber, 'RENDER_FAILED');
  const object = document.context.lookup(placeholder);
  check(object instanceof PDFRawStream && object.getContents().length === 0
    && object.dict.get(PDFName.of('Type')) === PDFName.of('XObject')
    && object.dict.get(PDFName.of('Subtype')) === PDFName.of('Form'), 'RENDER_FAILED');
  const slot = object.dict.get(PDFName.of('SafeAtHomeEvidenceSlot'));
  const box = object.dict.lookup(PDFName.of('BBox'));
  check(slot instanceof PDFNumber && slot.asNumber() === index && box instanceof PDFArray
    && box.asArray().every((coordinate, offset) => coordinate instanceof PDFNumber
      && coordinate.asNumber() === [0, 0, 1, 1][offset]) && box.size() === 4, 'RENDER_FAILED');
  return { resources, placeholder };
}

function draftBanner(page: PDFPage, font: PDFFont): void {
  page.drawRectangle({ x: 0, y: PAGE_HEIGHT - 32, width: PAGE_WIDTH, height: 32, color: rgb(1, 0.94, 0.78) });
  page.drawText(DRAFT_LABEL, { x: 18, y: PAGE_HEIGHT - 21, font, size: 11, color: rgb(0.35, 0.12, 0) });
}

function annotationLabel(index: number, label: string): string { return `${index + 1}${label ? ': ' + label : ''}`; }

function captionSections(finding: Finding, descriptor: EvidenceDescriptor): string[] {
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
  return sections;
}

function wrapExact(text: string, textFont: ReviewedTextFont): string[] {
  check(!/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/u.test(text), 'TEXT_UNSUPPORTED');
  const font = textFont.font;
  const lines: string[] = [];
  for (const paragraph of text.split('\n')) {
    check(textFont.supports(paragraph), 'TEXT_UNSUPPORTED');
    let line = ''; let width = 0; let inkLeft = 0; let inkRight = 0;
    for (const character of paragraph) {
      let advance: number;
      try { font.encodeText(character); advance = font.widthOfTextAtSize(character, FONT_SIZE); }
      catch { throw new DraftExportRenderError('TEXT_UNSUPPORTED'); }
      const ink = textFont.inkBounds(character);
      const left = ink.left * FONT_SIZE, right = Math.max(ink.right * FONT_SIZE, advance);
      if (Math.max(inkRight, width + right) - Math.min(inkLeft, width + left) > TEXT_WIDTH && line.length > 0) {
        lines.push(line); line = ''; width = 0; inkLeft = 0; inkRight = 0;
      }
      check(right - Math.min(0, left) <= TEXT_WIDTH, 'CONTENT_TOO_LARGE');
      inkLeft = Math.min(inkLeft, width + left); inkRight = Math.max(inkRight, width + right);
      line += character; width += advance;
    }
    lines.push(line);
  }
  return lines;
}

function drawBodyLine(page: PDFPage, line: string, y: number, textFont: ReviewedTextFont): void {
  const ink = textFont.inkBounds(line), left = Math.min(0, ink.left * FONT_SIZE);
  check(Math.max(ink.right * FONT_SIZE, textFont.font.widthOfTextAtSize(line, FONT_SIZE)) - left <= PAGE_WIDTH - MARGIN * 2,
    'CONTENT_TOO_LARGE');
  check(ink.top * FONT_SIZE <= LINE_HEIGHT - 3 && ink.bottom * FONT_SIZE >= -3, 'CONTENT_TOO_LARGE');
  page.drawText(line, { x: MARGIN - left, y, size: FONT_SIZE, font: textFont.font });
}

function programIntakeSections(intake: ProgramIntakeAppendix, caseRevision: number): string[] {
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
  return sections;
}

function appendProgramIntake(document: PDFDocument, sections: string[], textFont: ReviewedTextFont, bold: PDFFont): void {
  const font = textFont.font;
  const lines = sections.flatMap(section => wrapExact(section, textFont));
  check(lines.length <= 300, 'CONTENT_TOO_LARGE');
  let page: PDFPage | undefined, y = 0;
  for (const line of lines) {
    if (page === undefined || y < 64) {
      page = document.addPage([PAGE_WIDTH, PAGE_HEIGHT]); draftBanner(page, bold); y = 762;
      page.drawText('Program preparation worksheet', { x: MARGIN, y, size: 14, font: bold }); y -= 30;
      page.drawText('Review all reported facts; requirements and intake remain subject to program confirmation.', { x: MARGIN, y: 35, size: 8, font });
    }
    drawBodyLine(page, line, y, textFont); y -= LINE_HEIGHT;
  }
}
