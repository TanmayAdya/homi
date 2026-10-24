import {
  PDFArray, PDFCheckBox, PDFDict, PDFDocument, PDFName, PDFNumber, PDFRawStream,
  PDFRef, PDFStream, StandardFonts, rgb,
  type PDFField, type PDFFont, type PDFPage, type PDFWidgetAnnotation,
} from 'pdf-lib';
import type { CaseSnapshot } from '../types.ts';
import {
  defineVerifiedFormTemplate, planFormFields,
  type FormPlanningContext, type FormPreparationPlan,
  type VerifiedFormTemplate,
} from './field-mapping.ts';
import { MAX_TEMPLATE_BYTES, verifyTemplateBytes } from './template-artifact.ts';

const BANNER_HEIGHT = 32;
const DRAFT_LABEL = 'INCOMPLETE DRAFT - NOT SUBMITTED';
const TEXT_INSET = 2;
const MIN_TEXT_SIZE = 8;
const MAX_TEXT_SIZE = 10;
const HELVETICA_BOUNDS = { left: -0.166, bottom: -0.225, right: 1, top: 0.931 };

export interface DraftRenderIssue {
  readonly fieldName: string;
  readonly code: 'UNSUPPORTED_CHARACTERS' | 'TEXT_DOES_NOT_FIT' | 'UNSUPPORTED_TEXT_LAYOUT';
  readonly message: string;
}

export interface DraftPreview {
  bytes: Uint8Array;
  plan: FormPreparationPlan;
  renderIssues: readonly DraftRenderIssue[];
}

export class DraftPreviewError extends Error {
  constructor() {
    super('The form preview could not be prepared from the verified template.');
    this.name = 'DraftPreviewError';
  }
}

