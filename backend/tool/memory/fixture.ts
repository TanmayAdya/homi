import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, open, readdir } from 'node:fs/promises';
import { basename, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import sharp from 'sharp';
import { sanitizeEvidenceImage, validateSanitizedEvidenceImage } from '../../src/evidence/image-sanitizer.ts';

export const FIXTURE_NAMES = ['solid.png', 'alpha.png', 'six.png', 'near24.png', 'near8.jpg', 'full16mp.jpg', 'oversize.png'] as const;
export type FixtureName = typeof FIXTURE_NAMES[number];
export interface FixtureMetadata { width: number; height: number; bytes: number; sha256: string }
const MIB = 1024 * 1024;

export async function validateFixtureDirectory(directory: string): Promise<string> {
  if (typeof directory !== 'string' || directory !== resolve(directory)
    || !/^sah-memory-[A-Za-z0-9_-]+$/.test(basename(directory))) throw new Error('Invalid fixture directory.');
  const stat = await lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0
    || (process.getuid && stat.uid !== process.getuid())) throw new Error('Invalid fixture directory.');
  return directory;
}

async function readFixed(directory: string, name: string, limit: number): Promise<Buffer> {
  const handle = await open(join(directory, name), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.nlink !== 1 || (stat.mode & 0o077) !== 0 || stat.size < 1 || stat.size > limit
      || (process.getuid && stat.uid !== process.getuid())) throw new Error('Invalid fixture file.');
    const bytes = Buffer.alloc(stat.size + 1);
    let length = 0;
    while (length < bytes.length) {
      const read = await handle.read(bytes, length, bytes.length - length, length);
      if (!read.bytesRead) break;
      length += read.bytesRead;
    }
    if (length !== stat.size) throw new Error('Fixture changed while reading.');
    return bytes.subarray(0, length);
  } finally { await handle.close(); }
}

export async function readFixture(directory: string, name: FixtureName): Promise<{ bytes: Buffer; metadata: FixtureMetadata }> {
  await validateFixtureDirectory(directory);
  if (!FIXTURE_NAMES.includes(name)) throw new Error('Unknown fixture.');
  const manifest = JSON.parse((await readFixed(directory, 'manifest.json', 16 * 1024)).toString('utf8'));
  if (!manifest || manifest.schemaVersion !== '1' || Object.keys(manifest).sort().join(',') !== 'files,schemaVersion'
    || !manifest.files || Object.keys(manifest.files).sort().join(',') !== [...FIXTURE_NAMES].sort().join(',')) {
    throw new Error('Invalid fixture manifest.');
  }
  const metadata = manifest.files[name];
  if (!metadata || Object.keys(metadata).sort().join(',') !== 'bytes,height,sha256,width'
    || ![metadata.width, metadata.height, metadata.bytes].every(value => Number.isSafeInteger(value) && value > 0)
    || metadata.width > 8192 || metadata.height > 8192 || !/^[a-f0-9]{64}$/.test(metadata.sha256)) {
    throw new Error('Invalid fixture metadata.');
  }
  const bytes = await readFixed(directory, name, name.endsWith('.jpg') ? 8 * MIB : 24 * MIB);
  if (bytes.length !== metadata.bytes || createHash('sha256').update(bytes).digest('hex') !== metadata.sha256) {
    throw new Error('Fixture content changed.');
  }
  return { bytes, metadata };
}

function canonicalPng(bytes: Buffer): Buffer {
  const parts: Buffer[] = [bytes.subarray(0, 8)];
  for (let offset = 8; offset < bytes.length;) {
    const size = bytes.readUInt32BE(offset) + 12;
    if (size < 12 || offset + size > bytes.length) throw new Error('Invalid generated PNG.');
    if (['IHDR', 'IDAT', 'IEND'].includes(bytes.toString('ascii', offset + 4, offset + 8))) parts.push(bytes.subarray(offset, offset + size));
    offset += size;
  }
  return Buffer.concat(parts);
}
async function png(width: number, height: number, pixels?: Buffer): Promise<Buffer> {
  const source = pixels ? sharp(pixels, { raw: { width, height, channels: 4 } })
    : sharp({ create: { width, height, channels: 4, background: { r: 45, g: 87, b: 111, alpha: 1 } } });
  return canonicalPng(await source.png({ compressionLevel: 6, palette: false, progressive: false }).toBuffer());
}
function randomPixels(width: number, height: number, noiseRows = height): Buffer {
  const pixels = Buffer.alloc(width * height * 4);
  let random = 0x4a617661;
  for (let index = 0; index < pixels.length; index += 4) {
    if (index < width * noiseRows * 4) {
      random ^= random << 13; random ^= random >>> 17; random ^= random << 5;
      pixels[index] = random & 255; pixels[index + 1] = (random >>> 8) & 255; pixels[index + 2] = (random >>> 16) & 255;
    }
    pixels[index + 3] = 255;
  }
  return pixels;
}

