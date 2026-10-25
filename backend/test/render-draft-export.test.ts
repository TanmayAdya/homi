import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test, { mock } from 'node:test';
import { PDFArray, PDFDict, PDFDocument, PDFName, PDFNumber, PDFRawStream, decodePDFRawStream } from 'pdf-lib';
import sharp from 'sharp';
import { createDemoFormArtifact } from '../fixtures/demo-form-template.ts';
import { createFormAnswerContext, createSavedFormAnswers } from '../src/forms/form-answers.ts';
import { sanitizeEvidenceImage } from '../src/evidence/image-sanitizer.ts';
import type { EvidenceAsset } from '../src/evidence/types.ts';
import { DraftExportRenderError, MAX_DRAFT_EXPORT_BYTES, renderDraftExport } from '../src/exports/render-draft-export.ts';
import type { CaseSnapshot } from '../src/types.ts';
import { paintedText } from '../tool/pdf-verification-text.ts';
import { emptyAnnotations } from '../src/assessment/annotations.ts';
import { intakeDefinition, type ProgramIntakeAppendix } from '../src/programs/intake.ts';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';

const NOW = '2026-10-17T22:00:00Z';
const PROGRAM = 'fictional-export-program';
const LABEL = 'INCOMPLETE DRAFT - NOT SUBMITTED';
const makeCase = (): CaseSnapshot => ({ schemaVersion: '1', caseId: 'PRIVATE-CASE-ID', revision: 2,
  profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
    householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [],
  findings: [{ id: 'PRIVATE-FINDING-ID', room: 'entrance', observation: 'Fictional step at the entrance.',
    reviewState: 'confirmed', evidenceIds: ['PRIVATE-IMAGE-ONE', 'PRIVATE-IMAGE-TWO'], measurements: [
      { type: 'Step height', value: 120, unit: 'mm', method: 'manual', confirmed: true },
      { type: 'Door opening', value: 800, unit: 'mm', method: 'estimated', confirmed: false },
    ] }] });

async function fixture() {
  const snapshot = makeCase();
  const form = await createDemoFormArtifact(PROGRAM);
  const context = { programId: PROGRAM, templateSha256: form.template.templateSha256, plannedAt: NOW };
  const answers = createSavedFormAnswers({ snapshot, context: createFormAnswerContext(form.template), answerRevision: 1,
    updatedAt: NOW, updatedBy: 'PRIVATE-REVIEWER', answers: [{ key: 'memberFirstName', value: 'Fictional', reviewState: 'reviewed' }] });
  const assets: EvidenceAsset[] = [];
  for (const [index, color] of ['red', 'blue'].entries()) {
    const image = await sanitizeEvidenceImage(await sharp({ create: { width: 120 + index * 30, height: 80,
      channels: 3, background: color } }).png().toBuffer());
    const { bytes, ...descriptor } = image;
    assets.push({ descriptor: { ...descriptor, evidenceId: snapshot.findings[0].evidenceIds[index], evidenceRevision: index + 1,
      caseId: snapshot.caseId, findingId: snapshot.findings[0].id, capturedAt: index === 0 ? null : '2026-10-17T20:00:00Z',
      preparedAt: NOW }, bytes });
  }
  return { snapshot, form, context, answers, assets };
}
type Fixture = Awaited<ReturnType<typeof fixture>>;
const render = (f: Fixture, assets = f.assets) => renderDraftExport(f.snapshot, f.form.template, f.form.bytes, f.context, f.answers, assets);
function streams(document: PDFDocument): string {
  return document.context.enumerateIndirectObjects().map(([, value]) => value instanceof PDFRawStream
    && value.dict.get(PDFName.of('Subtype')) !== PDFName.of('Image')
    ? Buffer.from(decodePDFRawStream(value).decode()).toString('latin1') : '').join('\n');
}
function pageStream(document: PDFDocument, index: number): string {
  const contents = document.getPage(index).node.Contents();
  return (contents instanceof PDFArray ? contents.asArray() : [contents]).map(value => {
    const stream = document.context.lookup(value); assert.ok(stream instanceof PDFRawStream);
    return Buffer.from(decodePDFRawStream(stream).decode()).toString('latin1');
  }).join('\n');
}
const hex = (text: string) => Buffer.from(text, 'latin1').toString('hex').toUpperCase();
function errorCode(code?: DraftExportRenderError['code']) {
  return (error: unknown): boolean => {
    assert.ok(error instanceof DraftExportRenderError);
    if (code) assert.equal(error.code, code);
    assert.ok(!error.message.includes('PRIVATE')); return true;
  };
}

