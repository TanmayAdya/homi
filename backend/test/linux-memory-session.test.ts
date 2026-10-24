import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';
import { assertWorkloadMode, LONG_SESSION_INTERVAL_MS, LONG_SESSION_ITERATIONS, parseWorkloadMode,
  sessionConfiguration, SOAK_SESSION_ITERATIONS, SOAK_SESSION_INTERVAL_MS, SOAK_PDF_GENERATION_ITERATIONS,
  SOAK_CLIENT_DEADLINE_MS, SOAK_PROFILE_DEADLINE_MS } from '../tool/linux-memory/protocol.ts';
import { artifactIsFresh, createProgressAcknowledger, runLinuxWorkload, runPacedLongSession,
  type LinuxWorkloadProgress } from '../tool/linux-memory/workload.ts';

const progress: LinuxWorkloadProgress = { schemaVersion: '1', kind: 'workload-progress', scenario: 'pdf-repeat-16mp',
  mode: 'long', iteration: 1, plannedIterations: 12, iterationElapsedMs: 20, elapsedMs: 20 };

test('long-session choices are fixed, bounded and restricted to the maximum-image repeat workloads', () => {
  assert.equal(parseWorkloadMode(), 'boundary'); assert.equal(parseWorkloadMode('long'), 'long');
  assert.equal(LONG_SESSION_ITERATIONS, 12); assert.equal(LONG_SESSION_INTERVAL_MS, 10_000);
  assertWorkloadMode('pdf-repeat-16mp', 'long'); assertWorkloadMode('upload-repeat-16mp', 'long');
  for (const mode of ['short', 'forever', '1000', '']) assert.throws(() => parseWorkloadMode(mode));
  assert.throws(() => assertWorkloadMode('pdf-solid-16mp', 'long'));
  assert.throws(() => assertWorkloadMode('reject-oversize', 'long'));
});

test('twelve paced operations respect heavy-request refill without shortening slow operations', async () => {
  let clock = 200; const starts: number[] = [], waits: number[] = [];
  const result = await runPacedLongSession(async index => {
    starts.push(clock); clock += index === 2 ? 14_000 : 2_000;
  }, { now: () => clock, wait: async milliseconds => { waits.push(milliseconds); clock += milliseconds; } });
  assert.equal(starts.length, 12); assert.equal(result.starts.length, 12); assert.equal(result.durations.length, 12);
  assert.ok(starts.every((start, index) => index === 0 || start - starts[index - 1] >= 10_000));
  assert.equal(starts[3] - starts[2], 14_000);
  assert.equal(result.elapsedMs, 116_000); assert.ok(waits.every(value => value === 8_000));
});

test('soak is fixed to sixty-one native-session operations spanning at least an hour', async () => {
  assert.equal(parseWorkloadMode('soak'), 'soak');
  assert.equal(SOAK_SESSION_ITERATIONS, 61); assert.equal(SOAK_SESSION_INTERVAL_MS, 60_000);
  assert.equal(SOAK_PDF_GENERATION_ITERATIONS, 10);
  assert.equal(SOAK_CLIENT_DEADLINE_MS, 75 * 60_000); assert.equal(SOAK_PROFILE_DEADLINE_MS, 3 * 60 * 60_000);
  assert.deepEqual(sessionConfiguration('soak'), { iterations: 61, intervalMs: 60_000 });
  for (const scenario of ['pdf-repeat-16mp', 'upload-repeat-16mp'] as const) assertWorkloadMode(scenario, 'soak');
  assert.throws(() => assertWorkloadMode('pdf-near24mb', 'soak'));
  let clock = 0, calls = 0; const waits: number[] = [];
  const result = await runPacedLongSession(async () => { calls++; clock += 5000; }, {
    mode: 'soak', now: () => clock, wait: async milliseconds => { waits.push(milliseconds); clock += milliseconds; },
  });
  assert.equal(calls, 61); assert.equal(waits.length, 60); assert.ok(waits.every(ms => ms === 55_000));
  assert.equal(result.starts.at(-1), 3_600_000); assert.equal(result.elapsedMs, 3_605_000);
  assert.ok(result.starts.every((start, index) => index === 0 || start - result.starts[index - 1] >= 60_000));
});

test('a soak failure at the renewal boundary stops further requests instead of completing invented work', async () => {
  let clock = 0, calls = 0;
  await assert.rejects(runPacedLongSession(async index => {
    calls++; clock += 50; if (index === 10) throw new Error('generation renewal failed');
  }, { mode: 'soak', now: () => clock, wait: async milliseconds => { clock += milliseconds; } }), /renewal failed/);
  assert.equal(calls, 11); assert.equal(clock, 600_050);
});

