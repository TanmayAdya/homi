import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { access, chmod, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import { parseMemoryProfileArguments } from '../tool/profile-memory.ts';
import { MEMORY_SCENARIOS, PROFILE_SERVICE_BYTES, PROFILE_TARGET_BYTES, PROFILE_WORKER_NODE_ARGS, MemoryProfileError,
  parseFixtureReport, parseMemoryWorkerReport, profileChildEnvironment, runBoundedProfileChild, runMemoryProfile,
  type ChildRequest, type ChildResult, type MemoryScenario, type MemoryWorkerReport, type ProfileDependencies } from '../tool/memory/profile-harness.ts';

const encode = (value: unknown) => Buffer.from(JSON.stringify(value));

test('profile and durable launch commands use the same explicit V8 budget', async () => {
  const docker = await readFile(new URL('../Dockerfile', import.meta.url), 'utf8');
  const manifest = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  const command = JSON.parse(docker.match(/^CMD (.+)$/m)![1]);
  assert.deepEqual(command, ['node', ...PROFILE_WORKER_NODE_ARGS, 'src/api/durable-server.ts']);
  assert.equal(manifest.scripts['serve:durable'], command.join(' '));
  const report = await runMemoryProfile(seam().deps);
  assert.deepEqual(report.runtime.workerExecArgv, [...PROFILE_WORKER_NODE_ARGS]);
});
const fixture = encode({ schemaVersion: '1', status: 'prepared', files: 8, bytes: 12_000_000 });
function worker(scenario: MemoryScenario, peakBytes = 200 * 1024 * 1024): MemoryWorkerReport {
  const iterations = scenario === 'pdf-repeat-16mp' || scenario === 'upload-repeat-16mp' ? 3 : 1;
  return { schemaVersion: '1', scenario, status: 'passed', iterations,
    memory: { startupRssBytes: 40 * 1024 * 1024, baselineRssBytes: 80 * 1024 * 1024, finalRssBytes: 100 * 1024 * 1024,
      maxRssKiB: peakBytes / 1024, maxRssBytes: peakBytes, iterationRssBytes: Array(iterations).fill(100 * 1024 * 1024) },
    workload: { inputBytes: 12345, selectedEvidenceBytes: 12345, selectedEvidencePixels: 16_000_000 },
    assertions: { expectedOutcome: true, noPrivateInput: true } };
}
function seam(change?: (request: ChildRequest, result: ChildResult) => Promise<ChildResult> | ChildResult) {
  const calls: ChildRequest[] = []; const removed: string[] = [];
  let active = 0; let maximum = 0;
  const deps: ProfileDependencies = {
    createDirectory: async () => '/fictional-owned-directory',
    removeDirectory: async directory => { removed.push(directory); },
    now: () => new Date('2026-10-18T00:00:00Z'),
    runChild: async request => {
      active++; maximum = Math.max(active, maximum); calls.push(request);
      await Promise.resolve();
      try {
        const result: ChildResult = { exitCode: 0, stdout: request.kind === 'fixture' ? fixture : encode(worker(request.scenario!)) };
        return change ? await change(request, result) : result;
      } finally { active--; }
    },
  };
  return { deps, calls, removed, maximum: () => maximum };
}

test('memory CLI requires explicit run and does not accept private paths, cloud settings or workload overrides', () => {
  assert.equal(parseMemoryProfileArguments([]), 'help'); assert.equal(parseMemoryProfileArguments(['--help']), 'help');
  assert.equal(parseMemoryProfileArguments(['run']), 'run');
  for (const args of [['run', '/private/photo.jpg'], ['--database', 'postgres://fictional'], ['--scenario', 'custom'],
    ['run', '--expose-gc'], ['--run']]) assert.throws(() => parseMemoryProfileArguments(args));
  const result = spawnSync(process.execPath, [new URL('../tool/profile-memory.ts', import.meta.url).pathname], { encoding: 'utf8' });
  assert.equal(result.status, 0); assert.match(result.stdout, /Explicit run/); assert.equal(result.stderr, '');
});

test('strict report parsing validates units, repeated iterations, provenance and bounded output', () => {
  assert.equal(parseFixtureReport(fixture).files, 8);
  assert.equal(parseMemoryWorkerReport(encode(worker('pdf-repeat-16mp')), 'pdf-repeat-16mp').iterations, 3);
  assert.equal(parseMemoryWorkerReport(encode(worker('upload-repeat-16mp')), 'upload-repeat-16mp').iterations, 3);
  const incompleteUpload = worker('upload-repeat-16mp');
  incompleteUpload.iterations = 1; incompleteUpload.memory.iterationRssBytes = incompleteUpload.memory.iterationRssBytes.slice(0, 1);
  assert.throws(() => parseMemoryWorkerReport(encode(incompleteUpload), 'upload-repeat-16mp'), MemoryProfileError);
  const changes: ((value: any) => void)[] = [value => { value.scenario = 'unknown'; },
    value => { value.memory.maxRssBytes = value.memory.maxRssKiB; },
    value => { value.memory.maxRssKiB = 1.5; }, value => { value.memory.finalRssBytes = value.memory.maxRssBytes + 1; },
    value => { value.memory.iterationRssBytes = []; }, value => { value.iterations = 2; },
    value => { value.assertions = {}; }, value => { value.assertions.expectedOutcome = 'true'; },
    value => { value.workload.inputBytes = -1; }, value => { value.path = '/private/input'; }];
  for (const change of changes) {
    const value = worker('pdf-solid-16mp'); change(value);
    assert.throws(() => parseMemoryWorkerReport(encode(value), 'pdf-solid-16mp'), MemoryProfileError);
  }
  for (const invalid of [Buffer.alloc(0), Buffer.alloc(256 * 1024 + 1), Buffer.from([0xff]), Buffer.from('{}\n{}')]) {
    assert.throws(() => parseFixtureReport(invalid), MemoryProfileError);
  }
});

test('fixture generation precedes fresh sequential workers and owned cleanup completes before success', async () => {
  const run = seam(); const report = await runMemoryProfile(run.deps);
  assert.equal(run.maximum(), 1); assert.equal(run.calls[0].kind, 'fixture');
  assert.deepEqual(run.calls.slice(1).map(item => item.scenario), [...MEMORY_SCENARIOS]);
  assert.equal(report.scenarios.length, 9); assert.equal(report.status, 'passed'); assert.equal(report.cleanup, 'removed');
  assert.deepEqual(report.scenarios.filter(item => item.scenario.startsWith('upload-')).map(item => item.scenario),
    ['upload-near8mb-jpeg', 'upload-16mp-jpeg', 'upload-repeat-16mp']);
  assert.deepEqual(run.removed, ['/fictional-owned-directory']);
  assert.equal(report.thresholds.headroomTargetBytes, PROFILE_TARGET_BYTES);
  assert.equal(report.thresholds.serviceReferenceBytes, PROFILE_SERVICE_BYTES);
  assert.equal(report.interpretation, 'local_process_peak_not_linux_container_or_hosting_certification');
  assert.equal(JSON.stringify(report).includes('/fictional-owned-directory'), false);
});

test('baseline memory failures stay failed while later scenarios still run and no result becomes green', async () => {
  const run = seam((request, result) => request.scenario === 'pdf-solid-16mp'
    ? { ...result, stdout: encode(worker(request.scenario, 600 * 1024 * 1024)) } : result);
  const report = await runMemoryProfile(run.deps);
  assert.equal(report.status, 'failed'); assert.equal(report.scenarios.length, MEMORY_SCENARIOS.length);
  assert.deepEqual(report.scenarios[0].failures, ['headroom_target_exceeded', 'service_reference_exceeded']);
  assert.ok(report.scenarios[0].remainingReferenceBytes! < 0);
  assert.equal(report.scenarios[1].status, 'passed'); assert.equal(report.cleanup, 'removed');
});

test('headroom target is an independent failure below the hosted reference', async () => {
  const run = seam((request, result) => request.scenario === 'pdf-solid-16mp'
    ? { ...result, stdout: encode(worker(request.scenario, 410 * 1024 * 1024)) } : result);
  const report = await runMemoryProfile(run.deps);
  assert.equal(report.status, 'failed'); assert.deepEqual(report.scenarios[0].failures, ['headroom_target_exceeded']);
  assert.ok(report.scenarios[0].remainingReferenceBytes! > 0);
});

test('nonzero exits, child failures and failed assertions cannot be hidden by a plausible success report', async () => {
  for (const kind of ['exit', 'timeout', 'status', 'assertion', 'invalid'] as const) {
    const run = seam((request, result) => {
      if (request.scenario !== 'pdf-solid-16mp') return result;
      const value = worker(request.scenario);
      if (kind === 'exit') return { ...result, exitCode: 1 };
      if (kind === 'timeout') return { ...result, failure: 'timed_out' };
      if (kind === 'status') value.status = 'failed';
      if (kind === 'assertion') value.assertions.expectedOutcome = false;
      return { ...result, stdout: kind === 'invalid' ? Buffer.from('PRIVATE error') : encode(value) };
    });
    const report = await runMemoryProfile(run.deps);
    assert.equal(report.status, 'failed'); assert.equal(report.scenarios[0].status, 'failed');
    assert.equal(report.scenarios.length, 9); assert.equal(report.cleanup, 'removed');
    assert.equal(JSON.stringify(report).includes('PRIVATE'), false);
  }
});

test('fixture failures skip all measured work and still clean up the owned directory', async () => {
  for (const invalid of [{ exitCode: 1, stdout: fixture }, { exitCode: 0, stdout: Buffer.from('{}') },
    { exitCode: null, stdout: Buffer.alloc(0), failure: 'output_limit' as const }]) {
    const run = seam(() => invalid); const report = await runMemoryProfile(run.deps);
    assert.equal(report.status, 'failed'); assert.equal(report.fixture.status, 'failed');
    assert.equal(report.scenarios.length, 0); assert.equal(run.calls.length, 1);
    assert.equal(report.cleanup, 'removed'); assert.equal(run.removed.length, 1);
  }
});

test('cleanup failure and interrupted work are explicit failed reports', async () => {
  const run = seam(); run.deps.removeDirectory = async () => { throw new Error('PRIVATE path'); };
  const report = await runMemoryProfile(run.deps);
  assert.equal(report.cleanup, 'failed'); assert.equal(report.status, 'failed');
  assert.equal(JSON.stringify(report).includes('PRIVATE'), false);
  const controller = new AbortController();
  const aborted = seam((request, result) => {
    if (request.kind === 'worker') { controller.abort(); return { exitCode: null, stdout: Buffer.alloc(0), failure: 'aborted' }; }
    return result;
  });
  const interrupted = await runMemoryProfile(aborted.deps, controller.signal);
  assert.equal(interrupted.status, 'failed'); assert.equal(interrupted.scenarios.length, 1);
  assert.ok(interrupted.scenarios[0].failures.includes('aborted')); assert.equal(interrupted.cleanup, 'removed');
});

test('runner scrubs inherited credentials and preloads and reports only bounded stdout', async () => {
  assert.deepEqual(Object.keys(profileChildEnvironment()).sort(), ['LANG', 'LC_ALL', 'PATH', 'TZ']);
  const result = await runBoundedProfileChild(['-e', 'process.stdout.write(JSON.stringify({keys:Object.keys(process.env).sort(),args:process.execArgv}))']);
  assert.equal(result.exitCode, 0); assert.equal(result.failure, undefined);
  const parsed = JSON.parse(result.stdout.toString());
  assert.deepEqual(parsed.keys.filter((key: string) => process.platform === 'darwin' && key === '__CF_USER_TEXT_ENCODING' ? false : true),
    ['LANG', 'LC_ALL', 'PATH', 'TZ']);
  assert.equal(parsed.args.some((value: string) => value === '--expose-gc' || value === '--require' || value.startsWith('--env-file')), false);
  const oversized = await runBoundedProfileChild(['-e', 'process.stdout.write("x".repeat(4096))'], { stdoutBytes: 64 });
  assert.equal(oversized.failure, 'output_limit'); assert.ok(oversized.stdout.length <= 64);
  const noisy = await runBoundedProfileChild(['-e', 'process.stderr.write("PRIVATE".repeat(1000))'], { stderrBytes: 64 });
  assert.equal(noisy.failure, 'output_limit'); assert.equal(noisy.stdout.length, 0);
});

test('runner bounds elapsed work, propagates abort, and rejects unbounded configuration', async () => {
  const timedOut = await runBoundedProfileChild(['-e', 'setInterval(()=>{},1000)'], { timeoutMs: 100 });
  assert.equal(timedOut.failure, 'timed_out');
  const controller = new AbortController(); controller.abort();
  const aborted = await runBoundedProfileChild(['-e', 'process.exit(2)'], { signal: controller.signal });
  assert.equal(aborted.failure, 'aborted'); assert.equal(aborted.exitCode, null);
  await assert.rejects(runBoundedProfileChild([], { timeoutMs: 0 }), MemoryProfileError);
  await assert.rejects(runBoundedProfileChild([], { stdoutBytes: Number.MAX_SAFE_INTEGER }), MemoryProfileError);
});

test('an actual owned directory is removed after a failed lightweight fixture process', async () => {
  let directory = '';
  const run = seam();
  run.deps.createDirectory = async () => {
    directory = await mkdtemp('/tmp/sah-memory-test-'); await chmod(directory, 0o700);
    assert.equal((await stat(directory)).mode & 0o777, 0o700);
    await writeFile(join(directory, 'fictional.txt'), 'generated fixture', { mode: 0o600 }); return directory;
  };
  run.deps.removeDirectory = async owned => { assert.equal(owned, directory); await rm(owned, { recursive: true }); };
  run.deps.runChild = async () => { throw new Error('PRIVATE fixture failure'); };
  const report = await runMemoryProfile(run.deps);
  assert.equal(report.status, 'failed'); assert.equal(report.cleanup, 'removed');
  await assert.rejects(access(directory), { code: 'ENOENT' });
});
