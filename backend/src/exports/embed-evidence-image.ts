import { Readable } from 'node:stream';
import { createDeflate, createInflate, type Deflate } from 'node:zlib';
import type { PDFDocument, PDFRef } from 'pdf-lib';
import type { EvidenceAsset, EvidenceDescriptor } from '../evidence/types.ts';
import { parseEvidenceAssetAsync, parseEvidenceAssetsAsync } from '../evidence/validation.ts';
import { inspectCanonicalEvidencePng } from '../evidence/image-sanitizer.ts';
import { MAX_EXPORT_BYTES } from './validation.ts';

export class EvidenceEmbeddingError extends Error {
  readonly code: 'EVIDENCE_INVALID' | 'CONTENT_TOO_LARGE' | 'EMBED_FAILED';
  constructor(code: EvidenceEmbeddingError['code'] = 'EMBED_FAILED') {
    super(code === 'CONTENT_TOO_LARGE' ? 'The selected evidence exceeds the draft export size limit.'
      : code === 'EVIDENCE_INVALID' ? 'Reload and review the selected evidence before exporting.'
        : 'The evidence image could not be embedded.');
    this.name = 'EvidenceEmbeddingError'; this.code = code;
  }
}

interface EmbeddedEvidenceImage { ref: PDFRef; width: number; height: number; compressedBytes: number }
export interface PreparedEvidenceImageEmbedding {
  descriptor: EvidenceDescriptor;
  embed(document: PDFDocument, maximumCompressedBytes?: number): Promise<EmbeddedEvidenceImage>;
}

function check(value: unknown, code: EvidenceEmbeddingError['code'] = 'EVIDENCE_INVALID'): asserts value {
  if (!value) throw new EvidenceEmbeddingError(code);
}

function paeth(left: number, above: number, upperLeft: number): number {
  const estimate = left + above - upperLeft;
  const leftDistance = Math.abs(estimate - left), aboveDistance = Math.abs(estimate - above);
  const upperLeftDistance = Math.abs(estimate - upperLeft);
  return leftDistance <= aboveDistance && leftDistance <= upperLeftDistance ? left
    : aboveDistance <= upperLeftDistance ? above : upperLeft;
}

function unfilter(row: Buffer, previous: Buffer): void {
  const filter = row[0]; check(filter <= 4);
  for (let offset = 1; offset < row.length; offset++) {
    const left = offset > 4 ? row[offset - 4] : 0, above = previous[offset];
    const upperLeft = offset > 4 ? previous[offset - 4] : 0;
    const prediction = filter === 0 ? 0 : filter === 1 ? left : filter === 2 ? above
      : filter === 3 ? Math.floor((left + above) / 2) : paeth(left, above, upperLeft);
    row[offset] = (row[offset] + prediction) & 255;
  }
}

function writeChannel(stream: Deflate, bytes: Buffer): Promise<void> {
  return new Promise((resolve, reject) => stream.write(bytes, error => error ? reject(error) : resolve()));
}

async function compressCanonicalChannels(asset: EvidenceAsset, maximumBytes: number): Promise<{
  rgb: Buffer; alpha: Buffer | null;
}> {
  const prepared = inspectCanonicalEvidencePng(asset.bytes);
  check(prepared.width === asset.descriptor.width && prepared.height === asset.descriptor.height);
  const inflater = createInflate({ chunkSize: 64 * 1024 });
  const source = Readable.from(prepared.compressed, { objectMode: false, highWaterMark: 64 * 1024 });
  const streams: Array<ReturnType<typeof createInflate> | Deflate> = [inflater];
  const closures = [new Promise<void>(resolve => inflater.once('close', resolve))];
  let failure: unknown, compressedBytes = 0;
  const stop = (error: unknown): void => {
    failure ??= error; source.destroy();
    for (const stream of streams) stream.destroy();
  };
  source.once('error', stop);
  const channels: Array<{ stream: Deflate; result: Promise<Buffer | null> }> = [];
  const channel = () => {
    const stream = createDeflate({ level: 6, chunkSize: 64 * 1024 });
    streams.push(stream); closures.push(new Promise<void>(resolve => stream.once('close', resolve)));
    const result = (async () => {
      const chunks: Buffer[] = [];
      let length = 0;
      for await (const output of stream) {
        check(Buffer.isBuffer(output), 'EMBED_FAILED');
        compressedBytes += output.length;
        check(compressedBytes <= maximumBytes, 'CONTENT_TOO_LARGE');
        chunks.push(output); length += output.length;
      }
      if (failure) throw failure;
      return Buffer.concat(chunks, length);
    })().catch(error => { stop(error); return null; });
    const selected = { stream, result }; channels.push(selected); return selected;
  };
  const rgb = channel();
  let alpha: ReturnType<typeof channel> | undefined;
  const rowBytes = prepared.width * 4 + 1, expectedBytes = rowBytes * prepared.height;
  let row = Buffer.alloc(rowBytes), previous = Buffer.alloc(rowBytes);
  let rowOffset = 0, rows = 0, total = 0;
  try {
    source.pipe(inflater);
    for await (const output of inflater) {
      check(Buffer.isBuffer(output) && total + output.length <= expectedBytes);
      total += output.length;
      for (let offset = 0; offset < output.length;) {
        if (failure) throw failure;
        const copied = Math.min(rowBytes - rowOffset, output.length - offset);
        output.copy(row, rowOffset, offset, offset + copied);
        offset += copied; rowOffset += copied;
        if (rowOffset !== rowBytes) continue;
        unfilter(row, previous);
        const colour = Buffer.allocUnsafe(prepared.width * 3), opacity = Buffer.allocUnsafe(prepared.width);
        let opaque = true;
        for (let pixel = 0; pixel < prepared.width; pixel++) {
          const rgbaOffset = 1 + pixel * 4, rgbOffset = pixel * 3;
          colour[rgbOffset] = row[rgbaOffset]; colour[rgbOffset + 1] = row[rgbaOffset + 1];
          colour[rgbOffset + 2] = row[rgbaOffset + 2]; opacity[pixel] = row[rgbaOffset + 3];
          if (opacity[pixel] !== 255) opaque = false;
        }
        if (!opaque && !alpha) {
          alpha = channel();
          const priorOpaqueRow = Buffer.alloc(prepared.width, 255);
          for (let prior = 0; prior < rows; prior++) await writeChannel(alpha.stream, priorOpaqueRow);
        }
        await writeChannel(rgb.stream, colour);
        if (alpha) await writeChannel(alpha.stream, opacity);
        [previous, row] = [row, previous]; rowOffset = 0; rows++;
      }
    }
    check(total === expectedBytes && rows === prepared.height && rowOffset === 0
      && inflater.bytesWritten === prepared.compressedBytes);
    rgb.stream.end(); alpha?.stream.end();
    const colourBytes = await rgb.result, alphaBytes = alpha ? await alpha.result : null;
    if (failure) throw failure;
    check(colourBytes !== null && (!alpha || alphaBytes !== null), 'EMBED_FAILED');
    return { rgb: colourBytes, alpha: alphaBytes };
  } catch (error) {
    stop(error); throw failure;
  } finally {
    source.destroy(); for (const stream of streams) stream.destroy();
    await Promise.all(closures);
    await Promise.all(channels.map(selected => selected.result));
  }
}