test('draft form stays first, selected images preserve order with reviewed values and uncertainty on separate pages', async () => {
  const f = await fixture(); const result = await render(f);
  assert.equal(result.pageCount, 3); assert.equal(result.renderingVersion, 'draft-export-v1');
  assert.equal(result.byteLength, result.bytes.byteLength); assert.ok(result.byteLength <= MAX_DRAFT_EXPORT_BYTES);
  assert.equal(result.sha256, createHash('sha256').update(result.bytes).digest('hex'));
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.deepEqual(document.getPage(0).getSize(), { width: 300, height: 332 });
  for (let index = 0; index < document.getPageCount(); index++) assert.ok(pageStream(document, index).includes(hex(LABEL)));
  assert.ok(streams(document).includes(hex('Fictional')));
  const first = pageStream(document, 1); const second = pageStream(document, 2);
  assert.ok(first.includes(hex('Reviewed evidence 1 of 2'))); assert.ok(second.includes(hex('Reviewed evidence 2 of 2')));
  for (const text of ['Observation: Fictional step at the entrance.', 'Captured: Unknown; no capture time supplied.',
    'Step height: 120 mm; method: manual; review: confirmed.', 'Door opening: 800 mm; method: estimated; review: not confirmed.',
    'Image shown to fit this page; do not measure physical dimensions from this print.']) assert.ok(first.includes(hex(text)), text);
  assert.ok(first.includes(hex('120 x 80 pixels.')) || first.includes(hex('Image: 120 x 80 pixels.')));
  assert.ok(second.includes(hex('Captured: 2026-10-17T20:00:00Z.')));
  const imageSizes = document.context.enumerateIndirectObjects().flatMap(([, value]) => value instanceof PDFRawStream
    && value.dict.get(PDFName.of('Subtype')) === PDFName.of('Image')
    ? [value.dict.get(PDFName.of('Width'))!.toString()] : []);
  assert.ok(imageSizes.includes('120')); assert.ok(imageSizes.includes('150'));
});

test('PDF contains no interactive widgets, embedded attachments, private identifiers or source metadata', async () => {
  const f = await fixture(); const result = await render(f);
  const document = await PDFDocument.load(result.bytes, { updateMetadata: false });
  assert.equal(document.catalog.has(PDFName.of('AcroForm')), false);
  assert.equal(document.catalog.has(PDFName.of('Names')), false);
  assert.equal(document.catalog.has(PDFName.of('Metadata')), false);
  assert.equal(document.getAuthor(), undefined);
  assert.ok(document.getPages().every(page => !page.node.Annots() || page.node.Annots()!.size() === 0));
  const content = streams(document);
  for (const text of [f.snapshot.caseId, f.snapshot.findings[0].id, 'PRIVATE-REVIEWER', ...f.snapshot.findings[0].evidenceIds]) {
    assert.ok(!content.includes(text)); assert.ok(!content.includes(hex(text)));
  }
});

