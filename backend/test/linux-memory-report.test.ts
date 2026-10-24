import assert from 'node:assert/strict';
import test from 'node:test';
import { assertLinuxMemoryStartup, evaluateLinuxMemoryScenario, type LinuxMemoryScenarioInput } from '../tool/linux-memory/report.ts';

function snapshot() {
  return { schemaVersion: '1', kind: 'memory', rssBytes: 204_800_000, maxRssKiB: 250_000, maxRssBytes: 256_000_000,
    cgroup: { version: 2, currentBytes: 220_000_000, peakBytes: 300_000_000, limitBytes: 499_998_720,
      swapMaxBytes: 0, cpuMax: '100000 100000', events: { low: 0, high: 0, max: 0, oom: 0, oom_kill: 0 } } };
}
function inspection(running: boolean) {
  return { Id: 'a'.repeat(64), Config: { User: 'node', Env: ['DO_NOT_EXPORT=this-private-value'] },
    HostConfig: { Memory: 500_000_000, MemorySwap: 500_000_000, NanoCpus: 1_000_000_000, ReadonlyRootfs: true,
      Privileged: false, PublishAllPorts: false, CapDrop: ['ALL'], CapAdd: [], Binds: [], VolumesFrom: [], Devices: [],
      DeviceRequests: [], Sysctls: {}, PortBindings: {}, NetworkMode: 'synthetic-isolated-network', PidMode: '',
      IpcMode: 'private', UTSMode: '', SecurityOpt: ['no-new-privileges'], RestartPolicy: { Name: 'no', MaximumRetryCount: 0 } },
    Mounts: [{ Type: 'volume', RW: false, Source: '/unreturned/private/path', Destination: '/lab' }],
    NetworkSettings: { Ports: { '8788/tcp': null } },
    State: { Status: running ? 'running' : 'exited', Running: running, OOMKilled: false, Dead: false, Error: '', ExitCode: 0 } };
}
function inputFor(scenario: LinuxMemoryScenarioInput['scenario'] = 'pdf-solid-16mp') {
  const common = { privateNoStore: true, ordinaryReadAccepted: true, crossOwnerCaseDenied: true, invalidSessionDenied: true, workerCompleted: true };
  const pdf = { draftOnly: true, exactPagesAndSelection: true, retryIdentityPreserved: true, boundToExactEvidence: true,
    downloadAccepted: true, pdfMagic: true, downloadDigestMatches: true, crossOwnerArtifactDenied: true };
  const upload = { httpCaseCreated: true, fixtureInputBounds: true, fixturePixelCoverage: true, uploadAccepted: true,
    exactDimensions: true, pngMetadata: true, replacementDigestStable: true, previewAccepted: true, previewDigestMatches: true,
    pngMagic: true, singleCurrentPhoto: true, crossOwnerArtifactDenied: true };
  const rejection = { httpCaseCreated: true, pixelLimitRejected: true, inputByteLimitRejected: true, aggregateLimitRejected: true, noPartialUpload: true };
  const iterations = ['pdf-repeat-16mp', 'upload-repeat-16mp'].includes(scenario) ? 3 : 1;
  const inputBytes = ['pdf-near24mb', 'pdf-repeat-16mp'].includes(scenario) ? 24_500_000
    : scenario.startsWith('upload-') ? 8_000_000 : 65_536;
  const selectedEvidenceBytes = scenario.startsWith('upload-') ? 21_000_000 : inputBytes * (scenario === 'pdf-six-16mp' ? 6 : 1);
  return { scenario, architecture: 'amd64' as 'amd64' | 'arm64',
    ready: { schemaVersion: '1', kind: 'ready', runtime: { node: '24.22.0', platform: 'linux', arch: 'x64', uid: 1000,
      execArgv: ['--max-old-space-size=64', '--max-semi-space-size=1'], allocatorArenaMax: 2, sharpConcurrency: 1 }, baseline: snapshot() }, memory: snapshot(),
    workload: { schemaVersion: '1', kind: 'workload', scenario, status: 'passed', iterations,
      workload: { inputBytes, selectedEvidenceBytes, selectedEvidencePixels: scenario === 'pdf-six-16mp' ? 15_996_000
        : scenario === 'upload-near8mb-jpeg' ? 7_290_000 : scenario === 'reject-oversize' ? 32_000_000 : 16_000_000 },
      iterationElapsedMs: Array<number>(iterations).fill(125),
      assertions: { ...common, ...(scenario.startsWith('pdf-') ? pdf : scenario.startsWith('upload-') ? upload : rejection) } as Record<string, boolean> },
    clientExitCode: 0 as number | null, apiHealthyAfterWorkload: true,
    beforeStopInspect: inspection(true), afterStopInspect: inspection(false) };
}

test('all nine complete Linux workload reports pass with page-rounded cgroup limit', () => {
  const scenarios: LinuxMemoryScenarioInput['scenario'][] = ['pdf-solid-16mp', 'pdf-alpha-16mp', 'pdf-six-16mp', 'pdf-near24mb',
    'upload-near8mb-jpeg', 'upload-16mp-jpeg', 'upload-repeat-16mp', 'pdf-repeat-16mp', 'reject-oversize'];
  for (const scenario of scenarios) {
    const result = evaluateLinuxMemoryScenario(inputFor(scenario));
    assert.equal(result.status, 'passed', `${scenario}: ${result.failures}`);
    assert.deepEqual(result.cgroupEventsDelta, { low: 0, high: 0, max: 0, oom: 0, oom_kill: 0 });
  }
});