test('a failed repeated operation stops the session immediately without fabricating later iterations', async () => {
  let clock = 0, calls = 0;
  await assert.rejects(runPacedLongSession(async index => {
    calls++; clock += 10;
    if (index === 3) throw new Error('synthetic repeat failed');
  }, { now: () => clock, wait: async milliseconds => { clock += milliseconds; } }), /synthetic repeat failed/);
  assert.equal(calls, 4);
});

test('reported iteration starts use the exact paced timestamp even when each clock read advances', async () => {
  let clock = 100; const actualStarts: number[] = [];
  const result = await runPacedLongSession(async (_index, started) => {
    assert.equal(started, clock - 1); actualStarts.push(started); clock += 7;
  }, { now: () => clock++, wait: async milliseconds => { clock += milliseconds; } });
  assert.deepEqual(result.starts, actualStarts.map(start => start - 100));
  assert.ok(actualStarts.every((start, index) => index === 0 || start - actualStarts[index - 1] >= 10_000));
});

test('cancellation interrupts pacing and does not issue the next heavy operation', async () => {
  let clock = 0, calls = 0; const controller = new AbortController();
  await assert.rejects(runPacedLongSession(async () => { calls++; clock += 10; }, {
    signal: controller.signal, now: () => clock, wait: async (_milliseconds, signal) => {
      assert.equal(signal, controller.signal); controller.abort(); signal?.throwIfAborted();
    },
  }), { name: 'AbortError' });
  assert.equal(calls, 1);
});

test('a one-millisecond early timer wake waits the remainder without shortening long or soak sessions', async () => {
  for (const mode of ['long', 'soak'] as const) {
    let clock = 0, calls = 0, early = false;
    const earlyAfter = mode === 'soak' ? 43 : 5, remainders: number[] = [];
    const config = sessionConfiguration(mode);
    const result = await runPacedLongSession(async () => { calls++; clock += 100; }, {
      mode, now: () => clock, wait: async milliseconds => {
        if (calls === earlyAfter) remainders.push(milliseconds);
        if (calls === earlyAfter && !early) { early = true; clock += milliseconds - 1; }
        else clock += milliseconds;
      },
    });
    assert.equal(calls, config.iterations);
    assert.deepEqual(remainders, [config.intervalMs - 100, 1]);
    assert.ok(result.starts.every((start, index) => index === 0 || start - result.starts[index - 1] >= config.intervalMs));
    assert.equal(result.starts.at(-1), (config.iterations - 1) * config.intervalMs);
  }
});

test('repeated nonadvancing or persistently early waiters fail after bounded waits without a next request', async () => {
  for (const advance of [0, 1]) {
    let clock = 0, calls = 0, waits = 0;
    await assert.rejects(runPacedLongSession(async () => { calls++; clock += 10; }, {
      now: () => clock, wait: async () => { waits++; clock += advance; },
    }), /pacing timer did not reach its deadline/);
    assert.equal(calls, 1); assert.equal(waits, 8);
  }
});

test('invalid initial, backward and overflowing pacing clocks cannot start further work', async () => {
  for (const invalid of [NaN, Infinity, -1, 0.5, Number.MAX_SAFE_INTEGER + 1]) {
    let calls = 0;
    await assert.rejects(runPacedLongSession(async () => { calls++; }, { now: () => invalid }), /pacing clock/);
    assert.equal(calls, 0);
  }
  let clock = 0, calls = 0;
  await assert.rejects(runPacedLongSession(async () => { calls++; clock += 10; }, {
    now: () => clock, wait: async () => { clock--; },
  }), /pacing clock/);
  assert.equal(calls, 1);
  clock = Number.MAX_SAFE_INTEGER - 5; calls = 0;
  await assert.rejects(runPacedLongSession(async () => { calls++; clock++; }, { now: () => clock }), /pacing clock/);
  assert.equal(calls, 1);
});

test('cancellation during the remaining one-millisecond wait prevents the next operation', async () => {
  let clock = 0, calls = 0, waits = 0; const controller = new AbortController();
  await assert.rejects(runPacedLongSession(async () => { calls++; clock += 100; }, {
    signal: controller.signal, now: () => clock, wait: async milliseconds => {
      waits++;
      if (waits === 1) clock += milliseconds - 1;
      else { assert.equal(milliseconds, 1); controller.abort(); }
    },
  }), { name: 'AbortError' });
  assert.equal(calls, 1); assert.equal(waits, 2); assert.equal(clock, 9999);
});