test('sanitized RGBA pixels and transparency survive PDF image and alpha-mask embedding exactly', async () => {
  const pixels = Buffer.from([255, 0, 0, 255, 0, 255, 0, 64, 0, 0, 255, 128,
    255, 255, 255, 0, 21, 87, 146, 1, 0, 0, 0, 255]);
  const source = await sharp(pixels, { raw: { width: 3, height: 2, channels: 4 } }).png().toBuffer();
  const image = await sanitizeEvidenceImage(source);
  const decoded = await sharp(image.bytes).ensureAlpha().raw().toBuffer();
  assert.equal(createHash('sha256').update(decoded).digest('hex'), createHash('sha256').update(pixels).digest('hex'));
  const f = await fixture();
  const { bytes, ...descriptor } = image;
  f.assets = [{ descriptor: { ...f.assets[0].descriptor, ...descriptor }, bytes }];
  const rendered = await render(f);
  const document = await PDFDocument.load(rendered.bytes, { updateMetadata: false });
  assert.equal(document.getPageCount(), 2);
  const rgbImages = document.context.enumerateIndirectObjects().flatMap(([, value]) => value instanceof PDFRawStream
    && value.dict.get(PDFName.of('Subtype')) === PDFName.of('Image')
    && value.dict.get(PDFName.of('ColorSpace')) === PDFName.of('DeviceRGB') ? [value] : []);
  assert.equal(rgbImages.length, 1);
  const rgb = Buffer.from(decodePDFRawStream(rgbImages[0]).decode());
  const alphaStream = document.context.lookup(rgbImages[0].dict.get(PDFName.of('SMask')));
  assert.ok(alphaStream instanceof PDFRawStream);
  const alpha = Buffer.from(decodePDFRawStream(alphaStream).decode());
  assert.equal(rgb.length, 18); assert.equal(alpha.length, 6);
  const reconstructed = Buffer.alloc(pixels.length);
  for (let index = 0; index < alpha.length; index++) {
    rgb.copy(reconstructed, index * 4, index * 3, index * 3 + 3);
    reconstructed[index * 4 + 3] = alpha[index];
  }
  assert.equal(createHash('sha256').update(reconstructed).digest('hex'), createHash('sha256').update(pixels).digest('hex'));
});

test('no evidence produces just the draft form, with unresolved fields still explicitly drafts', async () => {
  const f = await fixture();
  const result = await renderDraftExport(f.snapshot, f.form.template, f.form.bytes, f.context, undefined, []);
  assert.equal(result.pageCount, 1); assert.equal(result.plan.summary.missing, 1);
});

test('any omitted reviewed form answer prevents artifact generation', async () => {
  const f = await fixture(); f.answers.answers[0].value = '\u0378';
  await assert.rejects(render(f), errorCode('FORM_RENDER_ISSUES'));
});

test('evidence must match the same case and a confirmed finding with its linked evidence ID', async () => {
  for (const mutate of [
    (f: Fixture) => { f.assets[0].descriptor.caseId = 'PRIVATE-OTHER-CASE'; },
    (f: Fixture) => { f.assets[0].descriptor.findingId = 'OTHER-FINDING'; },
    (f: Fixture) => { f.snapshot.findings[0].reviewState = 'needs_review'; },
    (f: Fixture) => { f.snapshot.findings[0].reviewState = 'dismissed'; },
    (f: Fixture) => { f.snapshot.findings[0].evidenceIds = []; },
    (f: Fixture) => { f.assets[0].descriptor.preparedAt = '2026-10-17T22:00:01Z'; },
    (f: Fixture) => { f.assets.push(f.assets[0]); },
  ]) {
    const f = await fixture(); mutate(f); await assert.rejects(render(f), errorCode('EVIDENCE_INVALID'));
  }
});

test('untrusted asset data cannot substitute pixels, dimensions, hashes, formats, or arbitrary extra metadata', async () => {
  for (const mutate of [
    (f: Fixture) => { f.assets[0].bytes[40] ^= 1; },
    (f: Fixture) => { f.assets[0].descriptor.width++; },
    (f: Fixture) => { f.assets[0].descriptor.byteLength++; },
    (f: Fixture) => { f.assets[0].descriptor.sha256 = '0'.repeat(64); },
    (f: Fixture) => { (f.assets[0].descriptor as any).url = 'https://PRIVATE/secret'; },
    (f: Fixture) => { (f.assets[0].descriptor as any).mediaType = 'application/pdf'; },
    (f: Fixture) => { f.assets[0].bytes = Buffer.from('%PDF-PRIVATE'); },
  ]) {
    const f = await fixture(); mutate(f); await assert.rejects(render(f), errorCode());
  }
});