test('startup gate rejects the observed RSS sampling race before workload launch without repairing original evidence', () => {
  const input = inputFor(); input.architecture = 'arm64'; input.ready.runtime.arch = 'arm64';
  Object.assign(input.ready.baseline, { rssBytes: 122_220_544, maxRssKiB: 119_228, maxRssBytes: 122_089_472 });
  const before = JSON.stringify(input.ready); let started = false;
  assert.throws(() => { assertLinuxMemoryStartup(input.ready, 'arm64'); started = true; }, /workload was not started/);
  assert.equal(started, false); assert.equal(JSON.stringify(input.ready), before);
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('baseline_memory_invalid'));
});

test('startup gate shares strict runtime and baseline checks and refuses prior pressure or exceeded headroom', () => {
  const valid = inputFor(); assert.doesNotThrow(() => assertLinuxMemoryStartup(valid.ready, 'amd64'));
  for (const mutate of [
    (input: ReturnType<typeof inputFor>) => { input.ready.baseline.cgroup.currentBytes = input.ready.baseline.cgroup.peakBytes + 1; },
    (input: ReturnType<typeof inputFor>) => { input.ready.baseline.cgroup.events.oom = 1; },
    (input: ReturnType<typeof inputFor>) => { input.ready.baseline.cgroup.events.max = 1; },
    (input: ReturnType<typeof inputFor>) => { input.ready.baseline.cgroup.peakBytes = 400_000_001; },
    (input: ReturnType<typeof inputFor>) => { input.ready.baseline.maxRssKiB = 400_000; input.ready.baseline.maxRssBytes = 409_600_000; },
    (input: ReturnType<typeof inputFor>) => { input.ready.runtime.execArgv.push('--expose-gc'); },
    (input: ReturnType<typeof inputFor>) => { input.ready.runtime.allocatorArenaMax = 8; },
  ]) {
    const input = inputFor(); mutate(input); assert.throws(() => assertLinuxMemoryStartup(input.ready, 'amd64'));
  }
  assert.throws(() => assertLinuxMemoryStartup(undefined, 'amd64'));
  assert.throws(() => assertLinuxMemoryStartup(valid.ready, 'arm64'));
});

test('arm64 must be explicitly requested, and report metrics are detached and contain no Docker secrets or paths', () => {
  const input = inputFor(); input.architecture = 'arm64'; input.ready.runtime.arch = 'arm64';
  const report = evaluateLinuxMemoryScenario(input);
  assert.equal(report.status, 'passed');
  input.ready.runtime.execArgv[0] = 'modified'; input.memory.cgroup.events.max = 99;
  input.workload.assertions.workerCompleted = false;
  assert.equal(report.memory?.cgroup.events.max, 0);
  assert.equal(report.workload?.assertions.workerCompleted, true);
  assert.deepEqual(report.runtime?.execArgv, ['--max-old-space-size=64', '--max-semi-space-size=1']);
  assert.doesNotMatch(JSON.stringify(report), /DO_NOT_EXPORT|private-value|private\/path|synthetic-isolated-network|a{64}/);
});

test('omitted optional empty Docker fields are safe, but explicit device cgroup rules are not', () => {
  const input = inputFor();
  for (const inspection of [input.beforeStopInspect, input.afterStopInspect]) {
    for (const key of ['CapAdd', 'Binds', 'VolumesFrom', 'Devices', 'DeviceRequests', 'Sysctls', 'PortBindings']) {
      Reflect.deleteProperty(inspection.HostConfig, key);
    }
  }
  assert.equal(evaluateLinuxMemoryScenario(input).status, 'passed');
  Object.assign(input.beforeStopInspect.HostConfig, { DeviceCgroupRules: ['a *:* rwm'] });
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('container_configuration_invalid'));
});

test('RSS and cgroup headroom are independently required and the exact target is allowed', () => {
  const input = inputFor(); input.memory.cgroup.peakBytes = 400_000_000;
  assert.equal(evaluateLinuxMemoryScenario(input).status, 'passed');
  input.memory.cgroup.peakBytes++;
  assert.deepEqual(evaluateLinuxMemoryScenario(input).failures, ['cgroup_headroom_target_exceeded']);
  input.memory.cgroup.peakBytes = 300_000_000;
  input.memory.maxRssKiB = 390_626; input.memory.maxRssBytes = 390_626 * 1024;
  assert.deepEqual(evaluateLinuxMemoryScenario(input).failures, ['rss_headroom_target_exceeded']);
  input.memory.maxRssKiB = 500_000; input.memory.maxRssBytes = 512_000_000;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('service_reference_exceeded'));
  input.memory.cgroup.peakBytes = input.memory.cgroup.limitBytes;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('service_reference_exceeded'));
});

