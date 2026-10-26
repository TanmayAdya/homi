import { createHash } from 'node:crypto';

export function invitationEmail(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 254) return null;
  const email = value.trim().toLowerCase();
  const parts = email.split('@');
  if (parts.length !== 2 || parts[0].length > 64 || !/^[a-z0-9._%+-]+$/.test(parts[0])
    || parts[0].startsWith('.') || parts[0].endsWith('.') || parts[0].includes('..')
    || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/.test(parts[1])
    || parts[1].split('.').some(label => label.length > 63 || label.startsWith('-') || label.endsWith('-'))) return null;
  return email;
}
export function invitationEmailHash(value: string): string {
  const normalized = invitationEmail(value);
  if (!normalized) throw new TypeError('Invalid invitation email.');
  return createHash('sha256').update(`invite-email-v1:${normalized}`).digest('hex');
}
