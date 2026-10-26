import { createHmac, randomBytes } from 'node:crypto';
import { evidenceIdentifier } from '../evidence/validation.ts';

export const ACCOUNT_REQUEST_BURST = 30;
export const ACCOUNT_REQUESTS_PER_MINUTE = 60;
export const ACCOUNT_HEAVY_BURST = 6;
export const ACCOUNT_HEAVY_REQUESTS_PER_MINUTE = 12;
export const ACCOUNT_MAX_ACTIVE_REQUESTS = 4;
export const MAX_TRACKED_ACCOUNTS = 256;
export const ACCOUNT_IDLE_TTL_MS = 10 * 60_000;
export const RECEIPT_REQUEST_BURST = 10;
export const RECEIPT_REQUESTS_PER_MINUTE = 20;

type Refusal = { accepted: false; status: 429 | 503; code: 'RATE_LIMITED' | 'SERVICE_UNAVAILABLE'; retryAfter: number };
export type AccountAdmissionResult = { accepted: true; release: () => void } | Refusal;
interface Bucket { available: number; observedAt: number }
interface Entry { requests: Bucket; heavy: Bucket; active: number; lastSeen: number }

export function createAccountAdmission(now: () => number = () => performance.now()) {
  const accounts = new Map<string, Entry>();
  const key = randomBytes(32);
  let lastObserved = 0;
  let receipt: Bucket | undefined;
  const clock = () => {
    const value = now();
    if (!Number.isFinite(value) || value < 0) throw new Error('Invalid account admission clock.');
    lastObserved = Math.max(lastObserved, value); return lastObserved;
  };
  const refill = (bucket: Bucket, burst: number, perMinute: number, current: number) => {
    bucket.available = Math.min(burst, bucket.available + (current - bucket.observedAt) * perMinute / 60_000);
    bucket.observedAt = current;
  };
  const wait = (bucket: Bucket, rate: number) => Math.max(1, Math.ceil((1 - bucket.available) * 60 / rate));
  return {
    acquire(userId: string, heavy: boolean): AccountAdmissionResult {
      if (!evidenceIdentifier(userId) || typeof heavy !== 'boolean') throw new Error('Invalid account admission identity.');
      const current = clock();
      for (const [id, entry] of accounts) {
        if (entry.active === 0 && current - entry.lastSeen >= ACCOUNT_IDLE_TTL_MS) accounts.delete(id);
      }
      const id = createHmac('sha256', key).update(userId).digest('hex');
      let entry = accounts.get(id);
      if (!entry) {
        if (accounts.size >= MAX_TRACKED_ACCOUNTS) return { accepted: false, status: 503, code: 'SERVICE_UNAVAILABLE', retryAfter: 1 };
        entry = { requests: { available: ACCOUNT_REQUEST_BURST, observedAt: current },
          heavy: { available: ACCOUNT_HEAVY_BURST, observedAt: current }, active: 0, lastSeen: current };
        accounts.set(id, entry);
      }
      entry.lastSeen = current;
      refill(entry.requests, ACCOUNT_REQUEST_BURST, ACCOUNT_REQUESTS_PER_MINUTE, current);
      refill(entry.heavy, ACCOUNT_HEAVY_BURST, ACCOUNT_HEAVY_REQUESTS_PER_MINUTE, current);
      let retryAfter = entry.active >= ACCOUNT_MAX_ACTIVE_REQUESTS ? 1 : 0;
      if (entry.requests.available < 1) retryAfter = Math.max(retryAfter, wait(entry.requests, ACCOUNT_REQUESTS_PER_MINUTE));
      if (heavy && entry.heavy.available < 1) retryAfter = Math.max(retryAfter, wait(entry.heavy, ACCOUNT_HEAVY_REQUESTS_PER_MINUTE));
      if (retryAfter) return { accepted: false, status: 429, code: 'RATE_LIMITED', retryAfter };
      entry.requests.available--; if (heavy) entry.heavy.available--;
      entry.active++;
      let released = false;
      return { accepted: true, release() { if (!released) { released = true; entry.active--; } } };
    },
    acquireReceipt(): { accepted: true } | Refusal {
      const current = clock();
      receipt ??= { available: RECEIPT_REQUEST_BURST, observedAt: current };
      refill(receipt, RECEIPT_REQUEST_BURST, RECEIPT_REQUESTS_PER_MINUTE, current);
      if (receipt.available < 1) return { accepted: false, status: 503, code: 'SERVICE_UNAVAILABLE',
        retryAfter: wait(receipt, RECEIPT_REQUESTS_PER_MINUTE) };
      receipt.available--; return { accepted: true };
    },
  };
}
export type AccountAdmission = ReturnType<typeof createAccountAdmission>;
