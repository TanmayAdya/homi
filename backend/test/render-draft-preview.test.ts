import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import {
  PDFArray, PDFDict, PDFDocument, PDFName, PDFNumber, PDFRawStream,
  PDFString, StandardFonts, decodePDFRawStream, type PDFWidgetAnnotation,
} from 'pdf-lib';
import { renderDraftPreview, DraftPreviewError } from '../src/forms/render-draft-preview.ts';
import { defineVerifiedFormTemplate, type FormPlanningContext, type VerifiedFormTemplate } from '../src/forms/field-mapping.ts';
import { createFormAnswerContext, createSavedFormAnswers, type FormAnswerInput, type SavedFormAnswerSet } from '../src/forms/form-answers.ts';
import type { CaseSnapshot } from '../src/types.ts';

const CASE: CaseSnapshot = { schemaVersion: '1', caseId: 'private-fictional-case-id', revision: 4,
  profile: { city: 'Private fictional city', county: null, healthPlan: 'Private fictional plan', tenure: 'owner',
    ageYears: 70, householdSize: 1, annualIncomeUsd: 0, ownerConsentReported: true },
  unresolvedFields: [], findings: [] };
const PROGRAM = 'synthetic-home-route';
const LABEL = 'INCOMPLETE DRAFT - NOT SUBMITTED';
interface Fixture { bytes: Uint8Array; template: VerifiedFormTemplate; context: FormPlanningContext }

async function fixture(): Promise<Fixture> {
  const document = await PDFDocument.create({ updateMetadata: false });
  const first = document.addPage([612, 792]);
  const second = document.addPage([612, 792]);
  first.drawText('SYNTHETIC ORIGINAL FIRST PAGE', { x: 30, y: 750, size: 12 });
  second.drawText('SYNTHETIC ORIGINAL SECOND PAGE', { x: 30, y: 750, size: 12 });
  document.setTitle('PRIVATE SOURCE METADATA');
  document.setAuthor('PRIVATE SOURCE AUTHOR');
  const form = document.getForm();
  const route = form.createCheckBox('route');
  route.addToPage(first, { x: 30, y: 640, width: 18, height: 18 });
  route.addToPage(first, { x: 30, y: 680, width: 18, height: 18 });
  const [home, other] = route.acroField.getWidgets();
  buttonAppearance(document, home, 'Home', 'HOME');
  buttonAppearance(document, other, 'Other', 'OTHER');
  for (const [name, y] of [['name', 600], ['clinical', 560], ['layout', 520]] as const) {
    const field = form.createTextField(name);
    field.addToPage(first, { x: 40, y, width: 180, height: 20 });
    field.setText(`PRIVATE ${name.toUpperCase()} ANSWER`);
    field.acroField.dict.set(PDFName.of('DV'), PDFString.of('PRIVATE DEFAULT ANSWER'));
    field.acroField.dict.set(PDFName.of('RV'), PDFString.of('PRIVATE RICH ANSWER'));
    field.defaultUpdateAppearances(document.embedStandardFont(StandardFonts.Helvetica));
  }
  const consent = form.createCheckBox('consent');
  consent.addToPage(second, { x: 30, y: 680, width: 18, height: 18 });
  buttonAppearance(document, consent.acroField.getWidgets()[0], 'Yes', 'CONSENT');
  consent.acroField.dict.set(PDFName.of('V'), PDFName.of('Yes'));
  consent.acroField.getWidgets()[0].setAppearanceState(PDFName.of('Yes'));
  const signature = form.createTextField('signature');
  signature.addToPage(second, { x: 40, y: 620, width: 180, height: 20 });
  signature.setText('PRIVATE SIGNED APPEARANCE');
  signature.defaultUpdateAppearances(document.embedStandardFont(StandardFonts.Helvetica));
  signature.acroField.dict.set(PDFName.of('FT'), PDFName.of('Sig'));
  signature.acroField.dict.set(PDFName.of('V'), document.context.obj({ Type: 'Sig', Name: PDFString.of('PRIVATE SIGNER') }));
  const bytes = await document.save({ updateFieldAppearances: false });
  const loaded = await PDFDocument.load(bytes, { updateMetadata: false });
  const hash = digest(bytes);
  const fields = loaded.getForm().getFields().map(field => {
    const name = field.getName();
    const type = field.acroField.FT().decodeText();
    const widgets = field.acroField.getWidgets().map(widget => ({
      page: loaded.getPages().findIndex(page => widget.P() === page.ref) + 1,
      rect: widget.Rect()!.asArray().map(value => loaded.context.lookup(value, PDFNumber).asNumber()),
      exportValue: type === 'Btn' ? widget.getOnValue()!.decodeText() : null,
    }));
    if (name === 'route') widgets.reverse();
    const semantic = name === 'route' ? 'routing' : name === 'clinical' ? 'clinical'
      : name === 'consent' ? 'consent' : name === 'signature' ? 'signature' : name === 'layout' ? 'layout' : 'identity';
    const reason = name === 'clinical' ? 'clinical_review' : name === 'consent' ? 'consent_review'
      : name === 'signature' ? 'signature_review' : name === 'layout' ? 'layout_only' : 'not_collected';
    return { fieldName: name, label: `Synthetic ${name}`, pdfType: type, semantic,
      required: false, maxLength: null, widgets,
      binding: name === 'route' ? { kind: 'routing', programId: PROGRAM, widgetIndex: 1, value: 'Home' }
        : { kind: 'manual', reason, resolvedBy: name === 'clinical' ? 'professional' : 'resident' } };
  });
  const template = defineVerifiedFormTemplate({ schemaVersion: '1', programId: PROGRAM,
    templateSha256: hash, formVersion: `sha256:${hash}`, mappingVersion: 'synthetic-v1', publisherRevision: null,
    sourceUrl: 'https://example.org/synthetic.pdf', sourcePageUrl: 'https://example.org/forms',
    reviewedOn: '2026-10-17', pageCount: 2, fields });
  return { bytes, template, context: { programId: PROGRAM, templateSha256: hash, plannedAt: '2026-10-17T20:00:00Z' } };
}

