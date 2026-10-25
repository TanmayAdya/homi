import sharp from 'sharp';
import { sanitizeEvidenceImage } from '../src/evidence/image-sanitizer.ts';

export async function createDemoEvidenceImage() {
  const pixels = Buffer.alloc(320 * 200 * 3);
  for (let y = 0; y < 200; y++) for (let x = 0; x < 320; x++) {
    const index = (y * 320 + x) * 3, step = y > 140 && x > 80 && x < 240;
    pixels[index] = step ? 64 : 225; pixels[index + 1] = step ? 100 : 235; pixels[index + 2] = step ? 130 : 240;
  }
  return sanitizeEvidenceImage(await sharp(pixels, { raw: { width: 320, height: 200, channels: 3 } }).png().toBuffer());
}
