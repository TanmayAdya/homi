import assert from 'node:assert/strict';
import test from 'node:test';
import { resolve } from 'node:path';
import { mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { randomBytes } from 'node:crypto';
import { apiContainerArgs, createProgressWriter, finalizeMeasuredScenario, localDockerEnvironment, parseCheckpointProgress,
  parseLinuxOptions, profileLinux, runCommand } from '../tool/linux-memory/container-harness.ts';

const output = resolve('local-artifacts/linux-test.json');
const args = ['--socket', '/tmp/owned-docker.sock', '--architecture', 'amd64', '--emulation', 'qemu-system', '--output', output];
test('Linux profile requires explicit local engine and architecture; report cannot escape ignored artifacts', () => {
  assert.equal(parseLinuxOptions(args).scenarios.length, 9);
  for (const bad of [[], [...args, '--socket', '/another.sock'], [...args, '--unknown', 'yes'],
    args.map(value => value === '/tmp/owned-docker.sock' ? 'tcp://remote:2375' : value),
    args.map(value => value === output ? '/tmp/report.json' : value),
    args.map(value => value === 'amd64' ? 'guess' : value)]) {
    assert.throws(() => parseLinuxOptions(bad));
  }
  assert.deepEqual(parseLinuxOptions([...args, '--scenario', 'pdf-near24mb']).scenarios, ['pdf-near24mb']);
  assert.deepEqual(parseLinuxOptions([...args, '--mode', 'long']).scenarios, ['upload-repeat-16mp', 'pdf-repeat-16mp']);
  assert.equal(parseLinuxOptions(args).mode, 'boundary');
  assert.throws(() => parseLinuxOptions([...args, '--mode', 'long', '--scenario', 'pdf-near24mb']));
  assert.throws(() => parseLinuxOptions([...args, '--mode', 'forever']));
  assert.equal(parseLinuxOptions([...args, '--image-source', 'cache']).imageSource, 'cache');
  assert.throws(() => parseLinuxOptions([...args, '--image-source', 'anywhere']));
  const native = args.map(value => value === 'qemu-system' ? 'none' : value);
  assert.deepEqual(parseLinuxOptions([...native, '--mode', 'soak']).scenarios, ['upload-repeat-16mp', 'pdf-repeat-16mp']);
  assert.throws(() => parseLinuxOptions([...args, '--mode', 'soak']), /native local Linux/);
  assert.throws(() => parseLinuxOptions([...native, '--mode', 'soak', '--scenario', 'pdf-near24mb']));
});
test('checkpoint events must match the next operation and cannot hide skipped or extra iterations', () => {
  const progress = { schemaVersion: '1', kind: 'workload-progress', scenario: 'upload-repeat-16mp', mode: 'long',
    iteration: 1, plannedIterations: 12, iterationElapsedMs: 6000, elapsedMs: 6500 };
  const parse = (value: unknown, next = 1) => parseCheckpointProgress(JSON.stringify(value), 'upload-repeat-16mp', next);
  assert.deepEqual(parse(progress), { iteration: 1, elapsedMs: 6500 });
  assert.equal(parse({ kind: 'workload' }), undefined);
  for (const invalid of [{ ...progress, iteration: 2 }, { ...progress, mode: 'boundary' }, { ...progress, plannedIterations: 3 },
    { ...progress, scenario: 'pdf-repeat-16mp' }, { ...progress, elapsedMs: -1 }, { ...progress, token: 'untrusted-field' }]) {
    assert.throws(() => parse(invalid));
  }
  assert.throws(() => parse({ ...progress, iteration: 13 }, 13));
  const soak = { ...progress, mode: 'soak', plannedIterations: 61, iteration: 61, elapsedMs: 3_606_000 };
  assert.deepEqual(parseCheckpointProgress(JSON.stringify(soak), 'upload-repeat-16mp', 61, 'soak'),
    { iteration: 61, elapsedMs: 3_606_000 });
  for (const invalid of [{ ...soak, plannedIterations: 12 }, { ...soak, mode: 'long' }, { ...soak, iteration: 62 }]) {
    assert.throws(() => parseCheckpointProgress(JSON.stringify(invalid), 'upload-repeat-16mp', invalid.iteration, 'soak'));
  }
});

test('running progress uses private atomic snapshots and refuses stale files and initial symlinks', async () => {
  const directory = await mkdtemp('/tmp/sah-soak-status-test-'), output = `${directory}/report.json`;
  try {
    const write = await createProgressWriter(output);
    await write({ status: 'running', iteration: 1 });
    assert.deepEqual(JSON.parse(await readFile(`${output}.progress.json`, 'utf8')), { status: 'running', iteration: 1 });
    await write({ status: 'failed', iteration: 17 });
    assert.deepEqual(JSON.parse(await readFile(`${output}.progress.json`, 'utf8')), { status: 'failed', iteration: 17 });
    assert.equal((await stat(`${output}.progress.json`)).mode & 0o777, 0o600);
    await assert.rejects(createProgressWriter(output), { code: 'EEXIST' });
    const target = `${directory}/target`; await writeFile(target, 'untouched');
    await symlink(target, `${directory}/link.json.progress.json`);
    await assert.rejects(createProgressWriter(`${directory}/link.json`), { code: 'EEXIST' });
    assert.equal(await readFile(target, 'utf8'), 'untouched');
    assert.equal((await readdir(directory)).some(name => name.endsWith('.tmp')), false);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('a stale soak sidecar fails before Docker and still closes the report and removes signal listeners', async t => {
  t.mock.method(console, 'error', () => {});
  const socketDirectory = await mkdtemp('/tmp/sah-soak-socket-');
  const socket = `${socketDirectory}/docker.sock`, server = createServer();
  const output = resolve(`local-artifacts/soak-collision-test-${randomBytes(6).toString('hex')}.json`);
  const before = { SIGINT: process.listeners('SIGINT'), SIGTERM: process.listeners('SIGTERM') };
  let diagnostics: string | undefined;
  try {
    await new Promise<void>(resolve => server.listen(socket, resolve));
    await writeFile(`${output}.progress.json`, 'previous run', { flag: 'wx', mode: 0o600 });
    assert.equal(await profileLinux(parseLinuxOptions(['--socket', socket, '--architecture', 'arm64', '--emulation', 'none',
      '--output', output, '--mode', 'soak', '--docker', '/not-an-executable'])), false);
    const report = JSON.parse(await readFile(output, 'utf8')); diagnostics = report.diagnosticDirectory;
    assert.equal(report.status, 'failed'); assert.match(report.error, /EEXIST/);
    assert.equal(report.cleanup.status, 'passed'); assert.equal(report.cleanup.temporaryFilesRemoved, true);
    assert.deepEqual(report.cases, []); assert.equal(await readFile(`${output}.progress.json`, 'utf8'), 'previous run');
    for (const signal of ['SIGINT', 'SIGTERM'] as const) assert.deepEqual(process.listeners(signal), before[signal]);
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(socketDirectory, { recursive: true, force: true });
    await Promise.all([rm(output, { force: true }), rm(`${output}.progress.json`, { force: true }),
      ...(diagnostics ? [rm(resolve('local-artifacts', diagnostics), { recursive: true, force: true })] : [])]);
  }
});
test('Docker subprocesses receive isolated local engine configuration without inherited credentials', () => {
  const env = localDockerEnvironment('/tmp/a.sock', '/tmp/private-config');
  assert.deepEqual(Object.keys(env).sort(), ['DOCKER_BUILDKIT', 'DOCKER_CONFIG', 'DOCKER_HOST', 'PATH']);
  assert.equal(env.DOCKER_HOST, 'unix:///tmp/a.sock');
  assert.equal(env.DOCKER_CONFIG, '/tmp/private-config');
});
test('measured API has a decimal 500 MB hard limit, no swap, production heaps and no host exposure', () => {
  const command = apiContainerArgs('api', 'isolated', 'fixtures', 'local-image', 'run1');
  const value = (flag: string) => command[command.indexOf(flag) + 1];
  assert.equal(value('--memory'), '500000000'); assert.equal(value('--memory-swap'), '500000000');
  assert.equal(value('--cpus'), '1'); assert.equal(value('--cap-drop'), 'ALL');
  assert.equal(value('--user'), '1000:1000'); assert.equal(value('--security-opt'), 'no-new-privileges');
  assert.equal(value('--mount'), 'type=volume,src=fixtures,dst=/lab,readonly');
  assert.ok(command.includes('--read-only'));
  for (const forbidden of ['--privileged', '--publish', '-p', '--volume', '-v', '--env-file', '--device']) assert.ok(!command.includes(forbidden));
  assert.deepEqual(command.slice(-4), ['node', '--max-old-space-size=64', '--max-semi-space-size=1', 'tool/linux-memory/server.ts']);
});
test('command runner preserves failure/timeout, bounds output and never evaluates shell syntax', async () => {
  const env = { PATH: process.env.PATH };
  const literal = await runCommand(process.execPath, ['-e', 'process.stdout.write(process.argv[1])', '$(do-not-run); `literal`'], env);
  assert.equal(literal.code, 0); assert.equal(literal.stdout, '$(do-not-run); `literal`');
  assert.equal((await runCommand(process.execPath, ['-e', 'process.exit(17)'], env)).code, 17);
  const timed = await runCommand(process.execPath, ['-e', 'setInterval(()=>{},1000)'], env, 30);
  assert.equal(timed.timedOut, true); assert.notEqual(timed.code, 0);
  const overflow = await runCommand(process.execPath, ['-e', "process.stdout.write('x'.repeat(3*1024*1024))"], env);
  assert.equal(overflow.code, -1);
  const abort = new AbortController();
  const interrupted = runCommand(process.execPath, ['-e', 'setInterval(()=>{},1000)'], env, 5_000, abort.signal);
  abort.abort();
  assert.equal((await interrupted).code, -1);
  let streamed = '';
  const observed = await runCommand(process.execPath, ['-e', 'process.stdout.write("progress\\n")'], env, 5000, undefined,
    chunk => { streamed += chunk; });
  assert.equal(observed.code, 0); assert.equal(streamed, 'progress\n');
  const rejected = await runCommand(process.execPath, ['-e', 'process.stdout.write("progress\\n")'], env, 5000, undefined,
    () => { throw new Error('Invalid progress'); });
  assert.equal(rejected.code, -1);
});

function measuredScenario() {
  const memory = { schemaVersion: '1', kind: 'memory', rssBytes: 220_000_000, maxRssKiB: 250_000, maxRssBytes: 256_000_000,
    cgroup: { version: 2, currentBytes: 250_000_000, peakBytes: 300_000_000, limitBytes: 499_998_720,
      swapMaxBytes: 0, cpuMax: '100000 100000', events: { low: 0, high: 0, max: 0, oom: 0, oom_kill: 0 } } };
  const input = { scenario: 'pdf-repeat-16mp' as const, architecture: 'amd64' as const, expectedMode: 'long' as const,
    ready: { schemaVersion: '1', kind: 'ready', runtime: { node: '24.22.0', platform: 'linux', arch: 'x64', uid: 1000,
      execArgv: ['--max-old-space-size=64', '--max-semi-space-size=1'], allocatorArenaMax: 2, sharpConcurrency: 1 }, baseline: structuredClone(memory) },
    checkpoints: Array.from({ length: 12 }, (_, index) => ({ iteration: index + 1, elapsedMs: index * 10_000 + 125, memory: structuredClone(memory) })),
    workload: { schemaVersion: '1', kind: 'workload', scenario: 'pdf-repeat-16mp', status: 'passed', iterations: 12, mode: 'long',
      workload: { inputBytes: 24_500_000, selectedEvidenceBytes: 24_500_000, selectedEvidencePixels: 16_000_000 },
      iterationElapsedMs: Array<number>(12).fill(125), iterationStartElapsedMs: Array.from({ length: 12 }, (_, index) => index * 10_000),
      elapsedMs: 110_126, renderRequests: 12, newGenerationRequests: 1, retryGenerationRequests: 11,
      assertions: { privateNoStore: true, ordinaryReadAccepted: true, crossOwnerCaseDenied: true, invalidSessionDenied: true, workerCompleted: true,
        draftOnly: true, exactPagesAndSelection: true, retryIdentityPreserved: true, boundToExactEvidence: true,
        downloadAccepted: true, pdfMagic: true, downloadDigestMatches: true, crossOwnerArtifactDenied: true,
        pacingRespected: true, completeSession: true, noRateLimitResponses: true, artifactFreshEachIteration: true, retryBytesStable: true } },
    clientExitCode: 0 };
  const inspection = (running: boolean) => ({ Id: 'a'.repeat(64), Config: { User: 'node' },
    HostConfig: { Memory: 500_000_000, MemorySwap: 500_000_000, NanoCpus: 1_000_000_000, ReadonlyRootfs: true,
      Privileged: false, PublishAllPorts: false, CapDrop: ['ALL'], NetworkMode: 'isolated', PidMode: '', IpcMode: 'private', UTSMode: '',
      RestartPolicy: { Name: 'no', MaximumRetryCount: 0 }, SecurityOpt: ['no-new-privileges'] },
    Mounts: [{ Type: 'volume', RW: false }], NetworkSettings: { Ports: null },
    State: { Running: running, Status: running ? 'running' : 'exited', OOMKilled: false, Dead: false, Error: '', ExitCode: 0 } });
  return { memory, input, inspection };
}

test('successful measured-case finalization snapshots, gracefully stops and inspects the same API', async () => {
  const fixture = measuredScenario(), calls: string[] = [];
  let running = true;
  const result = await finalizeMeasuredScenario(fixture.input, {
    inspect: async () => { calls.push('inspect'); return fixture.inspection(running); },
    snapshot: async () => { calls.push('snapshot'); return fixture.memory; },
    stop: async () => { calls.push('stop'); running = false; },
  });
  assert.equal(result.status, 'passed', result.failures.join(','));
  assert.deepEqual(calls, ['inspect', 'snapshot', 'stop', 'inspect']);
  assert.equal(result.checkpoints.length, 12);
});

test('failed final capture retains partial measurements and still attempts graceful stop and final inspect', async () => {
  const fixture = measuredScenario(), calls: string[] = [];
  fixture.input.checkpoints.splice(5);
  fixture.input.checkpoints[4].memory.cgroup.peakBytes = 420_000_000;
  let running = true;
  const result = await finalizeMeasuredScenario(fixture.input, {
    inspect: async () => { calls.push('inspect'); return fixture.inspection(running); },
    snapshot: async () => { calls.push('snapshot'); throw new Error('private provider details'); },
    stop: async () => { calls.push('stop'); running = false; },
  });
  assert.equal(result.status, 'failed'); assert.equal(result.memory, null);
  assert.equal(result.checkpoints.length, 5); assert.equal(result.checkpoints[4].memory.cgroup.peakBytes, 420_000_000);
  for (const code of ['final_memory_capture_failed', 'final_memory_invalid', 'iteration_checkpoints_invalid', 'cgroup_headroom_target_exceeded']) {
    assert.ok(result.failures.includes(code), result.failures.join(','));
  }
  assert.equal(result.api.afterStop.running, false);
  assert.deepEqual(calls, ['inspect', 'snapshot', 'stop', 'inspect']);
  assert.doesNotMatch(JSON.stringify(result), /private provider details/);
});

test('inspection and shutdown exceptions remain failed cases instead of discarding completed telemetry', async () => {
  for (const phase of ['before', 'stop', 'after'] as const) {
    const fixture = measuredScenario(); let running = true, inspections = 0, stops = 0;
    const result = await finalizeMeasuredScenario(fixture.input, {
      inspect: async () => {
        inspections++;
        if ((phase === 'before' && inspections === 1) || (phase === 'after' && inspections === 2)) throw new Error('inspect failed');
        return fixture.inspection(running);
      },
      snapshot: async () => fixture.memory,
      stop: async () => { stops++; if (phase === 'stop') throw new Error('stop failed'); running = false; },
    });
    assert.equal(result.status, 'failed'); assert.equal(result.checkpoints.length, 12);
    assert.equal(stops, 1); assert.equal(inspections, 2);
    assert.ok(result.failures.includes(phase === 'before' ? 'api_initial_inspection_failed'
      : phase === 'after' ? 'api_final_inspection_failed' : 'api_graceful_stop_failed'));
    if (phase !== 'before') assert.equal(result.memory?.cgroup.peakBytes, fixture.memory.cgroup.peakBytes);
  }
});

test('an OOM-killed API skips unavailable final capture and preserves actual exit status with partial samples', async () => {
  const fixture = measuredScenario(); fixture.input.checkpoints.splice(4);
  const inspection = fixture.inspection(false); inspection.State.OOMKilled = true; inspection.State.ExitCode = 137;
  const result = await finalizeMeasuredScenario(fixture.input, {
    inspect: async () => inspection,
    snapshot: async () => { throw new Error('must not capture a stopped API'); },
    stop: async () => { throw new Error('must not stop an already stopped API'); },
  });
  assert.equal(result.status, 'failed'); assert.equal(result.checkpoints.length, 4);
  assert.equal(result.api.beforeStop.oomKilled, true); assert.equal(result.api.afterStop.exitCode, 137);
  assert.equal(result.failures.includes('final_memory_capture_failed'), false);
  assert.equal(result.failures.includes('api_graceful_stop_failed'), false);
});