function buttonAppearance(document: PDFDocument, widget: PDFWidgetAnnotation, name: string, marker: string): void {
  const { width, height } = widget.getRectangle();
  const stream = (label: string) => document.context.register(document.context.flateStream(`% ${label}\n`, {
    Type: 'XObject', Subtype: 'Form', BBox: [0, 0, width, height], Resources: {},
  }));
  widget.setAppearances(document.context.obj({ N: { Off: stream(`OFF_${marker}`), [name]: stream(`ON_${marker}`) } }));
  widget.setAppearanceState(PDFName.of('Off'));
}

function digest(bytes: Uint8Array): string { return createHash('sha256').update(bytes).digest('hex'); }

async function revise(f: Fixture, mutate: (document: PDFDocument) => void): Promise<Fixture> {
  const document = await PDFDocument.load(f.bytes, { updateMetadata: false });
  mutate(document);
  const bytes = await document.save({ updateFieldAppearances: false });
  const hash = digest(bytes);
  return { bytes, template: { ...f.template, templateSha256: hash, formVersion: `sha256:${hash}` },
    context: { ...f.context, templateSha256: hash } };
}

async function render(f: Fixture) { return renderDraftPreview(CASE, f.template, f.bytes, f.context); }

async function reviewedFixture(): Promise<Fixture> {
  const f = await revise(await fixture(), document => {
    document.getForm().getField('name').acroField.setPartialName('First Name');
  });
  const template = defineVerifiedFormTemplate({ ...f.template, fields: f.template.fields.map(field =>
    field.fieldName === 'name' ? { ...field, fieldName: 'First Name', label: 'Member given name',
      binding: { kind: 'reviewed_answer', answerKey: 'memberFirstName' } } : field) });
  return { ...f, template };
}

function reviewedAnswers(f: Fixture, value: string, reviewState: FormAnswerInput['reviewState'] = 'reviewed'): SavedFormAnswerSet {
  return createSavedFormAnswers({ snapshot: CASE, context: createFormAnswerContext(f.template), answerRevision: 2,
    updatedAt: f.context.plannedAt, updatedBy: 'fictional-reviewer',
    answers: [{ key: 'memberFirstName', value, reviewState }] });
}