test('selection count, aggregate bytes and overflowing captions fail without silently dropping content', async () => {
  const f = await fixture();
  await assert.rejects(render(f, Array(7).fill(f.assets[0])), errorCode('EVIDENCE_INVALID'));
  const big = Buffer.alloc(13 * 1024 * 1024);
  await assert.rejects(render(f, f.assets.map(asset => ({ bytes: big,
    descriptor: { ...asset.descriptor, byteLength: big.byteLength } }))), errorCode('CONTENT_TOO_LARGE'));
  for (const mutate of [
    (f: Fixture) => { f.snapshot.findings[0].observation = 'PRIVATE'.repeat(200); },
    (f: Fixture) => { f.snapshot.findings[0].observation = Array(40).fill('PRIVATE').join('\n'); },
    (f: Fixture) => { f.snapshot.findings[0].measurements = Array(9).fill(f.snapshot.findings[0].measurements[0]); },
    (f: Fixture) => { f.snapshot.findings[0].measurements[0].type = 'W'.repeat(81); },
  ]) {
    const f = await fixture(); mutate(f); await assert.rejects(render(f), errorCode('CONTENT_TOO_LARGE'));
  }
});

test('renderer refuses aggregate decoded pixels before validating or embedding PNG bytes', async () => {
  const f = await fixture();
  for (const asset of f.assets) {
    Object.assign(asset.descriptor, { width: 4000, height: 3000 });
    asset.bytes.fill(0);
  }
  await assert.rejects(render(f), errorCode('CONTENT_TOO_LARGE'));
});

test('unsupported evidence text fails accurately instead of being transliterated or silently truncated', async () => {
  for (const observation of ['PRIVATE \u0378', 'PRIVATE\u0000VALUE', 'PRIVATE e\u0301']) {
    const f = await fixture(); f.snapshot.findings[0].observation = observation;
    await assert.rejects(render(f), errorCode('TEXT_UNSUPPORTED'));
  }
});

for (const sample of [
  { script: 'Simplified', name: '李明', observation: '门口有台阶，请安装扶手。\n浴室地面湿滑，测量为 12.7 mm。',
    label: '入口扶手：请核对', repair: '希望安装浴室扶手，并修复入口台阶。' },
  { script: 'Traditional', name: '陳美華', observation: '門口有臺階，請安裝扶手。\n浴室地面濕滑，測量為 12.7 mm。',
    label: '入口扶手：請核對', repair: '希望安裝浴室扶手，並修復入口臺階。' },
  { script: 'Compatibility and supplementary Han', name: '兀兀𠮷吉', observation: '保留原字：兀兀。\n姓名原字：𠮷吉。',
    label: '核對原字：兀兀𠮷吉', repair: '請保留原字，不合併兀兀與𠮷吉。' },
]) test(`${sample.script} names, multiline observations, photo labels and intake paint with exact Unicode`, async () => {
  const f = await fixture();
  const at = '2026-10-24T22:00:00Z';
  f.form = (await (await loadRuntimeBenefitsBundle('team-beta-drafts-v2')).loadFormTemplate('rtp-home-repair'))!;
  f.context = { programId: 'rtp-home-repair', templateSha256: f.form.template.templateSha256, plannedAt: at };
  f.answers = createSavedFormAnswers({ snapshot: f.snapshot, context: createFormAnswerContext(f.form.template), answerRevision: 1,
    updatedAt: at, updatedBy: 'PRIVATE-REVIEWER', answers: [{ key: 'memberFirstName', value: sample.name, reviewState: 'reviewed' }] });
  f.snapshot.findings[0].observation = sample.observation;
  f.snapshot.findings[0].measurements[0].type = sample.script === 'Simplified' ? '台阶高度' : '臺階高度';
  const annotations = f.assets.map(asset => ({ ...emptyAnnotations(asset.descriptor, 1),
    marks: [{ id: 'label-box', rect: [800000, 800000, 200000, 200000] as [number, number, number, number], label: sample.label }],
    reviewState: 'reviewed' as const, reviewedCaseRevision: f.snapshot.revision, reviewedAt: at, reviewedBy: 'PRIVATE-REVIEWER' }));
  const definition = intakeDefinition('rtp-home-repair')!;
  const repair = `${sample.repair.repeat(9)} José / Lee 12.7 mm`;
  const intake: ProgramIntakeAppendix = { definition, saved: { schemaVersion: '2', caseId: f.snapshot.caseId,
    caseRevision: f.snapshot.revision, programId: definition.programId, questionnaireVersion: definition.questionnaireVersion,
    intakeRevision: 1, updatedAt: at, updatedBy: 'PRIVATE-REVIEWER',
    answers: [{ key: 'repairRequest', value: repair, reviewState: 'reported' }] } };
  const before = structuredClone({ snapshot: f.snapshot, answers: f.answers, annotations, intake });
  const result = await renderDraftExport(f.snapshot, f.form.template, f.form.bytes, f.context, f.answers, f.assets, annotations, intake);
  const document = await PDFDocument.load(result.bytes);
  assert.ok(paintedText(document, 0).includes(sample.name));
  for (const page of [1, 2]) {
    const painted = paintedText(document, page);
    assert.ok(painted.includes(`1: ${sample.label}`));
    assert.ok(painted.join('').includes(`Observation: ${sample.observation.replaceAll('\n', '')}`));
    assert.ok(painted.join('').includes(`${f.snapshot.findings[0].measurements[0].type}: 120 mm`));
    assert.match(pageStream(document, page), /0\.7 0\.08 0\.08 RG/);
  }
  const worksheet = Array.from({ length: document.getPageCount() - 3 }, (_, page) => paintedText(document, page + 3).join('')).join('');
  assert.ok(worksheet.includes(`Reported: ${repair}`), 'Every entered character survives line and page wrapping.');
  assert.deepEqual({ snapshot: f.snapshot, answers: f.answers, annotations, intake }, before);
  assert.ok(result.byteLength < 1024 * 1024, 'The packet embeds only needed Chinese glyphs, not the whole CJK font.');
});

