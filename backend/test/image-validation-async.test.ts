import assert from 'node:assert/strict';
import { createHook } from 'node:async_hooks';
import { createHash } from 'node:crypto';
import { deflateSync } from 'node:zlib';
import test from 'node:test';
import { ImageSanitizationError, MAX_SANITIZED_IMAGE_BYTES, validateSanitizedEvidenceImage,
  validateSanitizedEvidenceImageAsync, validateSanitizedEvidenceImagesAsync } from '../src/evidence/image-sanitizer.ts';
import { parseEvidenceAssetAsync, parseEvidenceAssetsAsync, parseSanitizedEvidenceImageAsync } from '../src/evidence/validation.ts';
import type { EvidenceAsset } from '../src/evidence/types.ts';

const PNG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
function chunk(type: string, data: Uint8Array): Buffer {
  const bytes = Buffer.alloc(data.length + 12); bytes.writeUInt32BE(data.length, 0);
  bytes.write(type, 4, 'ascii'); bytes.set(data, 8);
  let crc = 0xffffffff;
  for (const byte of bytes.subarray(4, -4)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  bytes.writeUInt32BE((crc ^ 0xffffffff) >>> 0, bytes.length - 4); return bytes;
}
function fixture(width = 17, height = 2000) {
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 6;
  const raster = Buffer.alloc((width * 4 + 1) * height, 25);
  for (let row = 0; row < height; row++) raster[row * (width * 4 + 1)] = row % 5;
  const compressed = deflateSync(raster);
  const pack = (data = compressed, selectedHeader = header, split = false) => Buffer.concat([PNG,
    chunk('IHDR', selectedHeader), ...(split
      ? [chunk('IDAT', data.subarray(0, 1)), chunk('IDAT', data.subarray(1, 3)),
        chunk('IDAT', data.subarray(3, -2)), chunk('IDAT', data.subarray(-2))]
      : [chunk('IDAT', data)]), chunk('IEND', Buffer.alloc(0))]);
  return { header, raster, compressed, pack, width, height };
}
function asset(bytes: Uint8Array, id = 'photo-a', width = 17, height = 2000): EvidenceAsset {
  return { bytes, descriptor: { caseId: 'case-a', findingId: 'finding-a', evidenceId: id, evidenceRevision: 1,
    width, height, byteLength: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'),
    mediaType: 'image/png', processingVersion: 'evidence-png-v1', capturedAt: null, preparedAt: '2026-10-19T00:00:00Z' } };
}
function safeError(error: unknown): boolean {
  assert.ok(error instanceof ImageSanitizationError);
  assert.ok(!error.message.includes('PRIVATE')); return true;
}

test('streaming canonical verification matches sync metadata across IDAT and raster chunk boundaries', async () => {
  const f = fixture();
  for (const bytes of [f.pack(), f.pack(f.compressed, f.header, true)]) {
    const actual = await validateSanitizedEvidenceImageAsync(bytes);
    const { bytes: detached, ...metadata } = actual;
    assert.deepEqual(metadata, validateSanitizedEvidenceImage(bytes));
    assert.deepEqual(Buffer.from(detached), bytes); assert.notEqual(detached.buffer, bytes.buffer);
    detached.fill(0); assert.notEqual(bytes[0], 0);
  }
});

test('streaming validation rejects CRC, noncanonical chunks, headers, bounds and PNG trailers', async () => {
  const f = fixture(2, 2), valid = f.pack(), badCrc = Buffer.from(valid); badCrc[badCrc.length - 1] ^= 1;
  const invalid: unknown[] = [null, '/PRIVATE/image.png', new Uint8Array(), Buffer.alloc(MAX_SANITIZED_IMAGE_BYTES + 1),
    badCrc, valid.subarray(0, -1), Buffer.concat([valid, Buffer.from('PRIVATE TRAILER')]),
    Buffer.concat([PNG, chunk('IHDR', f.header), chunk('tEXt', Buffer.from('PRIVATE')), chunk('IDAT', f.compressed), chunk('IEND', Buffer.alloc(0))]),
    Buffer.concat([PNG, chunk('IHDR', f.header), chunk('IDAT', f.compressed), chunk('IHDR', f.header), chunk('IEND', Buffer.alloc(0))]),
    Buffer.concat([PNG, chunk('IHDR', f.header), ...Array(4096).fill(chunk('IDAT', Buffer.alloc(0))), chunk('IEND', Buffer.alloc(0))])];
  for (const [width, height] of [[8193, 1], [4001, 4000], [0, 1]]) {
    const header = Buffer.from(f.header); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
    invalid.push(f.pack(f.compressed, header));
  }
  for (const [offset, value] of [[8, 16], [9, 2], [10, 1], [11, 1], [12, 1]]) {
    const header = Buffer.from(f.header); header[offset] = value; invalid.push(f.pack(f.compressed, header));
  }
  for (const value of invalid) await assert.rejects(validateSanitizedEvidenceImageAsync(value as Uint8Array), safeError);
});

test('streaming validation rejects truncated, trailing and concatenated zlib streams, including split IDAT', async () => {
  const f = fixture(2, 2);
  const variants = [f.compressed.subarray(0, -1), Buffer.alloc(0),
    Buffer.concat([f.compressed, Buffer.from('PRIVATE TRAILER')]),
    Buffer.concat([f.compressed, deflateSync(Buffer.alloc(0))]),
    Buffer.concat([f.compressed, f.compressed])];
  for (const data of variants) {
    await assert.rejects(validateSanitizedEvidenceImageAsync(f.pack(data)), safeError);
    if (data.length >= 5) await assert.rejects(validateSanitizedEvidenceImageAsync(f.pack(data, f.header, true)), safeError);
  }
});

test('streaming validation requires exact raster length and checks every row filter across output boundaries', async () => {
  const f = fixture(), invalidFilter = Buffer.from(f.raster);
  invalidFilter[(f.width * 4 + 1) * 1000] = 5;
  for (const raster of [f.raster.subarray(0, -1), Buffer.concat([f.raster, Buffer.from([0])]), invalidFilter]) {
    await assert.rejects(validateSanitizedEvidenceImageAsync(f.pack(deflateSync(raster))), safeError);
  }
  const tiny = fixture(1, 1);
  await assert.rejects(validateSanitizedEvidenceImageAsync(tiny.pack(deflateSync(Buffer.alloc(2 * 1024 * 1024)))), safeError);
});

test('async image and asset parsers freeze all caller-controlled scalars and bytes before yielding', async () => {
  const f = fixture(), expected = f.pack(), input = Buffer.from(expected);
  const pendingValidation = validateSanitizedEvidenceImageAsync(input); input.fill(0);
  const validated = await pendingValidation; assert.deepEqual(Buffer.from(validated.bytes), expected);
  const image = { ...validated, mediaType: 'image/png' as const, processingVersion: 'evidence-png-v1' as const };
  const pendingImage = parseSanitizedEvidenceImageAsync(image);
  image.width = 1; image.sha256 = '0'.repeat(64); image.bytes.fill(0);
  const parsedImage = await pendingImage;
  assert.equal(parsedImage.width, f.width); assert.deepEqual(Buffer.from(parsedImage.bytes), expected);
  const owned = asset(Buffer.from(expected)), pendingAsset = parseEvidenceAssetAsync(owned);
  owned.descriptor.caseId = 'changed'; owned.descriptor.sha256 = '0'.repeat(64); owned.bytes.fill(0);
  const parsedAsset = await pendingAsset;
  assert.equal(parsedAsset.descriptor.caseId, 'case-a'); assert.deepEqual(Buffer.from(parsedAsset.bytes), expected);
  await assert.rejects(parseEvidenceAssetAsync({ ...parsedAsset, descriptor: { ...parsedAsset.descriptor, width: 1 } }));
  await assert.rejects(parseSanitizedEvidenceImageAsync({ ...parsedImage, mediaType: 'image/png',
    processingVersion: 'evidence-png-v1', sha256: '0'.repeat(64) }));
});

test('batch parser snapshots later images before awaiting the first and validates one stream at a time', async () => {
  const f = fixture(), expected = f.pack(), inputs = [asset(Buffer.from(expected)), asset(Buffer.from(expected), 'photo-b')];
  let zlibResources = 0;
  const hook = createHook({ init(_id, type) { if (type === 'ZLIB') zlibResources++; } });
  hook.enable();
  try {
    const pending = parseEvidenceAssetsAsync(inputs);
    assert.equal(zlibResources, 1);
    inputs[1].bytes.fill(0); inputs[1].descriptor.evidenceId = 'changed'; inputs.pop();
    const parsed = await pending;
    assert.equal(zlibResources, 2); assert.equal(parsed.length, 2);
    assert.equal(parsed[1].descriptor.evidenceId, 'photo-b'); assert.deepEqual(Buffer.from(parsed[1].bytes), expected);
  } finally { hook.disable(); }
  const invalidRaster = Buffer.from(f.raster); invalidRaster[0] = 5;
  const invalid = f.pack(deflateSync(invalidRaster));
  zlibResources = 0; hook.enable();
  try {
    await assert.rejects(validateSanitizedEvidenceImagesAsync([invalid, expected]), safeError);
    assert.equal(zlibResources, 1, 'A refused first image must not start later decompression.');
  } finally { hook.disable(); }
});

test('batch parser rejects aggregate encoded/pixel budgets before starting any zlib work', async () => {
  const f = fixture(), first = asset(f.pack()), second = asset(f.pack(), 'photo-b');
  first.descriptor.width = second.descriptor.width = 4000;
  first.descriptor.height = second.descriptor.height = 3000;
  let streams = 0;
  const hook = createHook({ init(_id, type) { if (type === 'ZLIB') streams++; } });
  hook.enable();
  try {
    await assert.rejects(parseEvidenceAssetsAsync([first, second]));
    assert.equal(streams, 0);
  } finally { hook.disable(); }
});