async function reviewedPreview(f: Fixture, value: string) {
  return renderDraftPreview(CASE, f.template, f.bytes, f.context, reviewedAnswers(f, value));
}

async function syncReviewedWidgets(f: Fixture): Promise<Fixture> {
  const document = await PDFDocument.load(f.bytes, { updateMetadata: false });
  const widgets = document.getForm().getField('First Name').acroField.getWidgets().map(widget => ({
    page: document.getPages().findIndex(page => widget.P() === page.ref) + 1,
    rect: widget.Rect()!.asArray().map(value => document.context.lookup(value, PDFNumber).asNumber()),
    exportValue: null,
  }));
  return { ...f, template: defineVerifiedFormTemplate({ ...f.template, fields: f.template.fields.map(field =>
    field.fieldName === 'First Name' ? { ...field, widgets } : field) }) };
}

function streamText(document: PDFDocument): string {
  return document.context.enumerateIndirectObjects().map(([, object]) => object instanceof PDFRawStream
    ? Buffer.from(decodePDFRawStream(object).decode()).toString('latin1') : '').join('\n');
}

function pageText(document: PDFDocument, index: number): string {
  const contents = document.getPage(index).node.Contents();
  const streams = contents instanceof PDFArray ? contents.asArray() : [contents];
  return streams.map(value => {
    const stream = document.context.lookup(value);
    assert.ok(stream instanceof PDFRawStream);
    return Buffer.from(decodePDFRawStream(stream).decode()).toString('latin1');
  }).join('\n');
}

test('preview selects only the reviewed physical routing widget, independent of Kids order', async () => {
  const f = await fixture();
  const result = await render(f);
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  const streams = streamText(document);
  assert.match(streams, /ON_HOME/);
  assert.match(streams, /OFF_OTHER/);
  assert.doesNotMatch(streams, /ON_OTHER|ON_CONSENT/);
  assert.match(streams, /OFF_CONSENT/);
  assert.deepEqual(result.plan.fields.find(field => field.fieldName === 'route')!.widgetValues, ['Off', 'Home']);
  assert.equal(result.plan.caseId, CASE.caseId);
  assert.equal(result.plan.caseRevision, CASE.revision);
  assert.equal(result.plan.templateSha256, digest(f.bytes));
  assert.deepEqual(result.renderIssues, []);
});

test('manual values, defaults, rich text, clinical answers and signature appearances stay blank', async () => {
  const result = await render(await fixture());
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  const text = streamText(document);
  for (const value of ['PRIVATE', CASE.caseId, CASE.profile.city!, CASE.profile.healthPlan!]) {
    assert.ok(!text.includes(value));
    assert.ok(!text.includes(Buffer.from(value).toString('hex').toUpperCase()));
  }
  for (const decision of result.plan.fields.filter(field => field.semantic !== 'routing')) {
    assert.equal(decision.value, null);
    assert.ok(decision.widgetValues.every(value => value === null));
  }
  assert.equal(document.getTitle(), 'Incomplete draft - not submitted');
  assert.equal(document.getAuthor(), undefined);
  assert.equal(document.catalog.has(PDFName.of('Metadata')), false);
  assert.equal(document.catalog.has(PDFName.of('AcroForm')), false);
  assert.ok(document.getPages().every(page => !page.node.Annots() || page.node.Annots()!.size() === 0));
});

test('manual fields without existing appearances render blank, including signature fields', async () => {
  const f = await revise(await fixture(), document => {
    for (const name of ['name', 'clinical', 'signature']) {
      for (const widget of document.getForm().getField(name).acroField.getWidgets()) {
        widget.dict.delete(PDFName.of('AP'));
      }
    }
  });
  const result = await render(f);
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.equal(document.getPageCount(), 2);
  assert.doesNotMatch(streamText(document), /PRIVATE/);
  assert.ok(result.plan.fields.filter(field => field.fieldName !== 'route').every(field => field.value === null));
});

