import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { createHook } from 'node:async_hooks';
import { deflateSync } from 'node:zlib';
import sharp from 'sharp';
import { PDFDocument, PDFName, PDFRawStream, PDFRef, decodePDFRawStream } from 'pdf-lib';
import { sanitizeEvidenceImage } from '../src/evidence/image-sanitizer.ts';
import type { EvidenceAsset } from '../src/evidence/types.ts';
import { embedEvidenceImage, EvidenceEmbeddingError, prepareEvidenceImageEmbeddings } from '../src/exports/embed-evidence-image.ts';

async function fixture(rgba: Buffer, width: number, height: number): Promise<EvidenceAsset> {
  const image = await sanitizeEvidenceImage(await sharp(rgba, { raw: { width, height, channels: 4 } }).png().toBuffer());
  const { bytes, ...imageFields } = image;
  return { bytes, descriptor: { ...imageFields, caseId: 'PRIVATE-CASE', evidenceId: 'PRIVATE-PHOTO',
    findingId: 'PRIVATE-FINDING', evidenceRevision: 1, capturedAt: null, preparedAt: '2026-10-19T00:00:00Z' } };
}
function channels(rgba: Buffer) {
  const rgb: number[] = [], alpha: number[] = [];
  for (let offset = 0; offset < rgba.length; offset += 4) {
    rgb.push(rgba[offset], rgba[offset + 1], rgba[offset + 2]); alpha.push(rgba[offset + 3]);
  }
  return { rgb: Buffer.from(rgb), alpha: Buffer.from(alpha) };
}
function stream(document: PDFDocument, ref: PDFRef): PDFRawStream {
  const value = document.context.lookup(ref); assert.ok(value instanceof PDFRawStream); return value;
}
function safeError(code: EvidenceEmbeddingError['code']) {
  return (error: unknown): boolean => {
    assert.ok(error instanceof EvidenceEmbeddingError); assert.equal(error.code, code);
    assert.ok(!error.message.includes('PRIVATE')); return true;
  };
}

function pngChunk(type: string, data: Uint8Array): Buffer {
  const bytes = Buffer.alloc(data.length + 12); bytes.writeUInt32BE(data.length, 0);
  bytes.write(type, 4, 'ascii'); bytes.set(data, 8);
  let crc = 0xffffffff;
  for (const byte of bytes.subarray(4, -4)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  bytes.writeUInt32BE((crc ^ 0xffffffff) >>> 0, bytes.length - 4); return bytes;
}

function filteredFixture(pixels: Buffer, width: number, height: number, filters: number[]) {
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 6;
  const raster = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    const filter = filters[y % filters.length], rowStart = y * (width * 4 + 1);
    raster[rowStart] = filter;
    for (let x = 0; x < width * 4; x++) {
      const index = y * width * 4 + x;
      const a = x >= 4 ? pixels[index - 4] : 0;
      const b = y > 0 ? pixels[index - width * 4] : 0;
      const c = x >= 4 && y > 0 ? pixels[index - width * 4 - 4] : 0;
      let predictor = 0;
      if (filter === 1) predictor = a;
      if (filter === 2) predictor = b;
      if (filter === 3) predictor = (a + b) >>> 1;
      if (filter === 4) {
        const p = a + b - c;
        predictor = [a, b, c].map(value => ({ value, distance: Math.abs(p - value) }))
          .sort((left, right) => left.distance - right.distance)[0].value;
      }
      raster[rowStart + x + 1] = (pixels[index] - predictor + 256) & 255;
    }
  }
  const pack = (compressed = deflateSync(raster)) => Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), pngChunk('IHDR', header),
    pngChunk('IDAT', compressed.subarray(0, 1)), pngChunk('IDAT', compressed.subarray(1, 3)),
    pngChunk('IDAT', compressed.subarray(3, -2)), pngChunk('IDAT', compressed.subarray(-2)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
  const asset = (bytes = pack()): EvidenceAsset => ({ bytes, descriptor: {
    caseId: 'PRIVATE-CASE', findingId: 'PRIVATE-FINDING', evidenceId: 'PRIVATE-PHOTO', evidenceRevision: 1,
    width, height, byteLength: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'),
    mediaType: 'image/png', processingVersion: 'evidence-png-v1', capturedAt: null, preparedAt: '2026-10-19T00:00:00Z',
  } });
  return { raster, pack, asset };
}