const metricFailures: [string, (input: ReturnType<typeof inputFor>) => void, string][] = [
  ['actual foreign architecture', i => { i.ready.runtime.arch = 'arm64'; }, 'runtime_invalid'],
  ['non-Linux runtime', i => { i.ready.runtime.platform = 'darwin'; }, 'runtime_invalid'],
  ['unpinned Node', i => { i.ready.runtime.node = '24.21.0'; }, 'runtime_invalid'],
  ['forced GC flag', i => { i.ready.runtime.execArgv.push('--expose-gc'); }, 'runtime_invalid'],
  ['wrong V8 heap limit', i => { i.ready.runtime.execArgv[0] = '--max-old-space-size=128'; }, 'runtime_invalid'],
  ['root runtime', i => { i.ready.runtime.uid = 0; }, 'runtime_invalid'],
  ['different allocator arena limit', i => { i.ready.runtime.allocatorArenaMax = 4; }, 'runtime_invalid'],
  ['unbounded allocator arenas', i => { i.ready.runtime.allocatorArenaMax = 0; }, 'runtime_invalid'],
  ['increased Sharp image concurrency', i => { i.ready.runtime.sharpConcurrency = 2; }, 'runtime_invalid'],
  ['KiB conversion mismatch', i => { i.memory.maxRssBytes++; }, 'final_memory_invalid'],
  ['current exceeds peak', i => { i.memory.cgroup.currentBytes = 300_000_001; }, 'final_memory_invalid'],
  ['zero peak', i => { i.memory.cgroup.peakBytes = 0; }, 'final_memory_invalid'],
  ['cgroup v1', i => { i.memory.cgroup.version = 1; }, 'final_memory_invalid'],
  ['limit rounded above configured', i => { i.memory.cgroup.limitBytes = 500_000_001; }, 'final_memory_invalid'],
  ['limit excessively rounded down', i => { i.memory.cgroup.limitBytes = 499_900_000; }, 'final_memory_invalid'],
  ['swap enabled', i => { i.memory.cgroup.swapMaxBytes = 1; }, 'final_memory_invalid'],
  ['CPU unlimited', i => { i.memory.cgroup.cpuMax = 'max 100000'; }, 'final_memory_invalid'],
  ['CPU exceeds one core', i => { i.memory.cgroup.cpuMax = '200000 100000'; }, 'final_memory_invalid'],
  ['existing baseline OOM', i => { i.ready.baseline.cgroup.events.oom = 1; i.memory.cgroup.events.oom = 1; }, 'oom_detected'],
  ['new OOM without kill', i => { i.memory.cgroup.events.oom = 1; }, 'oom_detected'],
  ['new OOM kill', i => { i.memory.cgroup.events.oom_kill = 1; }, 'oom_detected'],
  ['counter reset', i => { i.ready.baseline.cgroup.events.max = 1; }, 'memory_counters_regressed'],
  ['peak reset', i => { i.ready.baseline.cgroup.peakBytes = 310_000_000; }, 'memory_counters_regressed'],
];
for (const [name, change, failure] of metricFailures) test(`fails closed for ${name}`, () => {
  const input = inputFor(); change(input);
  const result = evaluateLinuxMemoryScenario(input);
  assert.equal(result.status, 'failed'); assert.ok(result.failures.includes(failure), result.failures.join(','));
});

test('absent memory, partial cgroup events, and snapshot error reports cannot pass', () => {
  const input: LinuxMemoryScenarioInput = inputFor();
  for (const memory of [undefined, null, { schemaVersion: '1', kind: 'memory', status: 'failed' },
    { ...snapshot(), cgroup: { ...snapshot().cgroup, events: { oom: 0, oom_kill: 0 } } }]) {
    input.memory = memory;
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('final_memory_invalid'));
  }
  input.memory = snapshot(); input.ready = undefined;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('baseline_memory_invalid'));
});

test('reports without the measured allocator and Sharp settings cannot pass the current runtime profile', () => {
  for (const field of ['allocatorArenaMax', 'sharpConcurrency']) {
    const input = inputFor(); Reflect.deleteProperty(input.ready.runtime, field);
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('runtime_invalid'));
  }
  const report = evaluateLinuxMemoryScenario(inputFor());
  assert.equal(report.runtime?.allocatorArenaMax, 2); assert.equal(report.runtime?.sharpConcurrency, 1);
});

const containerFailures: [string, (inspect: ReturnType<typeof inspection>) => void][] = [
  ['unbounded memory', i => { i.HostConfig.Memory = 0; }],
  ['swap allowance', i => { i.HostConfig.MemorySwap = 1_000_000_000; }],
  ['wrong CPU budget', i => { i.HostConfig.NanoCpus = 2_000_000_000; }],
  ['writable root', i => { i.HostConfig.ReadonlyRootfs = false; }],
  ['privileged', i => { i.HostConfig.Privileged = true; }],
  ['retained capabilities', i => { i.HostConfig.CapDrop = []; }],
  ['missing no-new-privileges', i => { i.HostConfig.SecurityOpt = []; }],
  ['root configured user', i => { i.Config.User = '0:1000'; }],
  ['host networking', i => { i.HostConfig.NetworkMode = 'host'; }],
  ['shared peer networking', i => { i.HostConfig.NetworkMode = 'container:peer'; }],
  ['host PID namespace', i => { i.HostConfig.PidMode = 'host'; }],
  ['automatic restart', i => { i.HostConfig.RestartPolicy.Name = 'always'; }],
  ['host bind mount', i => { i.Mounts[0].Type = 'bind'; }],
  ['writable volume', i => { i.Mounts[0].RW = true; }],
  ['automatic host ports', i => { i.HostConfig.PublishAllPorts = true; }],
];
for (const [name, change] of containerFailures) test(`rejects ${name} before or after the measured workload`, () => {
  for (const phase of ['beforeStopInspect', 'afterStopInspect'] as const) {
    const input = inputFor(); change(input[phase]);
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('container_configuration_invalid'));
  }
});