test('every page preserves full source geometry and gets its own visible draft band', async () => {
  const result = await render(await fixture());
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.equal(document.getPageCount(), 2);
  const labelHex = Buffer.from(LABEL).toString('hex').toUpperCase();
  for (let index = 0; index < 2; index++) {
    assert.deepEqual(document.getPage(index).getSize(), { width: 612, height: 824 });
    assert.ok(pageText(document, index).includes(labelHex));
    const xobjects = document.getPage(index).node.Resources()!.lookup(PDFName.of('XObject'), PDFDict);
    const embedded = document.context.lookup(xobjects.values()[0]);
    assert.ok(embedded instanceof PDFRawStream);
    assert.equal(embedded.dict.lookup(PDFName.of('BBox'), PDFArray).toString(), '[ 0 0 612 792 ]');
    assert.equal(embedded.dict.lookup(PDFName.of('Matrix'), PDFArray).toString(), '[ 1 0 0 1 0 0 ]');
  }
  const streams = streamText(document);
  for (const label of ['SYNTHETIC ORIGINAL FIRST PAGE', 'SYNTHETIC ORIGINAL SECOND PAGE']) {
    assert.ok(streams.includes(Buffer.from(label).toString('hex').toUpperCase()));
  }
});

test('hash mismatch, malformed PDF and mismatched plan context fail with a sanitized error', async () => {
  const f = await fixture();
  const assertSafe = async (operation: Promise<unknown>) => assert.rejects(operation, error => {
    assert.ok(error instanceof DraftPreviewError);
    assert.equal(error.message, 'The form preview could not be prepared from the verified template.');
    return true;
  });
  const changed = Uint8Array.from(f.bytes); changed[changed.length - 1] ^= 1;
  await assertSafe(renderDraftPreview(CASE, f.template, changed, f.context));
  await assertSafe(renderDraftPreview(CASE, f.template, f.bytes, { ...f.context, programId: 'another' }));
  await assertSafe(renderDraftPreview(CASE, f.template, f.bytes, { ...f.context, templateSha256: 'a'.repeat(64) }));
  await assertSafe(renderDraftPreview(CASE, f.template, f.bytes, { ...f.context, plannedAt: 'invalid' }));
  await assertSafe(renderDraftPreview(CASE, f.template, new Uint8Array(5 * 1024 * 1024 + 1), f.context));
  await assertSafe(renderDraftPreview(CASE, f.template, new Uint8Array(7), f.context));
  const bytes = Buffer.from('%PDF-1.7\nINVALID PRIVATE TEMPLATE');
  const hash = digest(bytes);
  await assertSafe(renderDraftPreview(CASE, { ...f.template, templateSha256: hash, formVersion: `sha256:${hash}` },
    bytes, { ...f.context, templateSha256: hash }));
});

test('caller inputs are detached before asynchronous PDF work and remain unchanged', async () => {
  const f = await fixture();
  const template = structuredClone(f.template);
  const snapshot = structuredClone(CASE);
  const originalHash = digest(f.bytes);
  const operation = renderDraftPreview(snapshot, template, f.bytes, f.context);
  snapshot.caseId = 'changed-after-call';
  f.bytes.fill(0);
  (template.fields[0].binding as { value: string }).value = 'Other';
  (f.context as { plannedAt: string }).plannedAt = 'invalid';
  const result = await operation;
  assert.equal(result.plan.caseId, CASE.caseId);
  assert.equal(result.plan.templateSha256, originalHash);
  assert.equal(result.plan.fields[0].value, 'Home');
});

test('unexpected or missing fields and changed types, flags or text limits are rejected', async () => {
  const f = await fixture();
  const cases: ((document: PDFDocument) => void)[] = [
    document => document.getForm().createTextField('unexpected').addToPage(document.getPage(0), { x: 30, y: 300 }),
    document => document.getForm().getField('name').acroField.setPartialName('renamed'),
    document => document.getForm().getField('name').acroField.dict.set(PDFName.of('FT'), PDFName.of('Ch')),
    document => document.getForm().getField('name').enableRequired(),
    document => document.getForm().getTextField('name').setMaxLength(100),
  ];
  for (const mutate of cases) await assert.rejects(render(await revise(f, mutate)), DraftPreviewError);
  const definition = structuredClone(f.template);
  (definition.fields as unknown[]).pop();
  await assert.rejects(renderDraftPreview(CASE, definition, f.bytes, f.context), DraftPreviewError);
});

