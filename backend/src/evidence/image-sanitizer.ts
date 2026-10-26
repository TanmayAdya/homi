import { createHash } from 'node:crypto';
import { createInflate, inflateSync } from 'node:zlib';
import { Readable } from 'node:stream';
import sharp from 'sharp';
import { MAX_SELECTED_EVIDENCE, type SanitizedEvidenceImage } from './types.ts';

export const MAX_IMAGE_INPUT_BYTES = 8 * 1024 * 1024;
export const MAX_IMAGE_PIXELS = 16_000_000;
export const MAX_IMAGE_EDGE = 8192;
export const MAX_SANITIZED_IMAGE_BYTES = 24 * 1024 * 1024;
export const IMAGE_PROCESSING_VERSION = 'evidence-png-v1' as const;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const MAX_PROFILE_BYTES = 1024 * 1024;
const MAX_PNG_CHUNKS = 4096;

export class ImageSanitizationError extends Error {
  readonly code: 'INVALID_IMAGE' | 'IMAGE_TOO_LARGE' | 'UNSUPPORTED_IMAGE';
  constructor(code: ImageSanitizationError['code'] = 'INVALID_IMAGE') {
    super(code === 'IMAGE_TOO_LARGE' ? 'The image exceeds the supported size limits.'
      : code === 'UNSUPPORTED_IMAGE' ? 'Provide a single JPEG or PNG image.'
        : 'The image could not be safely prepared.');
    this.name = 'ImageSanitizationError';
    this.code = code;
  }
}

function check(condition: unknown, code: ImageSanitizationError['code'] = 'INVALID_IMAGE'): asserts condition {
  if (!condition) throw new ImageSanitizationError(code);
}

function dimensions(width: number, height: number): void {
  check(Number.isSafeInteger(width) && width > 0 && Number.isSafeInteger(height) && height > 0);
  check(width <= MAX_IMAGE_EDGE && height <= MAX_IMAGE_EDGE && width * height <= MAX_IMAGE_PIXELS, 'IMAGE_TOO_LARGE');
}

function boundedInflate(input: Buffer, maximum: number): Buffer {
  const result = inflateSync(input, { maxOutputLength: maximum, info: true }) as unknown as {
    buffer: Buffer; engine: { bytesWritten: number };
  };
  check(result.engine.bytesWritten === input.length);
  return result.buffer;
}