test('explicit ports, host Binds, device requests, and sysctls fail even with otherwise safe inspect fields', () => {
  for (const unsafe of [ { PortBindings: { '8788/tcp': [{ HostPort: '8788' }] } }, { Binds: ['/tmp:/tmp'] },
    { DeviceRequests: [{ Count: -1 }] }, { Devices: [{ PathOnHost: '/dev/mem' }] }, { Sysctls: { 'net.ipv4.ip_forward': '1' } } ]) {
    const input = inputFor(); Object.assign(input.beforeStopInspect.HostConfig, unsafe);
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('container_configuration_invalid'));
  }
  const input = inputFor();
  Object.assign(input.beforeStopInspect.NetworkSettings, { Ports: { '8788/tcp': [{ HostPort: '8788' }] } });
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('container_configuration_invalid'));
});

test('OOM-killed, dead, replaced, unhealthy, and nonzero-exit containers cannot be rescued by good workload JSON', () => {
  const changes: [(input: ReturnType<typeof inputFor>) => void, string][] = [
    [i => { i.beforeStopInspect.State.Running = false; }, 'api_not_running'],
    [i => { i.afterStopInspect.State.OOMKilled = true; }, 'api_exit_failed'],
    [i => { i.afterStopInspect.State.ExitCode = 137; }, 'api_exit_failed'],
    [i => { i.afterStopInspect.State.Dead = true; }, 'api_exit_failed'],
    [i => { i.afterStopInspect.Id = 'b'.repeat(64); }, 'container_identity_mismatch'],
    [i => { i.clientExitCode = null; }, 'client_exit_failed'],
    [i => { i.clientExitCode = 1; }, 'client_exit_failed'],
    [i => { i.apiHealthyAfterWorkload = false; }, 'api_unhealthy'],
  ];
  for (const [change, failure] of changes) {
    const input = inputFor(); change(input);
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes(failure));
  }
});

test('a killed API retains its actual exit and OOM status even when no final memory report exists', () => {
  const input = inputFor();
  input.beforeStopInspect.State.Running = false; input.beforeStopInspect.State.Status = 'exited';
  input.beforeStopInspect.State.OOMKilled = true; input.beforeStopInspect.State.ExitCode = 137;
  input.afterStopInspect.State.OOMKilled = true; input.afterStopInspect.State.ExitCode = 137;
  const result = evaluateLinuxMemoryScenario({ ...input, memory: undefined, clientExitCode: 1, apiHealthyAfterWorkload: false });
  assert.equal(result.status, 'failed'); assert.equal(result.memory, null);
  assert.deepEqual(result.api, {
    beforeStop: { running: false, exitCode: 137, oomKilled: true },
    afterStop: { running: false, exitCode: 137, oomKilled: true },
  });
  assert.ok(result.failures.includes('api_exit_failed'));
  assert.ok(result.failures.includes('final_memory_invalid'));
});

test('missing assertions, failed assertions, and truncated repeats remain failures', () => {
  for (const name of ['boundToExactEvidence', 'crossOwnerCaseDenied', 'downloadDigestMatches', 'workerCompleted']) {
    const input = inputFor(); delete input.workload.assertions[name];
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_assertions_incomplete'));
  }
  const input = inputFor('pdf-repeat-16mp');
  input.workload.assertions.downloadDigestMatches = false;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_failed'));
  input.workload.assertions.downloadDigestMatches = true; input.workload.status = 'failed';
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_failed'));
  input.workload.status = 'passed'; input.workload.iterationElapsedMs.pop();
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_invalid'));
  input.workload.iterationElapsedMs.push(125); input.workload.workload.selectedEvidencePixels = 1;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_invalid'));
});

test('ordinary safety failures preserve measured peaks for diagnosis without accepting a partial success', () => {
  const input = inputFor(); input.clientExitCode = 1;
  input.memory.cgroup.peakBytes = 450_000_000; input.workload.assertions = {};
  const result = evaluateLinuxMemoryScenario(input);
  assert.equal(result.status, 'failed'); assert.equal(result.memory?.cgroup.peakBytes, 450_000_000);
  assert.deepEqual(result.failures, ['cgroup_headroom_target_exceeded', 'client_exit_failed', 'workload_assertions_incomplete']);
});