test('changed widget rectangles, pages, export names and extra widgets are rejected', async () => {
  const f = await fixture();
  const cases: ((document: PDFDocument) => void)[] = [
    document => document.getForm().getField('route').acroField.getWidgets()[0].setRectangle({ x: 0, y: 0, width: 18, height: 18 }),
    document => document.getForm().getField('route').acroField.getWidgets()[0].setP(document.getPage(1).ref),
    document => buttonAppearance(document, document.getForm().getField('route').acroField.getWidgets()[0], 'Changed', 'CHANGED'),
    document => document.getForm().getCheckBox('route').addToPage(document.getPage(1), { x: 100, y: 100 }),
    document => {
      const widget = document.context.obj({ Type: 'Annot', Subtype: 'Widget', Rect: [0, 0, 10, 10] });
      document.getPage(0).node.addAnnot(document.context.register(widget));
    },
  ];
  for (const mutate of cases) await assert.rejects(render(await revise(f, mutate)), DraftPreviewError);
});

test('page count, crop and rotation changes fail closed rather than clipping or transforming the form', async () => {
  const f = await fixture();
  const cases: ((document: PDFDocument) => void)[] = [
    document => { document.addPage(); },
    document => document.getPage(0).setCropBox(0, 0, 500, 700),
    document => document.getPage(0).node.set(PDFName.of('Rotate'), PDFNumber.of(90)),
    document => document.getPage(0).setMediaBox(10, 10, 612, 792),
  ];
  for (const mutate of cases) await assert.rejects(render(await revise(f, mutate)), DraftPreviewError);
});

test('XFA, encrypted templates and active actions are rejected before output', async () => {
  const f = await fixture();
  const cases: ((document: PDFDocument) => void)[] = [
    document => document.catalog.lookup(PDFName.of('AcroForm'), PDFDict).set(PDFName.of('XFA'), PDFString.of('PRIVATE XFA')),
    document => document.catalog.set(PDFName.of('OpenAction'), document.context.obj({ S: 'JavaScript', JS: PDFString.of('private()') })),
    document => document.getForm().getField('name').acroField.dict.set(PDFName.of('AA'), document.context.obj({})),
    document => document.getForm().getField('route').acroField.getWidgets()[0].dict.set(PDFName.of('A'), document.context.obj({ S: 'URI', URI: PDFString.of('https://example.org') })),
    document => document.catalog.set(PDFName.of('Names'), document.context.obj({ JavaScript: {} })),
    document => { document.context.trailerInfo.Encrypt = document.context.register(document.context.obj({ Filter: 'Standard' })); },
  ];
  for (const mutate of cases) await assert.rejects(render(await revise(f, mutate)), DraftPreviewError);
});

test('ordinary source links are excluded from the noninteractive output', async () => {
  const f = await revise(await fixture(), document => {
    document.getPage(0).node.addAnnot(document.context.register(document.context.obj({ Type: 'Annot', Subtype: 'Link',
      Rect: [10, 10, 30, 20], A: { S: 'URI', URI: PDFString.of('https://example.org/private-link') } })));
  });
  const result = await render(f);
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.ok(document.getPages().every(page => !page.node.Annots() || page.node.Annots()!.size() === 0));
  assert.ok(!Buffer.from(result.bytes).toString('latin1').includes('private-link'));
});