export async function prepareFixtures(directory: string) {
  await validateFixtureDirectory(directory);
  if ((await readdir(directory)).length !== 0) throw new Error('Fixture directory must be empty.');
  const files = {} as Record<FixtureName, FixtureMetadata>;
  let totalBytes = 0;
  const save = async (name: FixtureName, bytes: Buffer, width: number, height: number, canonical = true) => {
    if (canonical) {
      const checked = validateSanitizedEvidenceImage(bytes);
      if (checked.width !== width || checked.height !== height) throw new Error('Generated dimensions differ.');
    }
    const handle = await open(join(directory, name), constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { await handle.writeFile(bytes); } finally { await handle.close(); }
    files[name] = { width, height, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
    totalBytes += bytes.length;
  };
  await save('solid.png', await png(4000, 4000), 4000, 4000);
  {
    const pixels = Buffer.alloc(4000 * 4000 * 4);
    for (let index = 0; index < pixels.length; index += 4) {
      pixels[index] = 80; pixels[index + 1] = 140; pixels[index + 2] = 190;
      pixels[index + 3] = (index / 4) % 256;
    }
    await save('alpha.png', await png(4000, 4000, pixels), 4000, 4000);
  }
  await save('six.png', await png(2000, 1333), 2000, 1333);
  {
    let low = 1, high = 4000, chosen: Buffer | undefined;
    while (low <= high) {
      const rows = Math.floor((low + high) / 2);
      const candidate = await png(4000, 4000, randomPixels(4000, 4000, rows));
      if (candidate.length <= 24 * MIB - 32 * 1024) { chosen = candidate; low = rows + 1; }
      else high = rows - 1;
    }
    if (!chosen || chosen.length < 23 * MIB) throw new Error('Near-limit PNG fixture was not achieved.');
    await save('near24.png', chosen, 4000, 4000);
  }
  {
    const pixels = randomPixels(2700, 2700);
    let low = 1, high = 100, chosen: Buffer | undefined;
    while (low <= high) {
      const quality = Math.floor((low + high) / 2);
      const candidate = await sharp(pixels, { raw: { width: 2700, height: 2700, channels: 4 } })
        .jpeg({ quality, chromaSubsampling: '4:4:4' }).toBuffer();
      if (candidate.length <= 8 * MIB) { chosen = candidate; low = quality + 1; }
      else high = quality - 1;
    }
    if (!chosen || chosen.length < 7.5 * MIB) throw new Error('Near-limit JPEG fixture was not achieved.');
    await save('near8.jpg', chosen, 2700, 2700, false);
  }
  {
    const width = 4000, height = 4000, pixels = Buffer.alloc(width * height * 4);
    let random = 0x12345678;
    for (let offset = 0; offset < pixels.length; offset += 4) {
      random ^= random << 13; random ^= random >>> 17; random ^= random << 5;
      const value = (random & 3) * 85;
      pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value; pixels[offset + 3] = 255;
    }
    const jpeg = await sharp(pixels, { raw: { width, height, channels: 4 } })
      .jpeg({ quality: 40, chromaSubsampling: '4:2:0' }).toBuffer();
    if (jpeg.length < 6 * MIB || jpeg.length > 8 * MIB) throw new Error('Full-pixel JPEG fixture was not achieved.');
    const canonical = await sanitizeEvidenceImage(jpeg);
    if (canonical.width !== width || canonical.height !== height || canonical.byteLength < 20 * MIB
      || canonical.byteLength > 24 * MIB) throw new Error('Full-pixel JPEG canonical output was not achieved.');
    await save('full16mp.jpg', jpeg, width, height, false);
  }
  await save('oversize.png', await png(4001, 4000), 4001, 4000, false);
  const manifest = Buffer.from(JSON.stringify({ schemaVersion: '1', files }));
  const handle = await open(join(directory, 'manifest.json'), constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { await handle.writeFile(manifest); } finally { await handle.close(); }
  return { schemaVersion: '1', status: 'prepared', files: FIXTURE_NAMES.length + 1, bytes: totalBytes + manifest.length };
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 3) { console.error('Synthetic fixture preparation failed.'); process.exitCode = 1; }
  else prepareFixtures(process.argv[2]).then(result => console.log(JSON.stringify(result)), () => {
    console.error('Synthetic fixture preparation failed.'); process.exitCode = 1;
  });
}