async function embedOwnedEvidenceImage(
  document: PDFDocument, asset: EvidenceAsset, maximumCompressedBytes: number,
): Promise<EmbeddedEvidenceImage> {
  try {
    check(Number.isSafeInteger(maximumCompressedBytes) && maximumCompressedBytes >= 1
      && maximumCompressedBytes <= MAX_EXPORT_BYTES, 'CONTENT_TOO_LARGE');
    const { rgb, alpha } = await compressCanonicalChannels(asset, maximumCompressedBytes);
    const { width, height } = asset.descriptor;
    const mask = alpha === null ? undefined : document.context.register(document.context.stream(alpha, {
      Type: 'XObject', Subtype: 'Image', Filter: 'FlateDecode', Width: width, Height: height,
      BitsPerComponent: 8, ColorSpace: 'DeviceGray', Decode: [0, 1],
    }));
    const ref = document.context.register(document.context.stream(rgb, {
      Type: 'XObject', Subtype: 'Image', Filter: 'FlateDecode', Width: width, Height: height,
      BitsPerComponent: 8, ColorSpace: 'DeviceRGB', SMask: mask,
    }));
    return { ref, width, height, compressedBytes: rgb.length + (alpha?.length ?? 0) };
  } catch (error) {
    if (error instanceof EvidenceEmbeddingError) throw error;
    throw new EvidenceEmbeddingError();
  }
}

export async function prepareEvidenceImageEmbeddings(
  inputs: ReadonlyArray<EvidenceAsset>,
): Promise<PreparedEvidenceImageEmbedding[]> {
  let assets: EvidenceAsset[];
  try { assets = await parseEvidenceAssetsAsync(inputs); }
  catch { throw new EvidenceEmbeddingError('EVIDENCE_INVALID'); }
  return assets.map(asset => {
    let held: EvidenceAsset | null = asset;
    return {
      descriptor: structuredClone(asset.descriptor),
      async embed(document: PDFDocument, maximumCompressedBytes = MAX_EXPORT_BYTES): Promise<EmbeddedEvidenceImage> {
        let owned = held;
        check(owned !== null); held = null;
        try { return await embedOwnedEvidenceImage(document, owned, maximumCompressedBytes); }
        finally { owned = null; }
      },
    };
  });
}

export async function embedEvidenceImage(
  document: PDFDocument, input: EvidenceAsset, maximumCompressedBytes = MAX_EXPORT_BYTES,
): Promise<EmbeddedEvidenceImage> {
  check(Number.isSafeInteger(maximumCompressedBytes) && maximumCompressedBytes >= 1
    && maximumCompressedBytes <= MAX_EXPORT_BYTES, 'CONTENT_TOO_LARGE');
  let asset: EvidenceAsset;
  try { asset = await parseEvidenceAssetAsync(input); }
  catch { throw new EvidenceEmbeddingError('EVIDENCE_INVALID'); }
  return embedOwnedEvidenceImage(document, asset, maximumCompressedBytes);
}