export async function renderDraftPreview(
  snapshot: CaseSnapshot,
  templateInput: unknown,
  templateBytes: Uint8Array,
  context: FormPlanningContext,
  answersInput?: unknown,
): Promise<DraftPreview> {
  try {
    const detachedCase = structuredClone(snapshot);
    const template = defineVerifiedFormTemplate(templateInput);
    check(templateBytes instanceof Uint8Array && templateBytes.byteLength >= 8
      && templateBytes.byteLength <= MAX_TEMPLATE_BYTES);
    const bytes = Uint8Array.from(templateBytes);
    const detachedContext = structuredClone(context);
    const detachedAnswers = structuredClone(answersInput);
    const actualHash = verifyTemplateBytes(bytes, template.templateSha256);
    check(detachedContext.templateSha256 === actualHash);
    const plan = planFormFields(detachedCase, template, { ...detachedContext, templateSha256: actualHash }, detachedAnswers);
    const source = await PDFDocument.load(bytes, { updateMetadata: false, throwOnInvalidObject: true });
    check(!source.isEncrypted);
    rejectActiveDocumentFeatures(source);
    const inventory = verifyInventory(source, template);
    const textFont = source.embedStandardFont(StandardFonts.Helvetica);
    const renderIssues: DraftRenderIssue[] = [];

    for (const [index, definition] of template.fields.entries()) {
      const { field, widgets } = inventory[index];
      const decision = plan.fields[index];
      let textLayout: TextLayout | undefined;
      if (decision.status === 'mapped' && definition.pdfType === 'Tx') {
        check(decision.origin?.kind === 'reviewed_form_answer'
          && !['clinical', 'consent', 'signature', 'layout', 'routing'].includes(definition.semantic)
          && typeof decision.value === 'string');
        const prepared = prepareTextLayout(decision.value, widgets, field, textFont, definition.maxLength);
        if (typeof prepared === 'string') {
          renderIssues.push(Object.freeze({ fieldName: definition.fieldName, code: prepared, message: issueMessage(prepared) }));
        } else textLayout = prepared;
      }
      clearValues(field.acroField.dict);
      for (const [widgetIndex, widget] of widgets.entries()) {
        clearValues(widget.dict);
        let appearance: PDFRef;
        if (definition.pdfType === 'Btn') {
          const state = decision.status === 'mapped' ? decision.widgetValues[widgetIndex] : 'Off';
          check(typeof state === 'string');
          const normal = widget.getAppearances()?.normal;
          check(normal instanceof PDFDict);
          const selected = normal.get(PDFName.of(state));
          check(selected instanceof PDFRef && source.context.lookup(selected) instanceof PDFStream);
          appearance = selected;
          widget.setAppearanceState(PDFName.of(state));
        } else if (textLayout) {
          const rect = widget.getRectangle();
          const { fontSize, encoded } = textLayout;
          const textHeight = (HELVETICA_BOUNDS.top - HELVETICA_BOUNDS.bottom) * fontSize;
          const x = TEXT_INSET - HELVETICA_BOUNDS.left * fontSize;
          const y = (rect.height - textHeight) / 2 - HELVETICA_BOUNDS.bottom * fontSize;
          appearance = source.context.register(source.context.flateStream(
            `BT\n/SafeAtHomeReviewedText ${fontSize} Tf\n0 g\n1 0 0 1 ${x} ${y} Tm\n${encoded} Tj\nET\n`,
            { Type: 'XObject', Subtype: 'Form', BBox: [0, 0, rect.width, rect.height],
              Resources: { Font: { SafeAtHomeReviewedText: textFont.ref } } },
          ));
          widget.dict.delete(PDFName.of('AS'));
        } else {
          const rect = widget.getRectangle();
          appearance = source.context.register(source.context.flateStream('', {
            Type: 'XObject', Subtype: 'Form', BBox: [0, 0, rect.width, rect.height], Resources: {},
          }));
          widget.dict.delete(PDFName.of('AS'));
        }
        widget.setAppearances(source.context.obj({ N: appearance }));
      }
    }
    source.getForm().flatten({ updateFieldAppearances: false });
    check(source.getForm().getFields().length === 0);
    await source.flush();

    const output = await PDFDocument.create({ updateMetadata: false });
    const font = await output.embedFont(StandardFonts.HelveticaBold);
    for (const page of source.getPages()) {
      const { width, height } = page.getSize();
      const embedded = await output.embedPage(page);
      const preview = output.addPage([width, height + BANNER_HEIGHT]);
      preview.drawPage(embedded, { x: 0, y: 0, width, height });
      preview.drawRectangle({ x: 0, y: height, width, height: BANNER_HEIGHT, color: rgb(1, 0.94, 0.8) });
      const fontSize = Math.min(11, (width - 24) / font.widthOfTextAtSize(DRAFT_LABEL, 1));
      preview.drawText(DRAFT_LABEL, { x: (width - font.widthOfTextAtSize(DRAFT_LABEL, fontSize)) / 2,
        y: height + (renderIssues.length > 0 ? 18 : 11), size: fontSize, font, color: rgb(0.35, 0.12, 0) });
      if (renderIssues.length > 0) {
        const note = `${renderIssues.length} reviewed answer${renderIssues.length === 1 ? '' : 's'} omitted - review rendering issues`;
        const size = Math.min(8, (width - 24) / font.widthOfTextAtSize(note, 1));
        preview.drawText(note, { x: (width - font.widthOfTextAtSize(note, size)) / 2,
          y: height + 6, size, font, color: rgb(0.35, 0.12, 0) });
      }
    }
    output.setTitle('Incomplete draft - not submitted');
    output.setCreator('Safe at Home draft preview');
    return { bytes: await output.save({ updateFieldAppearances: false }), plan,
      renderIssues: Object.freeze(renderIssues) };
  } catch {
    throw new DraftPreviewError();
  }
}

interface InventoryEntry { field: PDFField; widgets: PDFWidgetAnnotation[] }

interface TextLayout { fontSize: number; encoded: string }