function longInput(scenario: 'pdf-repeat-16mp' | 'upload-repeat-16mp' = 'pdf-repeat-16mp') {
  const input = inputFor(scenario);
  const iterations = 12;
  return { ...input, expectedMode: 'long' as const,
    checkpoints: Array.from({ length: iterations }, (_, index) => ({ iteration: index + 1,
      elapsedMs: index * 10_000 + 125, memory: snapshot() })),
    workload: { ...input.workload, mode: 'long', iterations,
      iterationElapsedMs: Array<number>(iterations).fill(125),
      iterationStartElapsedMs: Array.from({ length: iterations }, (_, index) => index * 10_000),
      elapsedMs: 110_126, renderRequests: scenario.startsWith('pdf-') ? 12 : 0,
      newGenerationRequests: scenario.startsWith('pdf-') ? 1 : 0,
      retryGenerationRequests: scenario.startsWith('pdf-') ? 11 : 0,
      assertions: { ...input.workload.assertions, pacingRespected: true, completeSession: true, noRateLimitResponses: true,
        ...(scenario.startsWith('pdf-') ? { artifactFreshEachIteration: true, retryBytesStable: true } : {}) } as Record<string, boolean> } };
}

test('explicit long upload and PDF modes require 12 paced iterations with memory after every iteration', () => {
  for (const scenario of ['pdf-repeat-16mp', 'upload-repeat-16mp'] as const) {
    const input = longInput(scenario), report = evaluateLinuxMemoryScenario(input);
    assert.equal(report.status, 'passed', report.failures.join(','));
    assert.equal(report.mode, 'long'); assert.equal(report.checkpoints.length, 12);
    assert.deepEqual(report.workload?.session, { iterationStartElapsedMs: input.workload.iterationStartElapsedMs,
      elapsedMs: 110_126, renderRequests: scenario.startsWith('pdf-') ? 12 : 0,
      newGenerationRequests: scenario.startsWith('pdf-') ? 1 : 0, retryGenerationRequests: scenario.startsWith('pdf-') ? 11 : 0 });
    assert.deepEqual(report.retentionTrend, { interpretation: 'descriptive_samples_not_proof_of_no_leaks', sampleCount: 12,
      earlyIterations: [1, 2, 3], lateIterations: [10, 11, 12], firstCheckpointElapsedMs: 125, lastCheckpointElapsedMs: 110_125,
      earlyMeanRssBytes: 204_800_000, lateMeanRssBytes: 204_800_000, rssMeanDeltaBytes: 0,
      earlyMeanCgroupCurrentBytes: 220_000_000, lateMeanCgroupCurrentBytes: 220_000_000, cgroupCurrentMeanDeltaBytes: 0,
      maxRssGrowthBytes: 0, cgroupPeakGrowthBytes: 0 });
  }
});

test('retention summaries report current-memory movement separately from cumulative peak growth and detach input', () => {
  const input = longInput();
  input.checkpoints.forEach(({ memory }, index) => {
    memory.rssBytes += index * 1_000_000;
    memory.cgroup.currentBytes -= index * 500_000;
    memory.maxRssKiB += index * 1000; memory.maxRssBytes = memory.maxRssKiB * 1024;
    memory.cgroup.peakBytes += index * 2_000_000;
  });
  input.memory = structuredClone(input.checkpoints.at(-1)!.memory);
  const report = evaluateLinuxMemoryScenario(input);
  assert.equal(report.status, 'passed', report.failures.join(','));
  assert.equal(report.retentionTrend?.rssMeanDeltaBytes, 9_000_000);
  assert.equal(report.retentionTrend?.cgroupCurrentMeanDeltaBytes, -4_500_000);
  assert.equal(report.retentionTrend?.maxRssGrowthBytes, 11_264_000);
  assert.equal(report.retentionTrend?.cgroupPeakGrowthBytes, 22_000_000);
  input.checkpoints[0].memory.rssBytes = 1; input.workload.iterationStartElapsedMs[0] = 123;
  assert.equal(report.checkpoints[0].memory.rssBytes, 204_800_000);
  assert.equal(report.workload?.session?.iterationStartElapsedMs[0], 0);
});

test('boundary and long workload modes cannot substitute for one another or broaden the scenario set', () => {
  const long = longInput();
  assert.ok(evaluateLinuxMemoryScenario({ ...long, expectedMode: 'boundary' }).failures.includes('workload_invalid'));
  assert.ok(evaluateLinuxMemoryScenario({ ...inputFor('pdf-repeat-16mp'), expectedMode: 'long' }).failures.includes('workload_invalid'));
  assert.deepEqual(evaluateLinuxMemoryScenario({ ...long, scenario: 'pdf-solid-16mp' }).failures, ['scenario_configuration_invalid']);
  assert.deepEqual(evaluateLinuxMemoryScenario({ ...long, expectedMode: 'unsupported' as 'long' }).failures, ['scenario_configuration_invalid']);
});

