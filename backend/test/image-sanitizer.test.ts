import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { deflateSync } from 'node:zlib';
import test from 'node:test';
import sharp from 'sharp';
import { ImageSanitizationError, MAX_IMAGE_INPUT_BYTES, MAX_SANITIZED_IMAGE_BYTES,
  sanitizeEvidenceImage, validateSanitizedEvidenceImage } from '../src/evidence/image-sanitizer.ts';

const PNG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
function chunk(type: string, data: Uint8Array): Buffer {
  const bytes = Buffer.alloc(data.length + 12); bytes.writeUInt32BE(data.length, 0);
  bytes.write(type, 4, 'ascii'); bytes.set(data, 8);
  let crc = 0xffffffff;
  for (const byte of bytes.subarray(4, -4)) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  bytes.writeUInt32BE((crc ^ 0xffffffff) >>> 0, bytes.length - 4); return bytes;
}
function pieces(bytes: Uint8Array): { type: string; data: Buffer }[] {
  const data = Buffer.from(bytes); const result = [];
  for (let offset = 8; offset < data.length;) {
    const length = data.readUInt32BE(offset);
    result.push({ type: data.subarray(offset + 4, offset + 8).toString('ascii'), data: data.subarray(offset + 8, offset + 8 + length) });
    offset += length + 12;
  }
  return result;
}
function repack(parts: { type: string; data: Buffer }[]): Buffer {
  return Buffer.concat([PNG, ...parts.map(part => chunk(part.type, part.data))]);
}
async function image(format: 'png' | 'jpeg' = 'png') {
  return sharp({ create: { width: 12, height: 8, channels: 3, background: { r: 240, g: 50, b: 10 } } })[format]().toBuffer();
}
function safeError(value: unknown): boolean {
  assert.ok(value instanceof ImageSanitizationError);
  assert.ok(!value.message.includes('PRIVATE')); return true;
}

test('JPEG and PNG become exact-sized canonical RGBA PNG with honest hashes', async () => {
  for (const format of ['jpeg', 'png'] as const) {
    const result = await sanitizeEvidenceImage(await image(format));
    assert.equal(result.mediaType, 'image/png'); assert.equal(result.processingVersion, 'evidence-png-v1');
    assert.equal(result.width, 12); assert.equal(result.height, 8);
    assert.equal(result.byteLength, result.bytes.length);
    assert.equal(result.sha256, createHash('sha256').update(result.bytes).digest('hex'));
    assert.deepEqual(pieces(result.bytes).map(piece => piece.type), ['IHDR', 'IDAT', 'IEND']);
    const metadata = await sharp(result.bytes).metadata();
    assert.equal(metadata.channels, 4); assert.equal(metadata.exif, undefined); assert.equal(metadata.icc, undefined);
    assert.deepEqual(validateSanitizedEvidenceImage(result.bytes), { width: 12, height: 8, sha256: result.sha256, byteLength: result.byteLength });
  }
});

test('EXIF orientation rotates pixels and removes EXIF/GPS/XMP/private metadata', async () => {
  const bytes = await sharp({ create: { width: 12, height: 8, channels: 3, background: 'red' } })
    .withMetadata({ orientation: 6 }).withExifMerge({ IFD0: { Artist: 'PRIVATE ARTIST' },
      IFD3: { GPSLatitudeRef: 'N', GPSLatitude: '37/1 20/1 0/1', GPSLongitudeRef: 'W', GPSLongitude: '121/1 50/1 0/1' } })
    .withXmp('<x:xmpmeta xmlns:x="adobe:ns:meta/">PRIVATE LOCATION</x:xmpmeta>').jpeg().toBuffer();
  assert.ok((await sharp(bytes).metadata()).exif);
  const result = await sanitizeEvidenceImage(bytes);
  assert.equal(result.width, 8); assert.equal(result.height, 12);
  const metadata = await sharp(result.bytes).metadata();
  for (const key of ['exif', 'icc', 'xmp', 'iptc', 'orientation'] as const) assert.equal(metadata[key], undefined);
  assert.ok(!Buffer.from(result.bytes).includes(Buffer.from('PRIVATE')));
});

test('text and compressed text chunks are removed without expanding their payload', async () => {
  const parts = pieces(await image());
  const source = repack([parts[0],
    { type: 'tEXt', data: Buffer.from('Location\0PRIVATE ADDRESS') },
    { type: 'zTXt', data: Buffer.concat([Buffer.from('Comment\0\0'), deflateSync(Buffer.alloc(2 * 1024 * 1024, 65))]) },
    { type: 'iTXt', data: Buffer.from('Location\0\0\0\0\0PRIVATE GPS') }, ...parts.slice(1)]);
  const result = await sanitizeEvidenceImage(source);
  assert.deepEqual(pieces(result.bytes).map(piece => piece.type), ['IHDR', 'IDAT', 'IEND']);
});

test('unsupported content, paths, URLs and malformed images fail with safe errors', async () => {
  const valid = await image();
  for (const input of [null, 'https://example.org/PRIVATE.png', '/PRIVATE/image.png', new Uint8Array(),
    Buffer.from('<svg>PRIVATE</svg>'), Buffer.from('%PDF-PRIVATE'), Buffer.from('GIF89aPRIVATE'),
    valid.subarray(0, valid.length - 4), Buffer.concat([valid, Buffer.from('PRIVATE TRAILER')]),
    Buffer.from([255, 216, 255, 217])]) {
    await assert.rejects(sanitizeEvidenceImage(input as never), safeError);
  }
  const corrupt = Buffer.from(valid); corrupt[corrupt.length - 1] ^= 1;
  await assert.rejects(sanitizeEvidenceImage(corrupt), safeError);
});