function prepareTextLayout(
  value: string, widgets: PDFWidgetAnnotation[], field: PDFField, font: PDFFont, maxLength: number | null,
): TextLayout | DraftRenderIssue['code'] {
  const unsupportedFlags = (1 << 13) | (1 << 20) | (1 << 24) | (1 << 25);
  if (/[\r\n\u2028\u2029]/.test(value) || (field.acroField.getFlags() & unsupportedFlags) !== 0
    || widgets.some(widget => (widget.getAppearanceCharacteristics()?.getRotation() ?? 0) !== 0)) {
    return 'UNSUPPORTED_TEXT_LAYOUT';
  }
  const characters = Array.from(value);
  const charset = new Set(font.getCharacterSet());
  if (characters.some(character => !charset.has(character.codePointAt(0)!))) return 'UNSUPPORTED_CHARACTERS';
  if (characters.length === 0 || (maxLength !== null && characters.length > maxLength)) return 'TEXT_DOES_NOT_FIT';
  const widths = characters.map(character => font.widthOfTextAtSize(character, 1));
  const advanceWidth = widths.reduce((sum, width) => sum + width, 0);
  const inkWidth = advanceWidth - widths[widths.length - 1]
    + HELVETICA_BOUNDS.right - HELVETICA_BOUNDS.left;
  const inkHeight = HELVETICA_BOUNDS.top - HELVETICA_BOUNDS.bottom;
  let fontSize = MAX_TEXT_SIZE;
  for (const widget of widgets) {
    const rect = widget.getRectangle();
    fontSize = Math.min(fontSize, (rect.width - 2 * TEXT_INSET) / inkWidth,
      (rect.height - 2 * TEXT_INSET) / inkHeight);
  }
  fontSize = Math.floor(fontSize * 100) / 100;
  if (!Number.isFinite(fontSize) || fontSize < MIN_TEXT_SIZE) return 'TEXT_DOES_NOT_FIT';
  return { fontSize, encoded: font.encodeText(value).toString() };
}

function issueMessage(code: DraftRenderIssue['code']): string {
  if (code === 'UNSUPPORTED_CHARACTERS') return 'This answer uses characters the preview font cannot display. Keep the original spelling and arrange a supported form entry method.';
  if (code === 'TEXT_DOES_NOT_FIT') return 'This answer does not fit at a readable size. Review the form entry method; the answer was not shortened.';
  return 'This answer requires an unsupported text layout. Review the form entry method; the answer was left blank.';
}