test('lossless Image and SMask streams preserve every RGB and alpha byte, including hidden colours', async () => {
  const pixels = Buffer.from([255, 0, 0, 0, 0, 255, 0, 1, 0, 0, 255, 128,
    10, 20, 30, 254, 255, 255, 255, 255, 0, 0, 0, 255]);
  const asset = await fixture(pixels, 3, 2), document = await PDFDocument.create();
  const canonical = await sharp(asset.bytes).raw().toBuffer();
  const embedded = await embedEvidenceImage(document, asset);
  assert.equal(embedded.width, 3); assert.equal(embedded.height, 2);
  const image = stream(document, embedded.ref), maskRef = image.dict.get(PDFName.of('SMask'));
  assert.ok(maskRef instanceof PDFRef);
  const mask = stream(document, maskRef), expected = channels(canonical);
  assert.equal(image.dict.get(PDFName.of('ColorSpace')), PDFName.of('DeviceRGB'));
  assert.equal(mask.dict.get(PDFName.of('ColorSpace')), PDFName.of('DeviceGray'));
  assert.deepEqual(Buffer.from(decodePDFRawStream(image).decode()), expected.rgb);
  assert.deepEqual(Buffer.from(decodePDFRawStream(mask).decode()), expected.alpha);
  assert.equal(embedded.compressedBytes, image.contents.length + mask.contents.length);
  assert.doesNotMatch(image.dict.toString() + mask.dict.toString(), /PRIVATE/);
});

test('opaque images omit SMask while streaming colour rows across multiple bounded chunks', async () => {
  const width = 257, height = 129, pixels = Buffer.alloc(width * height * 4);
  for (let offset = 0; offset < pixels.length; offset += 4) {
    pixels[offset] = offset % 251; pixels[offset + 1] = (offset * 3) % 253;
    pixels[offset + 2] = (offset * 7) % 255; pixels[offset + 3] = 255;
  }
  const asset = await fixture(pixels, width, height), document = await PDFDocument.create();
  const embedded = await embedEvidenceImage(document, asset), image = stream(document, embedded.ref);
  assert.equal(image.dict.has(PDFName.of('SMask')), false);
  assert.deepEqual(Buffer.from(decodePDFRawStream(image).decode()), channels(pixels).rgb);
});

test('embedding captures caller bytes and descriptors before native work yields', async () => {
  const asset = await fixture(Buffer.from([11, 22, 33, 44]), 1, 1), document = await PDFDocument.create();
  const pending = embedEvidenceImage(document, asset);
  asset.bytes.fill(0); asset.descriptor.width = 100; asset.descriptor.sha256 = '0'.repeat(64);
  const embedded = await pending;
  assert.equal(embedded.width, 1);
  assert.deepEqual(Buffer.from(decodePDFRawStream(stream(document, embedded.ref)).decode()), Buffer.from([11, 22, 33]));
});

test('invalid canonical input and compressed capacity refusal do not register partial image objects', async () => {
  const asset = await fixture(Buffer.from([11, 22, 33, 44]), 1, 1), document = await PDFDocument.create();
  const initial = document.context.enumerateIndirectObjects().length;
  await assert.rejects(embedEvidenceImage(document, asset, 1), safeError('CONTENT_TOO_LARGE'));
  assert.equal(document.context.enumerateIndirectObjects().length, initial);
  const invalid = structuredClone(asset); invalid.bytes[0] ^= 1;
  await assert.rejects(embedEvidenceImage(document, invalid), safeError('EVIDENCE_INVALID'));
  await assert.rejects(embedEvidenceImage(document, { ...asset, descriptor: { ...asset.descriptor, width: 2 } }), safeError('EVIDENCE_INVALID'));
  assert.equal(document.context.enumerateIndirectObjects().length, initial);
  for (const limit of [0, -1, NaN, Infinity, 1.5, 32 * 1024 * 1024 + 1]) {
    await assert.rejects(embedEvidenceImage(document, asset, limit), safeError('CONTENT_TOO_LARGE'));
  }
});