const longWorkloadFailures: [string, (input: ReturnType<typeof longInput>) => void][] = [
  ['truncated iterations', input => { input.workload.iterations = 11; }],
  ['truncated durations', input => { input.workload.iterationElapsedMs.pop(); }],
  ['truncated starts', input => { input.workload.iterationStartElapsedMs.pop(); }],
  ['unpaced requests', input => { input.workload.iterationStartElapsedMs[1]--; }],
  ['overlapping requests', input => { input.workload.iterationElapsedMs[0] = 10_001; }],
  ['short total elapsed', input => { input.workload.elapsedMs = 110_124; }],
  ['nonfinite elapsed', input => { input.workload.elapsedMs = Infinity; }],
  ['rendering skipped', input => { input.workload.renderRequests = 1; }],
  ['new artifacts each iteration', input => { input.workload.newGenerationRequests = 12; }],
  ['retries skipped', input => { input.workload.retryGenerationRequests = 0; }],
];
for (const [name, change] of longWorkloadFailures) test(`long report fails closed for ${name}`, () => {
  const input = longInput(); change(input);
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_invalid'));
});

test('long assertion omissions and failed response checks fail even if all measurements are within target', () => {
  for (const assertion of ['pacingRespected', 'completeSession', 'noRateLimitResponses', 'artifactFreshEachIteration', 'retryBytesStable']) {
    const input = longInput(); delete input.workload.assertions[assertion];
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_assertions_incomplete'));
    input.workload.assertions[assertion] = false;
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_failed'));
  }
});

test('missing, truncated, duplicated, reordered, malformed or extra long checkpoints cannot pass', () => {
  const changes: ((input: ReturnType<typeof longInput>) => unknown)[] = [
    () => undefined, () => null,
    input => input.checkpoints.slice(0, 11),
    input => [...input.checkpoints, input.checkpoints[11]],
    input => input.checkpoints.map((item, index) => index === 5 ? input.checkpoints[4] : item),
    input => [...input.checkpoints].reverse(),
    input => input.checkpoints.map((item, index) => index === 5 ? { ...item, memory: {} } : item),
    input => input.checkpoints.map((item, index) => index === 5 ? { ...item, elapsedMs: 1 } : item),
  ];
  for (const change of changes) {
    const input = longInput();
    const result = evaluateLinuxMemoryScenario({ ...input, checkpoints: change(input) });
    assert.equal(result.status, 'failed'); assert.equal(result.retentionTrend, null);
    assert.ok(result.failures.includes('iteration_checkpoints_invalid'));
  }
  const input = longInput(); input.checkpoints.pop(); input.checkpoints[5].memory.cgroup.peakBytes = 401_000_000;
  const failed = evaluateLinuxMemoryScenario(input);
  assert.equal(failed.checkpoints.length, 11);
  assert.ok(failed.failures.includes('cgroup_headroom_target_exceeded'));
});

test('per-iteration checkpoint clocks must correspond to completed workload iterations', () => {
  for (const elapsedMs of [122, 10_001, 120_000]) {
    const input = longInput(); input.checkpoints[0].elapsedMs = elapsedMs;
    const result = evaluateLinuxMemoryScenario(input);
    assert.equal(result.status, 'failed'); assert.equal(result.retentionTrend, null);
    assert.ok(result.failures.includes(elapsedMs === 122 || elapsedMs === 10_001 ? 'checkpoint_timing_invalid' : 'iteration_checkpoints_invalid'));
  }
  const rounding = longInput(); rounding.checkpoints[0].elapsedMs--;
  assert.equal(evaluateLinuxMemoryScenario(rounding).status, 'passed');
});

test('every checkpoint must satisfy RSS, cgroup, hard-limit and OOM checks even if final metrics appear healthy', () => {
  const mutations: [(memory: ReturnType<typeof snapshot>) => void, string][] = [
    [memory => { memory.maxRssKiB = 400_000; memory.maxRssBytes = 409_600_000; }, 'rss_headroom_target_exceeded'],
    [memory => { memory.cgroup.peakBytes = 401_000_000; }, 'cgroup_headroom_target_exceeded'],
    [memory => { memory.cgroup.peakBytes = memory.cgroup.limitBytes; }, 'service_reference_exceeded'],
    [memory => { memory.cgroup.events.oom = 1; }, 'oom_detected'],
    [memory => { memory.cgroup.events.oom_kill = 1; }, 'oom_detected'],
    [memory => { memory.cgroup.events.max = 1; }, 'cgroup_hard_limit_pressure_detected'],
  ];
  for (const [change, failure] of mutations) {
    const input = longInput(); change(input.checkpoints[5].memory);
    const report = evaluateLinuxMemoryScenario(input);
    assert.ok(report.failures.includes(failure), report.failures.join(','));
    assert.ok(report.failures.includes('memory_counters_regressed'));
    assert.equal(report.retentionTrend, null); assert.equal(report.cgroupEventsDelta, null);
  }
});

test('monotonic checkpoint counters and final snapshot are required across the full session', () => {
  for (const change of [
    (memory: ReturnType<typeof snapshot>) => { memory.maxRssKiB--; memory.maxRssBytes -= 1024; },
    (memory: ReturnType<typeof snapshot>) => { memory.cgroup.peakBytes--; },
    (memory: ReturnType<typeof snapshot>) => { memory.cgroup.limitBytes -= 4096; },
    (memory: ReturnType<typeof snapshot>) => { memory.cgroup.cpuMax = '50000 50000'; },
    (memory: ReturnType<typeof snapshot>) => { Object.assign(memory.cgroup.events, { oom_group_kill: 0 }); },
  ]) {
    const input = longInput(); change(input.checkpoints[7].memory);
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('memory_counters_regressed'));
  }
  const input = longInput(); input.memory.cgroup.peakBytes--;
  assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('memory_counters_regressed'));
});