function verifyInventory(document: PDFDocument, template: VerifiedFormTemplate): InventoryEntry[] {
  const pages = document.getPages();
  check(pages.length === template.pageCount);
  for (const page of pages) {
    const media = page.getMediaBox();
    const crop = page.getCropBox();
    check(media.x === 0 && media.y === 0 && media.width >= 100 && media.width <= 2000
      && media.height >= 100 && media.height <= 2000 && page.getRotation().angle === 0
      && JSON.stringify(media) === JSON.stringify(crop));
    check(!page.node.has(PDFName.of('AA')));
  }
  const form = document.getForm();
  const fields = form.getFields();
  check(form.acroForm.getAllFields().length === fields.length && fields.length === template.fields.length);
  const byName = new Map(fields.map(field => [field.getName(), field]));
  check(byName.size === fields.length);
  const usedWidgets = new Set<PDFDict>();
  const entries = template.fields.map(definition => {
    const field = byName.get(definition.fieldName);
    check(field !== undefined && field.acroField.FT().decodeText() === definition.pdfType);
    check(field.isRequired() === definition.required);
    const maximum = field.acroField.dict.lookup(PDFName.of('MaxLen'));
    check(maximum === undefined ? definition.maxLength === null
      : maximum instanceof PDFNumber && maximum.asNumber() === definition.maxLength);
    rejectActions(field.acroField.dict);
    if (definition.pdfType === 'Btn') check(field instanceof PDFCheckBox);
    const actual = field.acroField.getWidgets();
    check(actual.length === definition.widgets.length);
    const remaining = new Set(actual);
    const widgets = definition.widgets.map(expected => {
      const matches = [...remaining].filter(widget => {
        const pageIndex = widgetPageIndex(widget, pages);
        const rect = widget.Rect()?.asArray().map(value => document.context.lookup(value, PDFNumber).asNumber());
        return pageIndex + 1 === expected.page && JSON.stringify(rect) === JSON.stringify(expected.rect);
      });
      check(matches.length === 1);
      const widget = matches[0];
      remaining.delete(widget);
      check(!usedWidgets.has(widget.dict));
      usedWidgets.add(widget.dict);
      rejectActions(widget.dict);
      check(widget.dict.lookup(PDFName.of('Subtype')) === PDFName.of('Widget'));
      if (definition.pdfType === 'Btn') {
        const normal = widget.getAppearances()?.normal;
        check(normal instanceof PDFDict);
        const keys = normal.keys().map(key => key.decodeText()).sort();
        check(JSON.stringify(keys) === JSON.stringify(['Off', expected.exportValue].sort()));
        for (const key of normal.keys()) {
          const ref = normal.get(key);
          check(ref instanceof PDFRef && document.context.lookup(ref) instanceof PDFStream);
        }
      } else {
        check(expected.exportValue === null);
      }
      return widget;
    });
    check(remaining.size === 0);
    return { field, widgets };
  });
  for (const page of pages) {
    for (const value of page.node.Annots()?.asArray() ?? []) {
      const annotation = document.context.lookup(value, PDFDict);
      if (annotation.lookup(PDFName.of('Subtype')) === PDFName.of('Widget')) check(usedWidgets.has(annotation));
    }
  }
  return entries;
}

function widgetPageIndex(widget: PDFWidgetAnnotation, pages: PDFPage[]): number {
  const locations = pages.map((page, index) => ({ page, index })).filter(({ page }) =>
    page.node.Annots()?.asArray().some(value => page.doc.context.lookup(value) === widget.dict));
  check(locations.length === 1);
  const { page, index } = locations[0];
  check(widget.P() === undefined || widget.P() === page.ref);
  return index;
}

function clearValues(dict: PDFDict): void {
  for (const key of ['V', 'DV', 'RV', 'DA', 'I']) dict.delete(PDFName.of(key));
}

function rejectActions(dict: PDFDict): void {
  check(!dict.has(PDFName.of('A')) && !dict.has(PDFName.of('AA')));
}

function rejectActiveDocumentFeatures(document: PDFDocument): void {
  check(!document.catalog.has(PDFName.of('OpenAction')) && !document.catalog.has(PDFName.of('AA')));
  const acroForm = document.catalog.lookup(PDFName.of('AcroForm'));
  check(acroForm instanceof PDFDict && !acroForm.has(PDFName.of('XFA')));
  const visited = new Set<object>();
  const inspect = (value: unknown, depth: number): void => {
    check(depth < 100);
    if (!(value instanceof PDFDict || value instanceof PDFArray || value instanceof PDFRawStream) || visited.has(value)) return;
    visited.add(value);
    if (value instanceof PDFRawStream) return inspect(value.dict, depth + 1);
    if (value instanceof PDFArray) {
      for (const entry of value.asArray()) inspect(entry, depth + 1);
      return;
    }
    for (const key of ['JS', 'JavaScript', 'EmbeddedFiles', 'XFA']) check(!value.has(PDFName.of(key)));
    const action = value.lookup(PDFName.of('S'));
    if (action instanceof PDFName) check(!['JavaScript', 'Launch', 'SubmitForm', 'ImportData', 'GoToR', 'Rendition'].includes(action.decodeText()));
    for (const entry of value.values()) inspect(entry, depth + 1);
  };
  for (const [, value] of document.context.enumerateIndirectObjects()) inspect(value, 0);
}

function check(condition: unknown): asserts condition {
  if (!condition) throw new DraftPreviewError();
}
