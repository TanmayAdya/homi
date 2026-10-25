export const HOSTED_MAX_ACTIVE_REQUESTS = 16;
export const HOSTED_REQUESTS_PER_MINUTE = 120;
const WINDOW_MS = 60_000;

export type AdmissionResult = { accepted: true; release: () => void }
  | { accepted: false; retryAfter: number };

export function createHostedAdmission(now: () => number = () => performance.now()) {
  let active = 0;
  let heavyActive = false;
  let windowStart: number | null = null;
  let lastObserved = 0;
  let admitted = 0;
  return {
    acquire(heavy: boolean): AdmissionResult {
      const observed = now();
      if (!Number.isFinite(observed) || observed < 0) throw new Error('Invalid admission clock.');
      const current = Math.max(lastObserved, observed);
      lastObserved = current;
      if (windowStart === null || current - windowStart >= WINDOW_MS) {
        windowStart = current;
        admitted = 0;
      }
      if (admitted >= HOSTED_REQUESTS_PER_MINUTE) {
        return { accepted: false, retryAfter: Math.max(1, Math.ceil((windowStart + WINDOW_MS - current) / 1000)) };
      }
      if (active >= HOSTED_MAX_ACTIVE_REQUESTS || (heavy && heavyActive)) {
        return { accepted: false, retryAfter: 1 };
      }
      admitted++; active++;
      if (heavy) heavyActive = true;
      let released = false;
      return { accepted: true, release() {
        if (released) return;
        released = true; active--;
        if (heavy) heavyActive = false;
      } };
    },
  };
}
