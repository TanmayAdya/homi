import { createHash } from 'node:crypto';

export const MAX_TEMPLATE_BYTES = 5 * 1024 * 1024;

export function verifyTemplateBytes(bytes: Uint8Array, expectedSha256: string): string {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength < 8 || bytes.byteLength > MAX_TEMPLATE_BYTES) {
    throw new Error('Invalid form template size.');
  }
  if (typeof expectedSha256 !== 'string' || !/^[a-f0-9]{64}$/.test(expectedSha256)) {
    throw new Error('Invalid form template digest.');
  }
  const buffer = Buffer.from(bytes);
  if (buffer.subarray(0, 5).toString('ascii') !== '%PDF-') throw new Error('A PDF template is required.');
  const digest = createHash('sha256').update(buffer).digest('hex');
  if (digest !== expectedSha256) throw new Error('The form template changed and needs a new mapping review.');
  return digest;
}