test('Chinese captions and labels that do not fit fail explicitly without silently clipping or shrinking', async () => {
  const f = await fixture();
  f.snapshot.findings[0].observation = '門口有臺階\n'.repeat(40);
  await assert.rejects(render(f), errorCode('CONTENT_TOO_LARGE'));
  f.snapshot.findings[0].observation = '門口有臺階';
  const annotations = f.assets.map(asset => ({ ...emptyAnnotations(asset.descriptor),
    marks: [{ id: 'wide-label', rect: [0, 0, 1000000, 1000000] as [number, number, number, number], label: '門'.repeat(80) }] }));
  await assert.rejects(renderDraftExport(f.snapshot, f.form.template, f.form.bytes, f.context, f.answers, f.assets, annotations), errorCode('CONTENT_TOO_LARGE'));
});

test('multiline observations and missing measurements remain readable with explicit unknown capture time', async () => {
  const f = await fixture(); f.snapshot.findings[0].observation = 'First reviewed line.\nSecond reviewed line.';
  f.snapshot.findings[0].measurements = [];
  const result = await render(f); const document = await PDFDocument.load(result.bytes);
  const content = pageStream(document, 1);
  for (const text of ['Observation: First reviewed line.', 'Second reviewed line.',
    'Measurements: none supplied; physical dimensions remain unknown.']) assert.ok(content.includes(hex(text)));
});

test('caller mutation after invocation cannot change the case, image, form answers, or selection meaning', async () => {
  const f = await fixture(); const pending = render(f);
  f.snapshot.findings[0].observation = 'PRIVATE MUTATED OBSERVATION';
  f.snapshot.findings[0].reviewState = 'dismissed';
  f.answers.answers[0].value = 'PRIVATE MUTATED NAME';
  f.assets[0].descriptor.caseId = 'PRIVATE MUTATED CASE'; f.assets[0].bytes.fill(0);
  f.form.bytes.fill(0); f.context.programId = 'MUTATED';
  const result = await pending; const document = await PDFDocument.load(result.bytes);
  assert.equal(result.pageCount, 3); const content = streams(document);
  assert.ok(content.includes(hex('Observation: Fictional step at the entrance.')));
  assert.ok(!content.includes(hex('PRIVATE MUTATED')));
});