test('all five PNG filters, first-row predictors and Paeth ties preserve pixels across row/IDAT boundaries', async () => {
  for (const [width, height, filters] of [
    [1, 20, [4, 3, 2, 1, 0]], [257, 129, [0, 1, 2, 3, 4]], [8192, 3, [4, 4, 4]],
  ] as const) {
    const pixels = Buffer.alloc(width * height * 4);
    for (let offset = 0; offset < pixels.length; offset++) {
      pixels[offset] = offset % 13 === 0 ? 0 : offset % 11 === 0 ? 255 : (offset * 79 + (offset >>> 2) * 31) & 255;
    }
    const asset = filteredFixture(pixels, width, height, [...filters]).asset();
    assert.deepEqual(await sharp(asset.bytes).raw().toBuffer(), pixels);
    const document = await PDFDocument.create(), embedded = await embedEvidenceImage(document, asset);
    const image = stream(document, embedded.ref), maskRef = image.dict.get(PDFName.of('SMask'));
    assert.ok(maskRef instanceof PDFRef);
    const expected = channels(pixels);
    assert.deepEqual(Buffer.from(decodePDFRawStream(image).decode()), expected.rgb);
    assert.deepEqual(Buffer.from(decodePDFRawStream(stream(document, maskRef)).decode()), expected.alpha);
  }
});

test('a final nonopaque row backfills all preceding opaque rows without changing colour or alpha', async () => {
  const width = 7, height = 100, pixels = Buffer.alloc(width * height * 4, 255);
  pixels[pixels.length - 1] = 1; pixels[pixels.length - 2] = 19;
  const asset = filteredFixture(pixels, width, height, [4, 3, 2, 1, 0]).asset(), document = await PDFDocument.create();
  const embedded = await embedEvidenceImage(document, asset), image = stream(document, embedded.ref);
  const maskRef = image.dict.get(PDFName.of('SMask')); assert.ok(maskRef instanceof PDFRef);
  assert.deepEqual(Buffer.from(decodePDFRawStream(image).decode()), channels(pixels).rgb);
  assert.deepEqual(Buffer.from(decodePDFRawStream(stream(document, maskRef)).decode()), channels(pixels).alpha);
});

test('every filter handles a first row and Paeth resolves left/above/upper-left ties in PNG order', async () => {
  const pixels = Buffer.from([10, 10, 73, 0, 30, 0, 73, 255, 0, 30, 73, 128, 171, 13, 49, 3]);
  for (const firstFilter of [0, 1, 2, 3, 4]) {
    const asset = filteredFixture(pixels, 2, 2, [firstFilter, 4]).asset();
    assert.deepEqual(await sharp(asset.bytes).raw().toBuffer(), pixels);
    const document = await PDFDocument.create(), embedded = await embedEvidenceImage(document, asset);
    const image = stream(document, embedded.ref), maskRef = image.dict.get(PDFName.of('SMask'));
    assert.ok(maskRef instanceof PDFRef);
    assert.deepEqual(Buffer.from(decodePDFRawStream(image).decode()), channels(pixels).rgb);
    assert.deepEqual(Buffer.from(decodePDFRawStream(stream(document, maskRef)).decode()), channels(pixels).alpha);
  }
});

test('compressed budget accepts the exact total and rejects one byte less with both channels active', async () => {
  const width = 257, height = 300, pixels = Buffer.alloc(width * height * 4);
  let seed = 0x12345678;
  for (let offset = 0; offset < pixels.length; offset++) {
    seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; pixels[offset] = seed & 255;
  }
  const asset = filteredFixture(pixels, width, height, [0, 1, 2, 3, 4]).asset();
  const accepted = await embedEvidenceImage(await PDFDocument.create(), asset);
  const exact = await embedEvidenceImage(await PDFDocument.create(), asset, accepted.compressedBytes);
  assert.equal(exact.compressedBytes, accepted.compressedBytes);
  const rejected = await PDFDocument.create(), initial = rejected.context.enumerateIndirectObjects().length;
  for (const limit of [64, accepted.compressedBytes - 1]) {
    await assert.rejects(embedEvidenceImage(rejected, asset, limit), safeError('CONTENT_TOO_LARGE'));
    assert.equal(rejected.context.enumerateIndirectObjects().length, initial);
  }
  assert.equal((await embedEvidenceImage(rejected, asset)).compressedBytes, accepted.compressedBytes);
});