const CRC_TABLE = Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = CRC_TABLE[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

interface Chunk { type: string; bytes: Buffer; data: Buffer }
function chunks(bytes: Buffer): Chunk[] {
  check(bytes.length >= 33 && bytes.subarray(0, 8).equals(PNG_SIGNATURE));
  const result: Chunk[] = [];
  let offset = 8;
  while (offset < bytes.length) {
    check(result.length < MAX_PNG_CHUNKS, 'IMAGE_TOO_LARGE');
    check(offset + 12 <= bytes.length);
    const length = bytes.readUInt32BE(offset);
    check(length <= bytes.length - offset - 12);
    const end = offset + 12 + length;
    const type = bytes.subarray(offset + 4, offset + 8).toString('ascii');
    check(/^[A-Za-z]{4}$/.test(type));
    check(crc32(bytes.subarray(offset + 4, end - 4)) === bytes.readUInt32BE(end - 4));
    result.push({ type, bytes: bytes.subarray(offset, end), data: bytes.subarray(offset + 8, end - 4) });
    offset = end;
    if (type === 'IEND') break;
  }
  check(offset === bytes.length && result.length >= 3 && result[0].type === 'IHDR'
    && result[0].data.length === 13 && result.at(-1)!.type === 'IEND' && result.at(-1)!.data.length === 0
    && result.filter(chunk => chunk.type === 'IHDR').length === 1 && result.some(chunk => chunk.type === 'IDAT'));
  dimensions(result[0].data.readUInt32BE(0), result[0].data.readUInt32BE(4));
  return result;
}

function preparePng(bytes: Buffer): Buffer {
  const parsed = chunks(bytes);
  check(!parsed.some(chunk => ['acTL', 'fcTL', 'fdAT'].includes(chunk.type)), 'UNSUPPORTED_IMAGE');
  check(parsed.filter(chunk => chunk.type === 'iCCP').length <= 1 && parsed.filter(chunk => chunk.type === 'eXIf').length <= 1);
  for (const chunk of parsed) {
    if (chunk.type === 'iCCP') {
      const end = chunk.data.indexOf(0);
      check(end >= 1 && end <= 79 && chunk.data[end + 1] === 0);
      boundedInflate(chunk.data.subarray(end + 2), MAX_PROFILE_BYTES);
    }
    if (chunk.type === 'eXIf') check(chunk.data.length <= 64 * 1024, 'IMAGE_TOO_LARGE');
  }
  return Buffer.concat([PNG_SIGNATURE, ...parsed.filter(chunk => !['tEXt', 'zTXt', 'iTXt'].includes(chunk.type)).map(chunk => chunk.bytes)]);
}

function checkJpeg(bytes: Buffer): void {
  check(bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216
    && bytes[bytes.length - 2] === 255 && bytes[bytes.length - 1] === 217);
  let offset = 2;
  while (offset < bytes.length - 2) {
    check(bytes[offset++] === 255);
    while (bytes[offset] === 255) offset++;
    const marker = bytes[offset++];
    if (marker === 218) return;
    check(marker !== undefined && marker !== 0 && marker !== 216 && marker !== 217 && offset + 2 <= bytes.length);
    const length = bytes.readUInt16BE(offset);
    check(length >= 2 && offset + length <= bytes.length);
    if (marker === 226) check(!bytes.subarray(offset + 2, offset + 6).equals(Buffer.from('MPF\0')), 'UNSUPPORTED_IMAGE');
    offset += length;
  }
  throw new ImageSanitizationError();
}

export function validateSanitizedEvidenceImage(input: Uint8Array): {
  width: number; height: number; sha256: string; byteLength: number;
} {
  try {
    check(input instanceof Uint8Array && input.byteLength > 0);
    check(input.byteLength <= MAX_SANITIZED_IMAGE_BYTES, 'IMAGE_TOO_LARGE');
    const bytes = Buffer.from(input);
    const parsed = chunks(bytes);
    check(parsed.every(chunk => ['IHDR', 'IDAT', 'IEND'].includes(chunk.type)));
    check(parsed.slice(1, -1).every(chunk => chunk.type === 'IDAT'));
    const header = parsed[0].data;
    check(header[8] === 8 && header[9] === 6 && header[10] === 0 && header[11] === 0 && header[12] === 0);
    const width = header.readUInt32BE(0); const height = header.readUInt32BE(4);
    const rowBytes = width * 4 + 1;
    const raster = boundedInflate(Buffer.concat(parsed.slice(1, -1).map(chunk => chunk.data)), rowBytes * height);
    check(raster.length === rowBytes * height);
    for (let row = 0; row < height; row++) check(raster[row * rowBytes] <= 4);
    return { width, height, sha256: createHash('sha256').update(bytes).digest('hex'), byteLength: bytes.length };
  } catch (error) {
    if (error instanceof ImageSanitizationError) throw error;
    throw new ImageSanitizationError();
  }
}

export interface ValidatedSanitizedEvidenceImage {
  bytes: Uint8Array;
  width: number;
  height: number;
  sha256: string;
  byteLength: number;
}

interface PreparedCanonicalImage {
  bytes: Uint8Array;
  width: number;
  height: number;
  compressed: Buffer[];
  compressedBytes: number;
}

export function inspectCanonicalEvidencePng(input: Uint8Array): Omit<PreparedCanonicalImage, 'bytes'> {
  check(input instanceof Uint8Array && input.byteLength > 0);
  check(input.byteLength <= MAX_SANITIZED_IMAGE_BYTES, 'IMAGE_TOO_LARGE');
  const view = Buffer.from(input.buffer, input.byteOffset, input.byteLength);
  const parsed = chunks(view);
  check(parsed.every(chunk => ['IHDR', 'IDAT', 'IEND'].includes(chunk.type)));
  check(parsed.slice(1, -1).every(chunk => chunk.type === 'IDAT'));
  const header = parsed[0].data;
  check(header[8] === 8 && header[9] === 6 && header[10] === 0 && header[11] === 0 && header[12] === 0);
  const compressed = parsed.slice(1, -1).map(chunk => chunk.data);
  return { width: header.readUInt32BE(0), height: header.readUInt32BE(4), compressed,
    compressedBytes: compressed.reduce((total, chunk) => total + chunk.length, 0) };
}

function prepareCanonicalImage(input: Uint8Array): PreparedCanonicalImage {
  check(input instanceof Uint8Array && input.byteLength > 0);
  check(input.byteLength <= MAX_SANITIZED_IMAGE_BYTES, 'IMAGE_TOO_LARGE');
  const bytes = Uint8Array.from(input);
  return { bytes, ...inspectCanonicalEvidencePng(bytes) };
}

async function validatePreparedCanonicalImage(prepared: PreparedCanonicalImage): Promise<ValidatedSanitizedEvidenceImage> {
  const rowBytes = prepared.width * 4 + 1, expectedBytes = rowBytes * prepared.height;
  const inflater = createInflate({ chunkSize: 64 * 1024 });
  const closed = new Promise<void>(resolve => inflater.once('close', resolve));
  const source = Readable.from(prepared.compressed, { objectMode: false });
  let total = 0;
  try {
    source.pipe(inflater);
    for await (const output of inflater) {
      check(Buffer.isBuffer(output));
      check(total + output.length <= expectedBytes);
      const firstFilter = (rowBytes - total % rowBytes) % rowBytes;
      for (let offset = firstFilter; offset < output.length; offset += rowBytes) check(output[offset] <= 4);
      total += output.length;
    }
    check(total === expectedBytes && inflater.bytesWritten === prepared.compressedBytes);
    return { bytes: prepared.bytes, width: prepared.width, height: prepared.height,
      byteLength: prepared.bytes.length, sha256: createHash('sha256').update(prepared.bytes).digest('hex') };
  } finally {
    source.destroy(); inflater.destroy();
    await closed;
  }
}

export async function validateSanitizedEvidenceImageAsync(input: Uint8Array): Promise<ValidatedSanitizedEvidenceImage> {
  try { return await validatePreparedCanonicalImage(prepareCanonicalImage(input)); }
  catch (error) {
    if (error instanceof ImageSanitizationError) throw error;
    throw new ImageSanitizationError();
  }
}

export async function validateSanitizedEvidenceImagesAsync(
  inputs: ReadonlyArray<Uint8Array>,
): Promise<ValidatedSanitizedEvidenceImage[]> {
  try {
    check(Array.isArray(inputs) && inputs.length <= MAX_SELECTED_EVIDENCE);
    const prepared = inputs.map(prepareCanonicalImage);
    const results: ValidatedSanitizedEvidenceImage[] = [];
    for (const image of prepared) results.push(await validatePreparedCanonicalImage(image));
    return results;
  } catch (error) {
    if (error instanceof ImageSanitizationError) throw error;
    throw new ImageSanitizationError();
  }
}

export async function sanitizeEvidenceImage(input: Uint8Array): Promise<SanitizedEvidenceImage> {
  try {
    check(input instanceof Uint8Array && input.byteLength > 0);
    check(input.byteLength <= MAX_IMAGE_INPUT_BYTES, 'IMAGE_TOO_LARGE');
    let bytes: Buffer = Buffer.from(input);
    const png = bytes.subarray(0, 8).equals(PNG_SIGNATURE);
    const jpeg = bytes[0] === 255 && bytes[1] === 216;
    check(png || jpeg, 'UNSUPPORTED_IMAGE');
    if (png) bytes = preparePng(bytes); else checkJpeg(bytes);
    const options = { failOn: 'warning' as const, limitInputPixels: MAX_IMAGE_PIXELS,
      unlimited: false, sequentialRead: true, pages: 1 };
    const metadata = await sharp(bytes, options).metadata();
    check(metadata.format === (png ? 'png' : 'jpeg') && (metadata.pages === undefined || metadata.pages === 1), 'UNSUPPORTED_IMAGE');
    dimensions(metadata.width, metadata.height);
    const { data, info } = await sharp(bytes, options).autoOrient().toColourspace('srgb').ensureAlpha()
      .png({ compressionLevel: 6, palette: false, progressive: false }).timeout({ seconds: 5 }).toBuffer({ resolveWithObject: true });
    dimensions(info.width, info.height);
    check(data.byteLength <= MAX_SANITIZED_IMAGE_BYTES, 'IMAGE_TOO_LARGE');
    const retained = chunks(data).filter(chunk => ['IHDR', 'IDAT', 'IEND'].includes(chunk.type));
    const canonical = new Uint8Array(PNG_SIGNATURE.length + retained.reduce((sum, chunk) => sum + chunk.bytes.length, 0));
    canonical.set(PNG_SIGNATURE); let offset = PNG_SIGNATURE.length;
    for (const chunk of retained) { canonical.set(chunk.bytes, offset); offset += chunk.bytes.length; }
    const verified = await validatePreparedCanonicalImage({ bytes: canonical, ...inspectCanonicalEvidencePng(canonical) });
    check(verified.width === info.width && verified.height === info.height);
    return { mediaType: 'image/png', ...verified, processingVersion: IMAGE_PROCESSING_VERSION };
  } catch (error) {
    if (error instanceof ImageSanitizationError) throw error;
    throw new ImageSanitizationError();
  }
}
