import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test, { mock } from 'node:test';
import { createHash } from 'node:crypto';
import { PDFDocument, PDFDict, PDFName, PDFRawStream, decodePDFRawStream } from 'pdf-lib';
import { embedReviewedTextFont, ReviewedTextFontSession } from '../src/pdf/reviewed-text-font.ts';
import { paintedTextRuns } from '../tool/pdf-verification-text.ts';

test('ordinary Latin exports keep Helvetica and accented names', async () => {
  const document = await PDFDocument.create();
  const reviewed = await embedReviewedTextFont(document, ['José Martínez']);
  assert.equal(reviewed.font.name, 'Helvetica');
  assert.equal(reviewed.supports('José Martínez'), true);
  document.addPage().drawText('José Martínez', { font: reviewed.font, size: 10 });
  assert.ok((await document.save()).length < 3000);
});

test('one embedded subset preserves simplified, traditional, Latin and compatibility name characters exactly', async () => {
  const text = '陈秀兰 陳秀蘭 黄丽娟 黃麗娟 José 兀兀 王𠮷';
  const document = await PDFDocument.create();
  const reviewed = await embedReviewedTextFont(document, [text]);
  assert.equal(reviewed.supports(text), true);
  document.addPage().drawText(text, { font: reviewed.font, x: 30, y: 700, size: 12 });
  const bytes = await document.save();
  assert.ok(bytes.length < 150_000, 'only used glyphs should be embedded');
  const loaded = await PDFDocument.load(bytes);
  assert.deepEqual(paintedTextRuns(loaded, 0).map(run => run.text), [text]);
});

test('Chinese metrics enclose independent glyph outlines and agree with the actual text advances', async () => {
  const document = await PDFDocument.create();
  const text = '陈秀兰 陳秀蘭 Ág 兀兀';
  const reviewed = await embedReviewedTextFont(document, [text]);
  const { default: fontkit } = await import('@pdf-lib/fontkit');
  const parsed = fontkit.create(await readFile(new URL('../assets/fonts/SafeAtHomeCJK-Regular.otf', import.meta.url)));
  const bounds = reviewed.inkBounds(text);
  let advance = 0;
  for (const glyph of parsed.layout(text).glyphs) {
    const box = glyph.bbox;
    if (Number.isFinite(box.minX)) {
      assert.ok(bounds.left <= advance + box.minX / 1000);
      assert.ok(bounds.right >= advance + box.maxX / 1000);
      assert.ok(bounds.bottom <= box.minY / 1000);
      assert.ok(bounds.top >= box.maxY / 1000);
    }
    advance += glyph.advanceWidth / 1000;
  }
  assert.ok(Math.abs(reviewed.font.widthOfTextAtSize(text, 10) - advance * 10) < 0.001);
  assert.ok(bounds.right >= advance);
});

test('missing glyphs and positional Unicode controls stay explicit failures', async () => {
  const document = await PDFDocument.create();
  const reviewed = await embedReviewedTextFont(document, ['中文 😀']);
  for (const text of ['😀', 'e\u0301', '王\uFE00', '李\u200D', '\uD800', '\u202Eabc', '\u0000']) {
    assert.equal(reviewed.supports(text), false);
    assert.throws(() => reviewed.inkBounds(text), /Unsupported reviewed text/);
  }
});

test('separate document subsets cannot leak an earlier resident name', async () => {
  for (const text of ['陈秀兰兀', '陳秀蘭兀']) {
    const document = await PDFDocument.create();
    const reviewed = await embedReviewedTextFont(document, [text]);
    document.addPage().drawText(text, { font: reviewed.font, size: 10 });
    const loaded = await PDFDocument.load(await document.save());
    assert.deepEqual(paintedTextRuns(loaded, 0).map(run => run.text), [text]);
  }
});


test('the pinned fontkit adapter reads one exact shared font allocation without changing it', async () => {
  const { default: fontkit } = await import('@pdf-lib/fontkit');
  const original = fontkit.create;
  const inputs: ArrayBuffer[] = [];
  const create = mock.method(fontkit, 'create', (data: unknown) => {
    assert.ok(data instanceof ArrayBuffer);
    assert.equal(data.byteLength, 10013776);
    inputs.push(data);
    return (original as unknown as (bytes: ArrayBuffer) => ReturnType<typeof original>)(data);
  });
  try {
    for (const text of ['陈秀兰', '陳秀蘭兀']) {
      const document = await PDFDocument.create();
      const reviewed = await embedReviewedTextFont(document, [text]);
      document.addPage().drawText(text, { font: reviewed.font, size: 10 });
      await document.save();
    }
    assert.equal(inputs.length, 2);
    assert.equal(inputs[0], inputs[1], 'only immutable source bytes are shared');
    assert.equal(createHash('sha256').update(new Uint8Array(inputs[0])).digest('hex'),
      'd27dcda3225034eed81d12e98c2e2cf3a23c5405856927ab6b69e6cfa449ccad');
  } finally { create.mock.restore(); }
});