test('malformed filtered streams finish validation refusal before starting either PDF deflater', async () => {
  const pixels = Buffer.from([255, 0, 0, 128, 0, 255, 0, 255]), f = filteredFixture(pixels, 1, 2, [4]);
  const invalidFilter = Buffer.from(f.raster); invalidFilter[5] = 5;
  const compressed = deflateSync(f.raster);
  const variants = [compressed.subarray(0, -1), Buffer.concat([compressed, deflateSync(Buffer.alloc(0))]),
    Buffer.concat([compressed, Buffer.from('PRIVATE')]), deflateSync(invalidFilter),
    deflateSync(f.raster.subarray(0, -1)), deflateSync(Buffer.concat([f.raster, Buffer.from([0])]))];
  for (const input of variants) {
    const document = await PDFDocument.create(), initial = document.context.enumerateIndirectObjects().length;
    let nativeStreams = 0;
    const hook = createHook({ init(_id, type) { if (type === 'ZLIB') nativeStreams++; } });
    hook.enable();
    try { await assert.rejects(embedEvidenceImage(document, f.asset(f.pack(input))), safeError('EVIDENCE_INVALID')); }
    finally { hook.disable(); }
    assert.equal(nativeStreams, 1, 'Only the bounded canonical validator may start for malformed input.');
    assert.equal(document.context.enumerateIndirectObjects().length, initial);
  }
});

test('prepared embeddings snapshot the whole selection and keep private bytes and metadata out of caller reach', async () => {
  const pixels = Buffer.from([11, 22, 33, 44]);
  const inputs = [filteredFixture(pixels, 1, 1, [4]).asset(), filteredFixture(pixels, 1, 1, [2]).asset()];
  const pending = prepareEvidenceImageEmbeddings(inputs);
  inputs[0].bytes.fill(0); inputs[1].bytes.fill(0); inputs[1].descriptor.width = 8192;
  inputs[1].descriptor.evidenceId = 'changed'; inputs.pop();
  const prepared = await pending;
  assert.equal(prepared.length, 2);
  for (const image of prepared) {
    assert.deepEqual(Object.keys(image).sort(), ['descriptor', 'embed']);
    assert.equal(image.descriptor.width, 1); assert.equal(image.descriptor.evidenceId, 'PRIVATE-PHOTO');
    image.descriptor.width = 8192; image.descriptor.height = 8192;
    image.descriptor.sha256 = '0'.repeat(64); image.descriptor.byteLength = 0;
    const document = await PDFDocument.create(), embedded = await image.embed(document);
    assert.equal(embedded.width, 1); assert.equal(embedded.height, 1);
    const rgb = stream(document, embedded.ref), mask = rgb.dict.get(PDFName.of('SMask'));
    assert.ok(mask instanceof PDFRef);
    assert.deepEqual(Buffer.from(decodePDFRawStream(rgb).decode()), Buffer.from([11, 22, 33]));
    assert.deepEqual(Buffer.from(decodePDFRawStream(stream(document, mask)).decode()), Buffer.from([44]));
  }
});

test('prepared embeddings are one-use after success, failure and during an in-flight attempt', async () => {
  const pixels = Buffer.alloc(257 * 50 * 4, 24), input = filteredFixture(pixels, 257, 50, [4, 3, 2, 1, 0]).asset();
  const [prepared] = await prepareEvidenceImageEmbeddings([input]), document = await PDFDocument.create();
  const first = prepared.embed(document);
  await assert.rejects(prepared.embed(document), safeError('EVIDENCE_INVALID'));
  await first;
  const count = document.context.enumerateIndirectObjects().length;
  await assert.rejects(prepared.embed(document), safeError('EVIDENCE_INVALID'));
  assert.equal(document.context.enumerateIndirectObjects().length, count);
  const [refused] = await prepareEvidenceImageEmbeddings([input]), rejectedDocument = await PDFDocument.create();
  const initial = rejectedDocument.context.enumerateIndirectObjects().length;
  await assert.rejects(refused.embed(rejectedDocument, 1), safeError('CONTENT_TOO_LARGE'));
  await assert.rejects(refused.embed(rejectedDocument), safeError('EVIDENCE_INVALID'));
  assert.equal(rejectedDocument.context.enumerateIndirectObjects().length, initial);
});

test('batch embedding preparation rejects aggregate limits before copying or opening decompression streams', async () => {
  const input = filteredFixture(Buffer.from([11, 22, 33, 44]), 1, 1, [4]).asset();
  const tooMany = Array(7).fill(input), tooManyPixels = [structuredClone(input), structuredClone(input)];
  for (const asset of tooManyPixels) { asset.descriptor.width = 4000; asset.descriptor.height = 3000; }
  for (const inputs of [tooMany, tooManyPixels]) {
    let streams = 0;
    const hook = createHook({ init(_id, type) { if (type === 'ZLIB') streams++; } });
    hook.enable();
    try { await assert.rejects(prepareEvidenceImageEmbeddings(inputs), safeError('EVIDENCE_INVALID')); }
    finally { hook.disable(); }
    assert.equal(streams, 0);
  }
});
