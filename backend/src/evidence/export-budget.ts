import type { EvidenceDescriptor } from './types.ts';

export const MAX_EXPORT_EVIDENCE_BYTES = 24 * 1024 * 1024;
export const MAX_EXPORT_EVIDENCE_PIXELS = 16_000_000;

export function exportEvidenceFitsBudget(
  descriptors: ReadonlyArray<Pick<EvidenceDescriptor, 'byteLength' | 'width' | 'height'>>,
): boolean {
  let bytes = 0, pixels = 0;
  for (const descriptor of descriptors) {
    if (![descriptor.byteLength, descriptor.width, descriptor.height]
      .every(value => Number.isSafeInteger(value) && value > 0)) return false;
    bytes += descriptor.byteLength;
    pixels += descriptor.width * descriptor.height;
    if (!Number.isSafeInteger(bytes) || !Number.isSafeInteger(pixels)
      || bytes > MAX_EXPORT_EVIDENCE_BYTES || pixels > MAX_EXPORT_EVIDENCE_PIXELS) return false;
  }
  return true;
}