function soakInput(scenario: 'pdf-repeat-16mp' | 'upload-repeat-16mp' = 'pdf-repeat-16mp') {
  const input = longInput(scenario), pdf = scenario.startsWith('pdf-');
  const iterations = 61;
  return { ...input, expectedMode: 'soak' as const,
    checkpoints: Array.from({ length: iterations }, (_, index) => ({ iteration: index + 1,
      elapsedMs: index * 60_000 + 125, memory: snapshot() })),
    workload: { ...input.workload, mode: 'soak', iterations,
      iterationElapsedMs: Array<number>(iterations).fill(125),
      iterationStartElapsedMs: Array.from({ length: iterations }, (_, index) => index * 60_000),
      elapsedMs: 3_600_126, renderRequests: pdf ? 61 : 0,
      newGenerationRequests: pdf ? 7 : 0, retryGenerationRequests: pdf ? 54 : 0,
      assertions: { ...input.workload.assertions,
        ...(pdf ? { generationRotationVerified: true, priorGenerationInvalidated: true } : {}) } as Record<string, boolean> } };
}

test('soak requires 61 complete paced iterations over at least one hour for each repeat workload', () => {
  for (const scenario of ['pdf-repeat-16mp', 'upload-repeat-16mp'] as const) {
    const input = soakInput(scenario), report = evaluateLinuxMemoryScenario(input), pdf = scenario.startsWith('pdf-');
    assert.equal(report.status, 'passed', report.failures.join(','));
    assert.equal(report.mode, 'soak'); assert.equal(report.checkpoints.length, 61);
    assert.deepEqual(report.workload?.session, {
      iterationStartElapsedMs: input.workload.iterationStartElapsedMs,
      elapsedMs: 3_600_126, renderRequests: pdf ? 61 : 0,
      newGenerationRequests: pdf ? 7 : 0, retryGenerationRequests: pdf ? 54 : 0,
    });
    assert.equal(report.retentionTrend?.interpretation, 'descriptive_samples_not_proof_of_no_leaks');
    assert.equal(report.retentionTrend?.sampleCount, 61);
    assert.deepEqual(report.retentionTrend?.earlyIterations, [1, 2, 3]);
    assert.deepEqual(report.retentionTrend?.lateIterations, [59, 60, 61]);
    assert.equal(report.retentionTrend?.lastCheckpointElapsedMs, 3_600_125);
  }
});

test('soak trends compare complete early and late samples without turning rising memory into a no-leak claim', () => {
  const input = soakInput();
  input.checkpoints.forEach(({ memory }, index) => {
    memory.rssBytes += index * 100_000;
    memory.cgroup.currentBytes += index * 200_000;
  });
  input.memory = structuredClone(input.checkpoints.at(-1)!.memory);
  const result = evaluateLinuxMemoryScenario(input);
  assert.equal(result.status, 'passed', result.failures.join(','));
  assert.equal(result.retentionTrend?.rssMeanDeltaBytes, 5_800_000);
  assert.equal(result.retentionTrend?.cgroupCurrentMeanDeltaBytes, 11_600_000);
  assert.equal(result.retentionTrend?.maxRssGrowthBytes, 0);
  assert.equal(result.retentionTrend?.interpretation, 'descriptive_samples_not_proof_of_no_leaks');
  input.checkpoints[60].memory.rssBytes = 1;
  input.workload.iterationStartElapsedMs[60] = 1;
  assert.equal(result.checkpoints[60].memory.rssBytes, 210_800_000);
  assert.equal(result.workload?.session?.iterationStartElapsedMs[60], 3_600_000);
});

const soakWorkloadFailures: [string, (input: ReturnType<typeof soakInput>) => void][] = [
  ['only 60 iterations', input => { input.workload.iterations = 60; }],
  ['only 60 durations', input => { input.workload.iterationElapsedMs.pop(); }],
  ['only 60 starts', input => { input.workload.iterationStartElapsedMs.pop(); }],
  ['extra starts', input => { input.workload.iterationStartElapsedMs.push(3_660_000); }],
  ['zero duration', input => { input.workload.iterationElapsedMs[60] = 0; }],
  ['nonfinite start', input => { input.workload.iterationStartElapsedMs[60] = NaN; }],
  ['late pacing violation', input => { input.workload.iterationStartElapsedMs[60]--; }],
  ['late overlapping requests', input => { input.workload.iterationElapsedMs[59] = 60_001; }],
  ['less than one hour', input => { input.workload.elapsedMs = 3_599_999; }],
  ['final operation omitted from elapsed', input => { input.workload.elapsedMs = 3_600_124; }],
  ['missing final render', input => { input.workload.renderRequests = 60; }],
  ['single generation reused for an hour', input => { input.workload.newGenerationRequests = 1; input.workload.retryGenerationRequests = 60; }],
  ['final rotation skipped', input => { input.workload.newGenerationRequests = 6; input.workload.retryGenerationRequests = 55; }],
  ['every request a new generation', input => { input.workload.newGenerationRequests = 61; input.workload.retryGenerationRequests = 0; }],
  ['wrong retry count', input => { input.workload.retryGenerationRequests = 53; }],
  ['long-mode report substituted', input => { input.workload.mode = 'long'; }],
];
for (const [name, change] of soakWorkloadFailures) test(`soak report fails closed for ${name}`, () => {
  const input = soakInput(); change(input);
  const report = evaluateLinuxMemoryScenario(input);
  assert.equal(report.status, 'failed');
  assert.ok(report.failures.includes('workload_invalid'), report.failures.join(','));
});

