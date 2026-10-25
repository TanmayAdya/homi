import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { createSupabaseAuthenticator } from '../src/auth/supabase-auth.ts';
import { AUTH, OTHER, OTHER_TOKEN, OWNER, TOKEN, parseScenario, syntheticAuthFetch } from '../tool/linux-memory/protocol.ts';
import { allocatorArenaMax, memorySnapshot, parseCgroupEvents, parseCgroupInteger, type MemorySnapshotSampler } from '../tool/linux-memory/server.ts';
import { digestResponse, runLinuxWorkload } from '../tool/linux-memory/workload.ts';

test('container telemetry requires finite byte limits and complete nonduplicated cgroup counters', () => {
  assert.equal(parseCgroupInteger('500000000\n'), 500_000_000);
  assert.equal(parseCgroupInteger('0\n'), 0);
  for (const value of ['max\n', '-1', '0.5', ' 2', '1\n\n', '9007199254740992']) assert.throws(() => parseCgroupInteger(value));
  assert.deepEqual(parseCgroupEvents('low 0\nhigh 0\nmax 3\noom 0\noom_kill 0\noom_group_kill 0\n'),
    { low: 0, high: 0, max: 3, oom: 0, oom_kill: 0, oom_group_kill: 0 });
  for (const value of ['low 0\nhigh 0\nmax 0\noom 0\n',
    'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\nlow 1\n',
    'low 0\nhigh 0\nmax 0\noom 0\noom_kill -1\n']) assert.throws(() => parseCgroupEvents(value));
});

test('allocator telemetry rejects values that do not represent a canonical decimal startup setting', () => {
  assert.equal(allocatorArenaMax('2'), 2); assert.equal(allocatorArenaMax('4'), 4); assert.equal(allocatorArenaMax('0'), 0);
  for (const value of ['', '0x2', ' 2', '2 ', '2\n', '+2', '02', '2.0', '-2', 'NaN', '9007199254740992']) {
    assert.equal(allocatorArenaMax(value), null);
  }
});

test('memory sampling observes current values before later high-water marks while sampling itself allocates', async () => {
  const calls: string[] = []; let cgroupPeak = 80_000_000, processPeak = 122_089_472;
  const sample = await memorySnapshot({
    cgroupV2: async () => true,
    readCgroup: async name => {
      calls.push(`${name}:start`);
      if (name === 'memory.current') {
        await Promise.resolve(); cgroupPeak = 100_000_000; calls.push('memory.current:finished');
        return '100000000\n';
      }
      if (name === 'memory.peak') return `${cgroupPeak}\n`;
      if (name === 'memory.max') { cgroupPeak = 128_000_000; return '499998720\n'; }
      if (name === 'memory.swap.max') return '0\n';
      if (name === 'memory.events') return 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n';
      return '100000 100000\n';
    },
    rssBytes: () => { calls.push('rss'); processPeak = 122_220_544; return processPeak; },
    maxRssKiB: () => { calls.push('maxRSS'); return processPeak / 1024; },
  });
  assert.equal(sample.rssBytes, 122_220_544); assert.equal(sample.maxRssBytes, 122_220_544);
  assert.equal(sample.maxRssKiB, 119_356);
  assert.equal(sample.cgroup.currentBytes, 100_000_000); assert.equal(sample.cgroup.peakBytes, 128_000_000);
  assert.ok(calls.indexOf('memory.current:finished') < calls.indexOf('memory.peak:start'));
  assert.deepEqual(calls.slice(-2), ['rss', 'maxRSS']);
});

test('sampler does not clamp or replace contradictory measurements and rejects unavailable cgroup v2', async () => {
  let reads = 0;
  const sampler: MemorySnapshotSampler = { cgroupV2: async () => true,
    readCgroup: async name => {
      reads++;
      const values = { 'memory.current': '200', 'memory.peak': '100', 'memory.max': '499998720',
        'memory.swap.max': '0', 'memory.events': 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n', 'cpu.max': '100000 100000' };
      return values[name];
    }, rssBytes: () => 122_220_544, maxRssKiB: () => 119_228 };
  const sample = await memorySnapshot(sampler);
  assert.equal(sample.rssBytes, 122_220_544); assert.equal(sample.maxRssBytes, 122_089_472);
  assert.equal(sample.cgroup.currentBytes, 200); assert.equal(sample.cgroup.peakBytes, 100);
  reads = 0; await assert.rejects(memorySnapshot({ ...sampler, cgroupV2: async () => false }), /cgroup v2 required/);
  assert.equal(reads, 0);
});

test('synthetic auth transport exercises provider parsing and separates fictional owners', async () => {
  const authenticate = createSupabaseAuthenticator(AUTH, syntheticAuthFetch);
  assert.deepEqual(await authenticate(TOKEN), { userId: OWNER });
  assert.deepEqual(await authenticate(OTHER_TOKEN), { userId: OTHER });
  assert.equal(await authenticate('unknown-token'), null);
  await assert.rejects(syntheticAuthFetch('https://external.example/auth/v1/user', { method: 'GET' }));
  assert.throws(() => parseScenario('anything-else'));
});

test('separate HTTP client hashes every streamed byte and handles split magic prefixes', async () => {
  const bytes = Buffer.from('%PDF-1.7\nsynthetic-packet\n');
  const stream = new ReadableStream<Uint8Array>({ start(controller) {
    for (const part of [bytes.subarray(0, 2), bytes.subarray(2, 5), bytes.subarray(5)]) controller.enqueue(part);
    controller.close();
  } });
  const result = await digestResponse(new Response(stream), bytes.length);
  assert.equal(result.bytes, bytes.length);
  assert.equal(result.sha256, createHash('sha256').update(bytes).digest('hex'));
  assert.deepEqual(result.prefix, bytes.subarray(0, 8));
});

test('HTTP client stops oversized binary bodies and cancels the reader', async () => {
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(Buffer.alloc(9)); },
    cancel() { cancelled = true; } });
  await assert.rejects(digestResponse(new Response(stream), 8));
  assert.equal(cancelled, true);
});

test('HTTP failures produce a failed bounded report without exposing response details', async t => {
  const diagnostics: unknown[][] = [];
  t.mock.method(console, 'error', (...args: unknown[]) => { diagnostics.push(args); });
  const transport: typeof fetch = async (input, options) => {
    assert.equal(input, 'http://api:8788/v1/read-case');
    assert.equal(options?.redirect, 'error');
    assert.ok(options?.signal);
    return new Response('private-provider-diagnostic', { status: 503 });
  };
  const report = await runLinuxWorkload('pdf-solid-16mp', '/not-read', transport);
  assert.equal(report.status, 'failed'); assert.equal(report.assertions.workerCompleted, false);
  assert.equal(report.iterationElapsedMs.length, 0);
  assert.equal(JSON.stringify(report).includes('private-provider-diagnostic'), false);
  assert.equal(JSON.stringify(diagnostics).includes('private-provider-diagnostic'), false);
  assert.equal(diagnostics.length, 2);
});