test('byte and dimension bounds reject before raster decode, including a tiny compressed bomb header', async () => {
  await assert.rejects(sanitizeEvidenceImage(Buffer.alloc(MAX_IMAGE_INPUT_BYTES + 1)), error =>
    error instanceof ImageSanitizationError && error.code === 'IMAGE_TOO_LARGE');
  const source = pieces(await image());
  for (const [width, height] of [[8193, 1], [4001, 4000], [0, 1]]) {
    const header = Buffer.from(source[0].data); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
    await assert.rejects(sanitizeEvidenceImage(repack([{ type: 'IHDR', data: header }, ...source.slice(1)])), safeError);
  }
});

test('animated PNG and MPO are rejected rather than silently selecting their first image', async () => {
  const parts = pieces(await image());
  for (const type of ['acTL', 'fcTL', 'fdAT']) {
    await assert.rejects(sanitizeEvidenceImage(repack([parts[0], { type, data: Buffer.alloc(8) }, ...parts.slice(1)])), error =>
      error instanceof ImageSanitizationError && error.code === 'UNSUPPORTED_IMAGE');
  }
  const jpeg = await image('jpeg');
  const mpo = Buffer.concat([jpeg.subarray(0, 2), Buffer.from([255, 226, 0, 6]), Buffer.from('MPF\0'), jpeg.subarray(2)]);
  await assert.rejects(sanitizeEvidenceImage(mpo), error => error instanceof ImageSanitizationError && error.code === 'UNSUPPORTED_IMAGE');
});

test('compressed colour profiles cannot expand beyond their independent limit', async () => {
  const parts = pieces(await image());
  const badProfile = Buffer.concat([Buffer.from('profile\0\0'), deflateSync(Buffer.alloc(1024 * 1024 + 1))]);
  await assert.rejects(sanitizeEvidenceImage(repack([parts[0], { type: 'iCCP', data: badProfile }, ...parts.slice(1)])), safeError);
  const profile = { type: 'iCCP', data: Buffer.concat([Buffer.from('profile\0\0'), deflateSync(Buffer.from('PRIVATE'))]) };
  await assert.rejects(sanitizeEvidenceImage(repack([parts[0], profile, profile, ...parts.slice(1)])), safeError);
});

test('many tiny chunks cannot consume unbounded parser objects or repeat metadata decompression', async () => {
  const parts = pieces(await image());
  const source = repack([parts[0], ...Array(4096).fill({ type: 'tEXt', data: Buffer.alloc(0) }), ...parts.slice(1)]);
  await assert.rejects(sanitizeEvidenceImage(source), error => error instanceof ImageSanitizationError && error.code === 'IMAGE_TOO_LARGE');
});

test('canonical verification rejects metadata, CRC errors, oversized data and noncanonical pixel streams', async () => {
  const canonical = await sanitizeEvidenceImage(await image()); const parts = pieces(canonical.bytes);
  assert.throws(() => validateSanitizedEvidenceImage(Buffer.alloc(MAX_SANITIZED_IMAGE_BYTES + 1)), safeError);
  assert.throws(() => validateSanitizedEvidenceImage(repack([parts[0], { type: 'tEXt', data: Buffer.from('PRIVATE') }, ...parts.slice(1)])), safeError);
  const invalid = Buffer.from(canonical.bytes); invalid[invalid.length - 1] ^= 1;
  assert.throws(() => validateSanitizedEvidenceImage(invalid), safeError);
  for (const raster of [Buffer.alloc((12 * 4 + 1) * 8 + 1), Buffer.alloc(1), Buffer.alloc((12 * 4 + 1) * 8, 255)]) {
    assert.throws(() => validateSanitizedEvidenceImage(repack([parts[0], { type: 'IDAT', data: deflateSync(raster) }, parts.at(-1)!])), safeError);
  }
  const trailing = Buffer.concat([parts[1].data, Buffer.from('PRIVATE TRAILER')]);
  assert.throws(() => validateSanitizedEvidenceImage(repack([parts[0], { type: 'IDAT', data: trailing }, parts.at(-1)!])), safeError);
});

test('caller mutation after invocation cannot replace image pixels or metadata', async () => {
  const bytes = await image();
  const pending = sanitizeEvidenceImage(bytes); bytes.fill(0);
  const result = await pending;
  assert.equal(result.width, 12); assert.equal(result.height, 8);
});

test('sanitizer returns an exact private allocation without sharing input, pooled backing storage or other results', async () => {
  const input = await image(), original = Buffer.from(input);
  const first = await sanitizeEvidenceImage(input), second = await sanitizeEvidenceImage(input);
  assert.equal(first.bytes.constructor, Uint8Array);
  assert.equal(first.bytes.byteOffset, 0); assert.equal(first.bytes.buffer.byteLength, first.byteLength);
  assert.notEqual(first.bytes.buffer, input.buffer); assert.notEqual(first.bytes.buffer, second.bytes.buffer);
  const expected = createHash('sha256').update(second.bytes).digest('hex');
  first.bytes.fill(0);
  assert.deepEqual(input, original); assert.equal(createHash('sha256').update(second.bytes).digest('hex'), expected);
  assert.equal(second.sha256, expected);
});