test('soak cannot substitute for long or boundary modes or run on a nonrepeat scenario', () => {
  const input = soakInput();
  for (const expectedMode of ['boundary', 'long'] as const) {
    assert.ok(evaluateLinuxMemoryScenario({ ...input, expectedMode }).failures.includes('workload_invalid'));
  }
  assert.ok(evaluateLinuxMemoryScenario({ ...longInput(), expectedMode: 'soak' }).failures.includes('workload_invalid'));
  assert.deepEqual(evaluateLinuxMemoryScenario({ ...input, scenario: 'pdf-solid-16mp' }).failures, ['scenario_configuration_invalid']);
  const upload = soakInput('upload-repeat-16mp'); upload.workload.renderRequests = 61;
  assert.ok(evaluateLinuxMemoryScenario(upload).failures.includes('workload_invalid'));
});

test('soak freshness, stable retries, new generations and prior artifact invalidation are all mandatory', () => {
  for (const assertion of ['artifactFreshEachIteration', 'retryBytesStable', 'generationRotationVerified',
    'priorGenerationInvalidated', 'pacingRespected', 'completeSession', 'noRateLimitResponses']) {
    const input = soakInput(); delete input.workload.assertions[assertion];
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_assertions_incomplete'), assertion);
    input.workload.assertions[assertion] = false;
    assert.ok(evaluateLinuxMemoryScenario(input).failures.includes('workload_failed'), assertion);
  }
  const upload = soakInput('upload-repeat-16mp');
  upload.workload.assertions.priorGenerationInvalidated = true;
  assert.ok(evaluateLinuxMemoryScenario(upload).failures.includes('workload_assertions_incomplete'));
});

test('soak preserves partial evidence but cannot pass with missing, malformed or mismatched late checkpoints', () => {
  const changes: ((input: ReturnType<typeof soakInput>) => unknown)[] = [
    () => undefined,
    input => input.checkpoints.slice(0, 60),
    input => [...input.checkpoints, { ...input.checkpoints[60], iteration: 62 }],
    input => input.checkpoints.map((item, index) => index === 60 ? input.checkpoints[59] : item),
    input => input.checkpoints.map((item, index) => index === 60 ? { ...item, memory: {} } : item),
  ];
  for (const change of changes) {
    const input = soakInput();
    const result = evaluateLinuxMemoryScenario({ ...input, checkpoints: change(input) });
    assert.equal(result.status, 'failed'); assert.equal(result.retentionTrend, null);
    assert.ok(result.failures.includes('iteration_checkpoints_invalid'));
  }
  for (const [index, elapsedMs] of [[60, 3_600_123], [60, 3_600_127], [59, 3_600_001]]) {
    const input = soakInput(); input.checkpoints[index].elapsedMs = elapsedMs;
    const result = evaluateLinuxMemoryScenario(input);
    assert.equal(result.status, 'failed'); assert.equal(result.retentionTrend, null);
    assert.ok(result.failures.includes('checkpoint_timing_invalid'));
  }
  const partial = soakInput(); partial.checkpoints.pop(); partial.clientExitCode = 1;
  const result = evaluateLinuxMemoryScenario(partial);
  assert.equal(result.checkpoints.length, 60); assert.equal(result.status, 'failed');
});

test('soak applies memory, runtime and cleanup checks to the final iteration without a long-mode cutoff', () => {
  const changes: [string, (input: ReturnType<typeof soakInput>) => void][] = [
    ['rss_headroom_target_exceeded', input => { input.checkpoints[60].memory.maxRssKiB = 400_000; input.checkpoints[60].memory.maxRssBytes = 409_600_000; }],
    ['cgroup_headroom_target_exceeded', input => { input.checkpoints[60].memory.cgroup.peakBytes = 401_000_000; }],
    ['oom_detected', input => { input.checkpoints[60].memory.cgroup.events.oom = 1; }],
    ['cgroup_hard_limit_pressure_detected', input => { input.checkpoints[60].memory.cgroup.events.max = 1; }],
    ['runtime_invalid', input => { input.ready.runtime.sharpConcurrency = 2; }],
    ['api_exit_failed', input => { input.afterStopInspect.State.ExitCode = 137; }],
  ];
  for (const [failure, change] of changes) {
    const input = soakInput(); change(input);
    const result = evaluateLinuxMemoryScenario(input);
    assert.equal(result.status, 'failed'); assert.ok(result.failures.includes(failure), result.failures.join(','));
  }
});
