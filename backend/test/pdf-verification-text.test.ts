import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument, PDFName, StandardFonts } from 'pdf-lib';
import { paintedText, paintedTextRuns } from '../tool/pdf-verification-text.ts';

async function fixture(operators: string, mapping = '2 beginbfchar\n<0001> <9648>\n<0002> <D842DFB7>\nendbfchar') {
  const document = await PDFDocument.create(), page = document.addPage([300, 400]);
  const unicode = document.context.register(document.context.flateStream(mapping));
  const font = document.context.register(document.context.obj({ Type: 'Font', Subtype: 'Type0', BaseFont: 'FictionalVerificationFont', ToUnicode: unicode }));
  const resources = document.context.obj({ Font: { FictionalChinese: font } });
  const form = document.context.register(document.context.flateStream(`BT /FictionalChinese 9 Tf ${operators} ET`, {
    Type: 'XObject', Subtype: 'Form', BBox: [0, 0, 300, 400], Resources: resources,
  }));
  const latin = await document.embedFont(StandardFonts.Helvetica);
  page.drawText('Latin first', { x: 10, y: 350, size: 11, font: latin });
  page.node.Resources()!.set(PDFName.of('XObject'), document.context.obj({ ReviewedAppearance: form }));
  page.node.addContentStream(document.context.register(document.context.flateStream('/ReviewedAppearance Do')));
  document.setSubject('Unused metadata 陈𠮷');
  return PDFDocument.load(await document.save());
}

test('painted text follows flattened appearance resources and exact supplementary Unicode with font size', async () => {
  const document = await fixture('<00010002> Tj');
  assert.deepEqual(paintedText(document, 0), ['Latin first', '陈𠮷']);
  assert.deepEqual(paintedTextRuns(document, 0).at(-1), { text: '陈𠮷', fontSize: 9, depth: 1 });
});

test('unused CMap entries, metadata, comments and literal operator-looking strings are not painted text', async () => {
  const document = await fixture('% <00010002> Tj\n(<00010002> Tj) Tj');
  assert.deepEqual(paintedText(document, 0), ['Latin first']);
});

test('a painted missing or unmapped CID fails closed instead of becoming a placeholder or omitted name', async () => {
  for (const code of ['0000', '0003']) {
    const document = await fixture(`<${code}> Tj`);
    assert.throws(() => paintedText(document, 0));
  }
});

test('unused source appearance fonts are tolerated but painted text still requires a resolved font', async () => {
  const empty = await fixture('/AbsentSourceFont 10 Tf () Tj');
  assert.deepEqual(paintedText(empty, 0), ['Latin first']);
  const painted = await fixture('/AbsentSourceFont 10 Tf <0001> Tj');
  assert.throws(() => paintedText(painted, 0));
});

test('range mappings preserve both explicit and incremented Unicode destinations', async () => {
  const document = await fixture('<0001000200030004> Tj',
    '2 beginbfrange\n<0001> <0002> <4E00>\n<0003> <0004> [<9648> <9673>]\nendbfrange');
  assert.equal(paintedText(document, 0).at(-1), '一丁陈陳');
});