test('reviewed text renders exactly, including supported accents, with source provenance intact', async () => {
  const f = await reviewedFixture();
  const value = 'Ángela Núñez';
  const result = await reviewedPreview(f, value);
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  const expectedFont = document.embedStandardFont(StandardFonts.Helvetica);
  const streams = streamText(document);
  assert.ok(streams.includes(`${expectedFont.encodeText(value)} Tj`));
  assert.match(streams, /\/SafeAtHomeReviewedText 10 Tf/);
  assert.deepEqual(result.renderIssues, []);
  const decision = result.plan.fields.find(field => field.fieldName === 'First Name')!;
  assert.equal(decision.value, value);
  assert.equal(decision.origin?.kind, 'reviewed_form_answer');
  assert.equal(document.getAuthor(), undefined);
  assert.equal(document.getTitle(), 'Incomplete draft - not submitted');
  assert.equal(document.catalog.has(PDFName.of('AcroForm')), false);
  assert.doesNotMatch(streams, /PRIVATE NAME ANSWER|PRIVATE CLINICAL ANSWER|PRIVATE SIGNED APPEARANCE/);
});

test('fit reduces text size deterministically while preserving the full answer and an 8pt floor', async () => {
  const f = await reviewedFixture();
  const value = 'A'.repeat(30);
  const result = await reviewedPreview(f, value);
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  const streams = streamText(document);
  const sizes = [...streams.matchAll(/\/SafeAtHomeReviewedText ([0-9.]+) Tf/g)].map(match => Number(match[1]));
  assert.equal(sizes.length, 1);
  assert.ok(sizes[0] >= 8 && sizes[0] < 10);
  const font = document.embedStandardFont(StandardFonts.Helvetica);
  assert.ok(streams.includes(`${font.encodeText(value)} Tj`));
  assert.deepEqual(result.renderIssues, []);
  const repeated = await reviewedPreview(f, value);
  const other = await PDFDocument.load(repeated.bytes, { updateMetadata: false });
  assert.match(streamText(other), new RegExp(`/SafeAtHomeReviewedText ${sizes[0]} Tf`));
});

test('overflow leaves the entire answer blank and reports a safe issue on every page', async () => {
  const f = await reviewedFixture();
  const value = 'W'.repeat(100);
  const result = await reviewedPreview(f, value);
  assert.equal(result.plan.fields.find(field => field.fieldName === 'First Name')!.value, value);
  assert.deepEqual(result.renderIssues.map(({ fieldName, code }) => ({ fieldName, code })), [
    { fieldName: 'First Name', code: 'TEXT_DOES_NOT_FIT' },
  ]);
  assert.ok(!JSON.stringify(result.renderIssues).includes(value));
  assert.ok(Object.isFrozen(result.renderIssues) && Object.isFrozen(result.renderIssues[0]));
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.doesNotMatch(streamText(document), /\/SafeAtHomeReviewedText/);
  assert.match(streamText(document), /ON_HOME/);
  const note = Buffer.from('1 reviewed answer omitted - review rendering issues').toString('hex').toUpperCase();
  for (let index = 0; index < document.getPageCount(); index++) assert.ok(pageText(document, index).includes(note));
});

test('unsupported scripts and combining marks stay exact in the logical plan, never transliterated into the PDF', async () => {
  const f = await reviewedFixture();
  for (const value of ['李', 'Zoë😀', 'e\u0301']) {
    const result = await reviewedPreview(f, value);
    assert.equal(result.plan.fields.find(field => field.fieldName === 'First Name')!.value, value);
    assert.equal(result.renderIssues.length, 1);
    assert.equal(result.renderIssues[0].code, 'UNSUPPORTED_CHARACTERS');
    assert.ok(!JSON.stringify(result.renderIssues).includes(value));
    const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
    assert.doesNotMatch(streamText(document), /\/SafeAtHomeReviewedText/);
  }
});

test('unreviewed answers stay blank without a misleading rendering omission', async () => {
  const f = await reviewedFixture();
  const result = await renderDraftPreview(CASE, f.template, f.bytes, f.context,
    reviewedAnswers(f, 'Fictional unreviewed answer', 'needs_review'));
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.notEqual(result.plan.fields.find(field => field.fieldName === 'First Name')!.status, 'mapped');
  assert.deepEqual(result.renderIssues, []);
  assert.doesNotMatch(streamText(document), /\/SafeAtHomeReviewedText/);
});