test('CFF subsets have a valid native font header instead of relying on a viewer fallback', async () => {
  const text = '陈美华 陳美華 繁複 𠮷 兀兀 Aé 123 简体中文 繁體中文';
  const document = await PDFDocument.create();
  const reviewed = await embedReviewedTextFont(document, [text]);
  document.addPage().drawText(text, { font: reviewed.font, size: 12 });
  const loaded = await PDFDocument.load(await document.save());
  const fonts = loaded.context.enumerateIndirectObjects().flatMap(([, object]) => {
    if (!(object instanceof PDFDict) || !object.has(PDFName.of('FontFile3'))) return [];
    const stream = object.lookup(PDFName.of('FontFile3'));
    assert.ok(stream instanceof PDFRawStream);
    return [decodePDFRawStream(stream).decode()];
  });
  assert.equal(fonts.length, 1);
  assert.deepEqual([...fonts[0].subarray(0, 4)], [1, 0, 4, 4],
    'CFF offSize must be 1–4; fontkit 1.1.1 incorrectly emits the source table length');
  assert.deepEqual(paintedTextRuns(loaded, 0).map(run => run.text), [text]);
});

test('the derivative keeps exact upstream outlines across Chinese scripts and all source font dictionaries', async () => {
  const fixture = JSON.parse(await readFile(new URL('./reviewed-font-outlines.fixture.json', import.meta.url), 'utf8'));
  const { default: fontkit } = await import('@pdf-lib/fontkit');
  const parsed = fontkit.create(await readFile(new URL('../assets/fonts/SafeAtHomeCJK-Regular.otf', import.meta.url)));
  for (const glyph of fixture.glyphs) {
    assert.equal(createHash('sha256').update(parsed.glyphForCodePoint(glyph.codepoint).path.toSVG()).digest('hex'),
      glyph.svgSha256, `The original outline for ${glyph.character} must be retained`);
  }
});


test('one export reuses its parser with independent, distinctly named form and appendix subsets', async () => {
  const { default: fontkit } = await import('@pdf-lib/fontkit');
  const original = fontkit.create;
  let parses = 0;
  const create = mock.method(fontkit, 'create', (data: unknown) => {
    parses += 1;
    return (original as unknown as (bytes: unknown) => ReturnType<typeof original>)(data);
  });
  try {
    const session = new ReviewedTextFontSession();
    const outputs: PDFDocument[] = [];
    for (const [role, text] of [['form', '李明'], ['appendix', '陳秀蘭李兀兀𠮷']] as const) {
      const document = await PDFDocument.create({ updateMetadata: false });
      const reviewed = await embedReviewedTextFont(document, [text], session, role);
      document.addPage().drawText(text, { font: reviewed.font, size: 10 });
      const loaded = await PDFDocument.load(await document.save(), { updateMetadata: false });
      assert.deepEqual(paintedTextRuns(loaded, 0).map(run => run.text), [text]);
      outputs.push(loaded);
    }
    assert.equal(parses, 1);
    const combined = await PDFDocument.create({ updateMetadata: false });
    for (const document of outputs) combined.addPage((await combined.copyPages(document, [0]))[0]);
    const loaded = await PDFDocument.load(await combined.save(), { updateMetadata: false });
    assert.deepEqual(paintedTextRuns(loaded, 0).map(run => run.text), ['李明']);
    assert.deepEqual(paintedTextRuns(loaded, 1).map(run => run.text), ['陳秀蘭李兀兀𠮷']);
    const names = loaded.context.enumerateIndirectObjects().flatMap(([, object]) =>
      object instanceof PDFDict && object.get(PDFName.of('Subtype')) === PDFName.of('Type0')
        ? [object.lookup(PDFName.of('BaseFont'), PDFName).decodeText()] : []);
    assert.deepEqual(names.sort(), ['SAHEVD+SafeAtHomeCJK-Regular', 'SAHFRM+SafeAtHomeCJK-Regular']);
  } finally { create.mock.restore(); }
});
