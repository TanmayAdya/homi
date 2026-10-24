import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createAccountAdmission, ACCOUNT_REQUEST_BURST, ACCOUNT_MAX_ACTIVE_REQUESTS,
  ACCOUNT_HEAVY_BURST, MAX_TRACKED_ACCOUNTS, ACCOUNT_IDLE_TTL_MS, RECEIPT_REQUEST_BURST } from '../src/api/account-admission.ts';

test('account burst is bounded and refill allows only earned requests', () => {
  let clock = 0;
  const gate = createAccountAdmission(() => clock);
  for (let i = 0; i < ACCOUNT_REQUEST_BURST; i++) {
    const permit = gate.acquire('fictional-alice', false); assert.ok(permit.accepted); permit.release();
  }
  assert.deepEqual(gate.acquire('fictional-alice', false), { accepted: false, status: 429, code: 'RATE_LIMITED', retryAfter: 1 });
  clock = 999;
  assert.equal(gate.acquire('fictional-alice', false).accepted, false);
  clock = 1000;
  const next = gate.acquire('fictional-alice', false); assert.ok(next.accepted); next.release();
  assert.equal(gate.acquire('fictional-alice', false).accepted, false);
  assert.equal(gate.acquire('fictional-bob', false).accepted, true);
});

test('heavy requests have a separate budget without blocking ordinary reads or cleanup', () => {
  let clock = 0;
  const gate = createAccountAdmission(() => clock);
  for (let i = 0; i < ACCOUNT_HEAVY_BURST; i++) {
    const permit = gate.acquire('fictional-alice', true); assert.ok(permit.accepted); permit.release();
  }
  assert.deepEqual(gate.acquire('fictional-alice', true), { accepted: false, status: 429, code: 'RATE_LIMITED', retryAfter: 5 });
  const read = gate.acquire('fictional-alice', false); assert.ok(read.accepted); read.release();
  clock = 4999;
  assert.deepEqual(gate.acquire('fictional-alice', true), { accepted: false, status: 429, code: 'RATE_LIMITED', retryAfter: 1 });
  clock = 5000;
  assert.equal(gate.acquire('fictional-alice', true).accepted, true);
});

test('account concurrency and release are bounded independently across owners', () => {
  const gate = createAccountAdmission(() => 0);
  const held = Array.from({ length: ACCOUNT_MAX_ACTIVE_REQUESTS }, () => gate.acquire('fictional-alice', false));
  assert.ok(held.every(item => item.accepted));
  assert.equal(gate.acquire('fictional-alice', false).accepted, false);
  const bob = gate.acquire('fictional-bob', false); assert.ok(bob.accepted);
  for (const item of held) if (item.accepted) { item.release(); item.release(); }
  assert.equal(gate.acquire('fictional-alice', false).accepted, true);
  bob.release();
});

test('map saturation refuses a new owner without evicting a live budget; inactive entries expire', () => {
  let clock = 0;
  const gate = createAccountAdmission(() => clock);
  const first = gate.acquire('fictional-active', false); assert.ok(first.accepted);
  for (let i = 1; i < MAX_TRACKED_ACCOUNTS; i++) {
    const item = gate.acquire(`fictional-owner-${i}`, false); assert.ok(item.accepted); item.release();
  }
  assert.deepEqual(gate.acquire('fictional-new-owner', false), { accepted: false, status: 503, code: 'SERVICE_UNAVAILABLE', retryAfter: 1 });
  clock = ACCOUNT_IDLE_TTL_MS;
  const newcomer = gate.acquire('fictional-new-owner', false); assert.ok(newcomer.accepted); newcomer.release();
  for (let i = 1; i < ACCOUNT_MAX_ACTIVE_REQUESTS; i++) assert.equal(gate.acquire('fictional-active', false).accepted, true);
  assert.equal(gate.acquire('fictional-active', false).accepted, false);
  first.release();
  assert.equal(gate.acquire('fictional-active', false).accepted, true);
});

test('repeated account churn cannot reset a resident budget before its idle expiry', () => {
  const gate = createAccountAdmission(() => 0);
  for (let i = 0; i < ACCOUNT_REQUEST_BURST; i++) {
    const item = gate.acquire('fictional-alice', false); assert.ok(item.accepted); item.release();
  }
  for (let i = 0; i < MAX_TRACKED_ACCOUNTS * 2; i++) {
    const item = gate.acquire(`fictional-churn-${i}`, false); if (item.accepted) item.release();
  }
  assert.deepEqual(gate.acquire('fictional-alice', false), { accepted: false, status: 429, code: 'RATE_LIMITED', retryAfter: 1 });
});

test('clock rollback cannot refill rate budgets and long idle periods do not accumulate unbounded credit', () => {
  let clock = 60_000;
  const gate = createAccountAdmission(() => clock);
  for (let i = 0; i < ACCOUNT_REQUEST_BURST; i++) { const p = gate.acquire('fictional-alice', false); assert.ok(p.accepted); p.release(); }
  clock = 0;
  assert.equal(gate.acquire('fictional-alice', false).accepted, false);
  clock = 60_999;
  assert.equal(gate.acquire('fictional-alice', false).accepted, false);
  clock = 100 * ACCOUNT_IDLE_TTL_MS;
  for (let i = 0; i < ACCOUNT_REQUEST_BURST; i++) { const p = gate.acquire('fictional-alice', false); assert.ok(p.accepted); p.release(); }
  assert.equal(gate.acquire('fictional-alice', false).accepted, false);
});

test('receipt polling uses an independent bounded shared bucket and no identity key', () => {
  let clock = 0;
  const gate = createAccountAdmission(() => clock);
  for (let i = 0; i < RECEIPT_REQUEST_BURST; i++) assert.equal(gate.acquireReceipt().accepted, true);
  assert.deepEqual(gate.acquireReceipt(), { accepted: false, status: 503, code: 'SERVICE_UNAVAILABLE', retryAfter: 3 });
  assert.equal(gate.acquire('fictional-alice', false).accepted, true);
  clock = 2999;
  assert.equal(gate.acquireReceipt().accepted, false);
  clock = 3000;
  assert.equal(gate.acquireReceipt().accepted, true);
});

test('invalid clock and owner identities fail before consuming capacity', () => {
  const gate = createAccountAdmission(() => 0);
  for (const id of ['', ' ', 'x'.repeat(201), 'bad\nidentifier', null] as unknown as string[]) {
    assert.throws(() => gate.acquire(id, false));
  }
  for (const clock of [NaN, Infinity, -1]) {
    const invalid = createAccountAdmission(() => clock);
    assert.throws(() => invalid.acquire('fictional-alice', false));
    assert.throws(() => invalid.acquireReceipt());
  }
  assert.equal(gate.acquire('fictional-alice', false).accepted, true);
});