test('progress acknowledgement is registered before publication and excludes stale acknowledgements', async () => {
  const signals = new EventEmitter(); let published = 0;
  const acknowledger = createProgressAcknowledger(value => {
    assert.deepEqual(value, progress); published++; signals.emit('SIGUSR2');
  }, signals);
  signals.emit('SIGUSR2');
  await acknowledger.report(progress); await acknowledger.report(progress);
  assert.equal(published, 2); acknowledger.dispose(); assert.equal(signals.listenerCount('SIGUSR2'), 0);
  await assert.rejects(acknowledger.report(progress), /acknowledgement state/);
});

test('an unacknowledged checkpoint fails and leaves no signal listener or pending timer', async () => {
  const signals = new EventEmitter(); let published = 0;
  const acknowledger = createProgressAcknowledger(() => { published++; }, signals, 10);
  await assert.rejects(acknowledger.report(progress), /timed out/);
  assert.equal(published, 1); acknowledger.dispose(); assert.equal(signals.listenerCount('SIGUSR2'), 0);
  assert.throws(() => createProgressAcknowledger(() => {}, signals, 30_001));
});

test('checkpoint wait rejects concurrent publication and can be cancelled during teardown', async () => {
  const signals = new EventEmitter(); const acknowledger = createProgressAcknowledger(() => {}, signals);
  const pending = acknowledger.report(progress);
  await assert.rejects(acknowledger.report(progress), /acknowledgement state/);
  acknowledger.dispose(); await assert.rejects(pending, /cancelled/);
  assert.equal(signals.listenerCount('SIGUSR2'), 0);
});

test('publication failures release the pending checkpoint instead of retaining its deadline', async () => {
  const signals = new EventEmitter(); const acknowledger = createProgressAcknowledger(() => { throw new Error('output failed'); }, signals);
  await assert.rejects(acknowledger.report(progress), /output failed/);
  await assert.rejects(acknowledger.report(progress), /output failed/); acknowledger.dispose();
});

test('PDF freshness checks reject expiration, future generation, invalid dates and earlier policy deadlines', () => {
  const artifact = { generatedAt: '2026-10-18T10:00:00.000Z', expiresAt: '2026-10-18T10:15:00.000Z', recheckAfter: null };
  const generated = Date.parse(artifact.generatedAt), expiry = Date.parse(artifact.expiresAt);
  assert.equal(artifactIsFresh(artifact, generated), true); assert.equal(artifactIsFresh(artifact, expiry - 1), true);
  assert.equal(artifactIsFresh(artifact, expiry), false); assert.equal(artifactIsFresh(artifact, generated - 1), false);
  assert.equal(artifactIsFresh({ ...artifact, expiresAt: 'invalid' }, generated), false);
  assert.equal(artifactIsFresh({ ...artifact, recheckAfter: '2026-10-18T10:01:00.000Z' }, generated + 60_000), false);
  assert.equal(artifactIsFresh(artifact, NaN), false);
});

test('an aborted long workload reports failure, no completed iterations and no plateau claim', async t => {
  t.mock.method(console, 'error', () => {});
  const controller = new AbortController(); controller.abort();
  const transport: typeof fetch = async () => { throw new Error('aborted workload must not send HTTP'); };
  const report = await runLinuxWorkload('pdf-repeat-16mp', '/not-read', transport, { mode: 'long', signal: controller.signal });
  assert.equal(report.status, 'failed'); assert.equal(report.mode, 'long'); assert.equal(report.iterations, 12);
  assert.deepEqual(report.iterationElapsedMs, []); assert.deepEqual(report.iterationStartElapsedMs, []);
  assert.equal(report.renderRequests, 0); assert.equal(report.assertions.workerCompleted, false);
  assert.equal(Object.keys(report).some(key => /plateau|stableMemory|leakFree/i.test(key)), false);
});

test('an aborted soak preserves its planned count without reporting fabricated renders or a completed hour', async t => {
  t.mock.method(console, 'error', () => {});
  const controller = new AbortController(); controller.abort();
  const report = await runLinuxWorkload('pdf-repeat-16mp', '/not-read', async () => {
    throw new Error('aborted workload must not send HTTP');
  }, { mode: 'soak', signal: controller.signal });
  assert.equal(report.status, 'failed'); assert.equal(report.mode, 'soak'); assert.equal(report.iterations, 61);
  assert.deepEqual(report.iterationStartElapsedMs, []); assert.equal(report.renderRequests, 0);
  assert.equal(report.assertions.completeSession, undefined); assert.equal(report.assertions.workerCompleted, false);
});