test('text-first serialization replaces each image slot without changing photo order or overlay paint order', async () => {
  const f = await fixture();
  f.snapshot.findings[0].observation = '門口臺階需要扶手';
  const annotations = f.assets.map(asset => ({ ...emptyAnnotations(asset.descriptor),
    marks: [{ id: 'exact-overlay', rect: [100000, 100000, 300000, 300000] as [number, number, number, number], label: '扶手位置' }] }));
  const original = PDFDocument.load;
  let textStages = 0;
  const load = mock.method(PDFDocument, 'load', async (...args: Parameters<typeof PDFDocument.load>) => {
    const document = await original(...args);
    const slots = document.context.enumerateIndirectObjects().filter(([, value]) =>
      value instanceof PDFRawStream && value.dict.has(PDFName.of('SafeAtHomeEvidenceSlot')));
    if (slots.length > 0) {
      textStages++;
      assert.equal(slots.length, 2);
      assert.equal(document.context.enumerateIndirectObjects().some(([, value]) =>
        value instanceof PDFRawStream && value.dict.get(PDFName.of('Subtype')) === PDFName.of('Image')), false);
      assert.ok(paintedText(document, 1).includes('1: 扶手位置'));
    }
    return document;
  });
  let result: Awaited<ReturnType<typeof renderDraftExport>>;
  try { result = await renderDraftExport(f.snapshot, f.form.template, f.form.bytes, f.context, f.answers, f.assets, annotations); }
  finally { load.mock.restore(); }
  assert.equal(textStages, 1);
  const document = await PDFDocument.load(result!.bytes);
  assert.equal(document.context.enumerateIndirectObjects().some(([, value]) =>
    value instanceof PDFRawStream && value.dict.has(PDFName.of('SafeAtHomeEvidenceSlot'))), false);
  for (const [index, expected] of [[255, 0, 0], [0, 0, 255]].entries()) {
    const page = document.getPage(index + 1);
    const resources = page.node.Resources()!.lookup(PDFName.of('XObject'), PDFDict);
    const images = resources.entries().filter(([name]) => name.decodeText().startsWith('Evidence-'));
    assert.equal(images.length, 1);
    const [name, ref] = images[0];
    const image = document.context.lookup(ref);
    assert.ok(image instanceof PDFRawStream);
    assert.equal(image.dict.get(PDFName.of('Subtype')), PDFName.of('Image'));
    assert.deepEqual(Array.from(decodePDFRawStream(image).decode().subarray(0, 3)), expected);
    const content = pageStream(document, index + 1);
    assert.ok(content.indexOf(`${name} Do`) >= 0);
    assert.ok(content.indexOf(`${name} Do`) < content.indexOf('0.7 0.08 0.08 RG'), 'Photo paints before its annotation.');
    assert.ok(paintedText(document, index + 1).includes('1: 扶手位置'));
  }
});

test('changed text-stage slot identity or geometry fails before a mismatched image can be returned', async () => {
  for (const mode of ['binding', 'index', 'bounds']) {
    const f = await fixture();
    const original = PDFDocument.load;
    let mutated = false;
    const load = mock.method(PDFDocument, 'load', async (...args: Parameters<typeof PDFDocument.load>) => {
      const document = await original(...args);
      const slots = document.context.enumerateIndirectObjects().filter(([, value]) =>
        value instanceof PDFRawStream && value.dict.has(PDFName.of('SafeAtHomeEvidenceSlot')));
      if (slots.length > 0) {
        mutated = true;
        const slot = slots[0][1]; assert.ok(slot instanceof PDFRawStream);
        if (mode === 'binding') {
          const resources = document.getPage(1).node.Resources()!.lookup(PDFName.of('XObject'), PDFDict);
          const name = resources.keys().find(key => key.decodeText().startsWith('Evidence-'))!;
          resources.set(name, slots[1][0]);
        } else if (mode === 'index') slot.dict.set(PDFName.of('SafeAtHomeEvidenceSlot'), PDFNumber.of(99));
        else slot.dict.set(PDFName.of('BBox'), document.context.obj([0, 0, 2, 1]));
      }
      return document;
    });
    try { await assert.rejects(render(f), errorCode('RENDER_FAILED')); }
    finally { load.mock.restore(); }
    assert.equal(mutated, true);
  }
});