test('reviewed answer input is detached before asynchronous PDF work', async () => {
  const f = await reviewedFixture();
  const answers = reviewedAnswers(f, 'Original Fictional');
  const operation = renderDraftPreview(CASE, f.template, f.bytes, f.context, answers);
  answers.answers[0].value = 'Changed After Call';
  answers.caseRevision += 1;
  const result = await operation;
  assert.equal(result.plan.fields.find(field => field.fieldName === 'First Name')!.value, 'Original Fictional');
  assert.deepEqual(result.renderIssues, []);
});

test('stale case, form and answer context cannot reach a rendered preview', async () => {
  const f = await reviewedFixture();
  const mutations: ((answers: SavedFormAnswerSet) => void)[] = [
    answers => { answers.caseId = 'another-case'; },
    answers => { answers.caseRevision += 1; },
    answers => { answers.programId = 'another-program'; },
    answers => { answers.formVersion = 'another-form'; },
    answers => { answers.mappingVersion = 'another-mapping'; },
    answers => { answers.formContextId = '0'.repeat(64); },
    answers => { answers.updatedAt = '2026-10-18T20:00:00Z'; },
  ];
  for (const mutate of mutations) {
    const answers = reviewedAnswers(f, 'Private Fictional Answer');
    mutate(answers);
    await assert.rejects(renderDraftPreview(CASE, f.template, f.bytes, f.context, answers), error => {
      assert.ok(error instanceof DraftPreviewError);
      assert.equal(error.message, 'The form preview could not be prepared from the verified template.');
      return true;
    });
  }
});

test('single-line answers fit multiline-capable boxes without changing source text or wrapping', async () => {
  const f = await revise(await reviewedFixture(), document => document.getForm().getTextField('First Name').enableMultiline());
  const result = await reviewedPreview(f, 'Fictional Name');
  assert.deepEqual(result.renderIssues, []);
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  const matching = streamText(document).match(/\/SafeAtHomeReviewedText/g) ?? [];
  assert.equal(matching.length, 1);
});

test('unsupported text widget semantics and rotation are review issues, not partial output', async () => {
  const base = await reviewedFixture();
  const mutations: ((document: PDFDocument) => void)[] = [
    document => document.getForm().getTextField('First Name').enablePassword(),
    document => document.getForm().getField('First Name').acroField.setFlag(1 << 20),
    document => document.getForm().getField('First Name').acroField.setFlag(1 << 24),
    document => document.getForm().getField('First Name').acroField.setFlag(1 << 25),
    document => document.getForm().getField('First Name').acroField.getWidgets()[0]
      .getOrCreateAppearanceCharacteristics().setRotation(90),
  ];
  for (const mutate of mutations) {
    const f = await revise(base, mutate);
    const result = await reviewedPreview(f, 'Fictional');
    assert.equal(result.renderIssues[0].code, 'UNSUPPORTED_TEXT_LAYOUT');
    const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
    assert.doesNotMatch(streamText(document), /\/SafeAtHomeReviewedText/);
  }
});

test('every widget must fit before any copy of a reviewed field is rendered', async () => {
  const f = await syncReviewedWidgets(await revise(await reviewedFixture(), document => {
    document.getForm().getTextField('First Name').addToPage(document.getPage(1), { x: 200, y: 400, width: 20, height: 20 });
  }));
  const result = await reviewedPreview(f, 'Fictional Name');
  assert.equal(result.renderIssues.length, 1);
  assert.equal(result.renderIssues[0].code, 'TEXT_DOES_NOT_FIT');
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.doesNotMatch(streamText(document), /\/SafeAtHomeReviewedText/);
});

test('vertical bounds include accented ink and reject a box below the readable minimum', async () => {
  const f = await syncReviewedWidgets(await revise(await reviewedFixture(), document => {
    document.getForm().getField('First Name').acroField.getWidgets()[0]
      .setRectangle({ x: 40, y: 600, width: 180, height: 10 });
  }));
  const result = await reviewedPreview(f, 'Ág');
  assert.equal(result.renderIssues.length, 1);
  assert.equal(result.renderIssues[0].code, 'TEXT_DOES_NOT_FIT');
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.doesNotMatch(streamText(document), /\/SafeAtHomeReviewedText/);
});
