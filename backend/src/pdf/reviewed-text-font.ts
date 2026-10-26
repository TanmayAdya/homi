import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { Readable, Transform } from 'node:stream';
import { PDFDocument, StandardFonts, type PDFFont } from 'pdf-lib';

const FONT_SHA256 = 'd27dcda3225034eed81d12e98c2e2cf3a23c5405856927ab6b69e6cfa449ccad';
const METRICS_SHA256 = '2c99168acf3251f5a362d79d38cb0b082913786e89b2f5120a5d4448d5f96524';
export const REVIEWED_TEXT_RENDERING_VERSION = `exact-han-noto-2.004-4:${FONT_SHA256}:${METRICS_SHA256}`;
const HELVETICA_BOUNDS = Object.freeze({ left: -0.166, bottom: -0.225, right: 1, top: 0.931 });
const UNSUPPORTED_SCALAR = /[\p{Mark}\p{Control}\p{Format}\p{Surrogate}\p{Private_Use}\p{Unassigned}]/u;

export interface TextInkBounds {
  readonly left: number;
  readonly bottom: number;
  readonly right: number;
  readonly top: number;
}
export interface ReviewedTextFont {
  readonly font: PDFFont;
  readonly bounds: TextInkBounds;
  supports(text: string): boolean;
  inkBounds(text: string): TextInkBounds;
}

interface FontAssets { bytes: Buffer; metrics: Buffer; fontBuffer: ArrayBuffer }
let assets: Promise<FontAssets> | undefined;
async function verifiedAssets(): Promise<FontAssets> {
  assets ??= Promise.all([
    readFile(new URL('../../assets/fonts/SafeAtHomeCJK-Regular.otf', import.meta.url)),
    readFile(new URL('../../assets/fonts/SafeAtHomeCJK-Regular.metrics.bin', import.meta.url)),
  ]).then(([bytes, metrics]) => {
    if (createHash('sha256').update(bytes).digest('hex') !== FONT_SHA256
      || createHash('sha256').update(metrics).digest('hex') !== METRICS_SHA256
      || metrics.subarray(0, 8).toString('ascii') !== 'SAHCM001'
      || metrics.length !== 16 + metrics.readUInt32BE(8) * 10
      || metrics.readUInt32BE(12) !== 1000) {
      throw new Error('The reviewed PDF font assets could not be verified.');
    }
    const fontBuffer = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength
      ? bytes.buffer as ArrayBuffer
      : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    return { bytes, metrics, fontBuffer };
  });
  return assets;
}

type ParsedFont = import('@pdf-lib/fontkit').Font;

function withValidCffSubsetHeader(parsed: ParsedFont): ParsedFont {
  const createSubset = parsed.createSubset.bind(parsed);
  parsed.createSubset = () => {
    const subset = createSubset();
    const encodeStream = subset.encodeStream.bind(subset);
    subset.encodeStream = () => {
      const prefix = Buffer.alloc(4);
      let received = 0;
      const repaired = new Transform({
        transform(chunk: Buffer, _encoding, callback) {
          let offset = 0;
          if (received < 4) {
            offset = Math.min(4 - received, chunk.length);
            chunk.copy(prefix, received, 0, offset);
            received += offset;
            if (received === 4) {
              if (prefix[0] !== 1 || prefix[1] !== 0 || prefix[2] !== 4) {
                callback(new Error('Unexpected reviewed CFF subset header.'));
                return;
              }
              prefix[3] = 4;
              this.push(prefix);
            }
          }
          if (offset < chunk.length) this.push(chunk.subarray(offset));
          callback();
        },
        flush(callback) {
          callback(received === 4 ? undefined : new Error('Incomplete reviewed CFF subset header.'));
        },
      });
      const source = encodeStream() as unknown as Readable;
      source.on('error', error => repaired.destroy(error));
      return source.pipe(repaired);
    };
    return subset;
  };
  return parsed;
}

export class ReviewedTextFontSession {
  #loaded: Promise<FontAssets & { parsed: ParsedFont }> | undefined;
  load(): Promise<FontAssets & { parsed: ParsedFont }> {
    this.#loaded ??= (async () => {
      const data = await verifiedAssets();
      const { default: fontkit } = await import('@pdf-lib/fontkit');
      const createFromBuffer = fontkit.create as unknown as (bytes: ArrayBuffer) => ParsedFont;
      return { ...data, parsed: withValidCffSubsetHeader(createFromBuffer(data.fontBuffer)) };
    })();
    return this.#loaded;
  }
}

export async function embedReviewedTextFont(
  document: PDFDocument, texts: readonly string[],
  session = new ReviewedTextFontSession(), role: 'form' | 'appendix' = 'appendix',
): Promise<ReviewedTextFont> {
  const latin = document.embedStandardFont(StandardFonts.Helvetica);
  const latinSet = new Set(latin.getCharacterSet());
  const latinSupports = (text: string) => Array.from(text).every(character =>
    !UNSUPPORTED_SCALAR.test(character) && latinSet.has(character.codePointAt(0)!));
  const needsCustom = texts.some(text => !latinSupports(text.replace(/[\r\n]/g, '')));
  if (!needsCustom) {
    return { font: latin, bounds: HELVETICA_BOUNDS, supports: latinSupports,
      inkBounds(text) {
        if (!latinSupports(text)) throw new Error('Unsupported reviewed text.');
        const characters = Array.from(text);
        const widths = characters.map(character => latin.widthOfTextAtSize(character, 1));
        const advance = widths.reduce((sum, width) => sum + width, 0);
        return { ...HELVETICA_BOUNDS, right: Math.max(advance,
          advance - (widths.at(-1) ?? 0) + HELVETICA_BOUNDS.right) };
      } };
  }
  const { bytes, metrics, parsed } = await session.load();
  document.registerFontkit({ create: () => parsed });
  const font = await document.embedFont(bytes, { subset: true,
    customName: `${role === 'form' ? 'SAHFRM' : 'SAHEVD'}+SafeAtHomeCJK-Regular` });
  font.encodeText(' ');
  const supports = (text: string) => Array.from(text).every(character =>
    !UNSUPPORTED_SCALAR.test(character) && parsed.hasGlyphForCodePoint(character.codePointAt(0)!));
  const units = metrics.readUInt32BE(12);
  const bounds = { left: parsed.bbox.minX / units, bottom: parsed.bbox.minY / units,
    right: parsed.bbox.maxX / units, top: parsed.bbox.maxY / units };
  return { font, bounds, supports,
    inkBounds(text) {
      if (!supports(text)) throw new Error('Unsupported reviewed text.');
      let advance = 0, left = 0, right = 0, bottom = 0, top = 0;
      for (const character of text) {
        const glyph = parsed.glyphForCodePoint(character.codePointAt(0)!);
        const offset = 16 + glyph.id * 10;
        if (offset + 10 > metrics.length) throw new Error('Invalid reviewed font metrics.');
        left = Math.min(left, advance + metrics.readInt16BE(offset + 2) / units);
        right = Math.max(right, advance + metrics.readInt16BE(offset + 6) / units);
        bottom = Math.min(bottom, metrics.readInt16BE(offset + 4) / units);
        top = Math.max(top, metrics.readInt16BE(offset + 8) / units);
        advance += metrics.readInt16BE(offset) / units;
      }
      return { left, bottom, right: Math.max(right, advance), top };
    } };
}
