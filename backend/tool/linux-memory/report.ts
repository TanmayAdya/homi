import { MEMORY_SCENARIOS, PROFILE_NODE_VERSION, PROFILE_SERVICE_BYTES, PROFILE_TARGET_BYTES,
  PROFILE_WORKER_NODE_ARGS, type MemoryScenario } from '../memory/profile-harness.ts';

export interface LinuxMemoryScenarioInput {
  scenario: MemoryScenario;
  architecture: 'amd64' | 'arm64';
  expectedMode?: 'boundary' | 'long' | 'soak';
  ready: unknown;
  memory: unknown;
  checkpoints?: unknown;
  workload: unknown;
  clientExitCode: number | null;
  apiHealthyAfterWorkload: boolean;
  beforeStopInspect: unknown;
  afterStopInspect: unknown;
}
export interface LinuxMemorySnapshot {
  schemaVersion: '1'; kind: 'memory'; rssBytes: number; maxRssKiB: number; maxRssBytes: number;
  cgroup: { version: 2; currentBytes: number; peakBytes: number; limitBytes: number; swapMaxBytes: number;
    cpuMax: string; events: Record<string, number> };
}
export interface LinuxMemoryCheckpoint {
  iteration: number; elapsedMs: number; memory: LinuxMemorySnapshot;
}
export interface LinuxMemoryRetentionTrend {
  interpretation: 'descriptive_samples_not_proof_of_no_leaks';
  sampleCount: number; earlyIterations: number[]; lateIterations: number[];
  firstCheckpointElapsedMs: number; lastCheckpointElapsedMs: number;
  earlyMeanRssBytes: number; lateMeanRssBytes: number; rssMeanDeltaBytes: number;
  earlyMeanCgroupCurrentBytes: number; lateMeanCgroupCurrentBytes: number; cgroupCurrentMeanDeltaBytes: number;
  maxRssGrowthBytes: number; cgroupPeakGrowthBytes: number;
}
interface ApiContainerOutcome { running: boolean | null; exitCode: number | null; oomKilled: boolean | null }
export interface LinuxMemoryScenarioResult {
  schemaVersion: '1'; scenario: MemoryScenario; architecture: 'amd64' | 'arm64';
  mode: 'boundary' | 'long' | 'soak';
  status: 'passed' | 'failed'; failures: string[];
  thresholds: { headroomTargetBytes: number; serviceReferenceBytes: number };
  runtime: { node: string; platform: 'linux'; arch: 'x64' | 'arm64'; uid: number; execArgv: string[];
    allocatorArenaMax: 2; sharpConcurrency: 1 } | null;
  baseline: LinuxMemorySnapshot | null;
  memory: LinuxMemorySnapshot | null;
  checkpoints: LinuxMemoryCheckpoint[];
  retentionTrend: LinuxMemoryRetentionTrend | null;
  cgroupEventsDelta: Record<string, number> | null;
  api: { beforeStop: ApiContainerOutcome; afterStop: ApiContainerOutcome };
  workload: { iterations: number; inputBytes: number; selectedEvidenceBytes: number; selectedEvidencePixels: number;
    iterationElapsedMs: number[]; assertions: Record<string, boolean>;
    session: { iterationStartElapsedMs: number[]; elapsedMs: number;
      renderRequests: number; newGenerationRequests: number; retryGenerationRequests: number } | null } | null;
}

const MIB = 1024 * 1024;
const EVENT_KEYS = ['low', 'high', 'max', 'oom', 'oom_kill', 'oom_group_kill', 'sock_throttled'];
const COMMON_ASSERTIONS = ['privateNoStore', 'ordinaryReadAccepted', 'crossOwnerCaseDenied', 'invalidSessionDenied', 'workerCompleted'];
const PDF_ASSERTIONS = ['draftOnly', 'exactPagesAndSelection', 'retryIdentityPreserved', 'boundToExactEvidence',
  'downloadAccepted', 'pdfMagic', 'downloadDigestMatches', 'crossOwnerArtifactDenied'];
const UPLOAD_ASSERTIONS = ['httpCaseCreated', 'fixtureInputBounds', 'fixturePixelCoverage', 'uploadAccepted',
  'exactDimensions', 'pngMetadata', 'replacementDigestStable', 'previewAccepted', 'previewDigestMatches',
  'pngMagic', 'singleCurrentPhoto', 'crossOwnerArtifactDenied'];
const REJECTION_ASSERTIONS = ['httpCaseCreated', 'pixelLimitRejected', 'inputByteLimitRejected', 'aggregateLimitRejected', 'noPartialUpload'];
const LONG_ASSERTIONS = ['pacingRespected', 'completeSession', 'noRateLimitResponses'];
const LONG_PDF_ASSERTIONS = ['artifactFreshEachIteration', 'retryBytesStable'];
const SOAK_PDF_ASSERTIONS = ['generationRotationVerified', 'priorGenerationInvalidated'];
type WorkloadMode = LinuxMemoryScenarioResult['mode'];
const LONG_ITERATIONS = 12;
const LONG_INTERVAL_MS = 10_000;
const SOAK_ITERATIONS = 61;
const SOAK_INTERVAL_MS = 60_000;
const SOAK_GENERATION_INTERVAL = 10;
const sessionIterations = (mode: WorkloadMode) => mode === 'soak' ? SOAK_ITERATIONS : LONG_ITERATIONS;
const sessionIntervalMs = (mode: WorkloadMode) => mode === 'soak' ? SOAK_INTERVAL_MS : LONG_INTERVAL_MS;
const REPEAT_SCENARIOS = ['pdf-repeat-16mp', 'upload-repeat-16mp'];

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function exact(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return record(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
function integer(value: unknown, minimum = 0, maximum = Number.MAX_SAFE_INTEGER): value is number {
  return Number.isSafeInteger(value) && Number(value) >= minimum && Number(value) <= maximum;
}
function sameStrings(value: unknown, expected: readonly string[]): boolean {
  return Array.isArray(value) && value.length === expected.length && value.every((item, index) => item === expected[index]);
}
function emptyList(value: unknown): boolean { return value == null || (Array.isArray(value) && value.length === 0); }
function emptyObject(value: unknown): boolean { return value == null || (record(value) && Object.keys(value).length === 0); }

function parseMemory(value: unknown): LinuxMemorySnapshot | null {
  if (!exact(value, ['schemaVersion', 'kind', 'rssBytes', 'maxRssKiB', 'maxRssBytes', 'cgroup'])
    || value.schemaVersion !== '1' || value.kind !== 'memory'
    || !integer(value.rssBytes, 1) || !integer(value.maxRssKiB, 1) || !integer(value.maxRssBytes, 1)
    || value.maxRssBytes !== value.maxRssKiB * 1024 || value.rssBytes > value.maxRssBytes) return null;
  const cg = value.cgroup;
  if (!exact(cg, ['version', 'currentBytes', 'peakBytes', 'limitBytes', 'swapMaxBytes', 'events', 'cpuMax'])
    || cg.version !== 2 || !integer(cg.currentBytes, 1) || !integer(cg.peakBytes, cg.currentBytes)
    || !integer(cg.limitBytes, PROFILE_SERVICE_BYTES - 65_536, PROFILE_SERVICE_BYTES)
    || cg.swapMaxBytes !== 0 || typeof cg.cpuMax !== 'string' || !record(cg.events)) return null;
  const cpu = /^([1-9][0-9]*) ([1-9][0-9]*)$/.exec(cg.cpuMax);
  if (!cpu || !integer(Number(cpu[1]), 1) || Number(cpu[1]) !== Number(cpu[2])) return null;
  const events = cg.events;
  if (!EVENT_KEYS.slice(0, 5).every(key => Object.hasOwn(events, key))
    || Object.entries(events).some(([key, count]) => !EVENT_KEYS.includes(key) || !integer(count))) return null;
  return { schemaVersion: '1', kind: 'memory', rssBytes: value.rssBytes, maxRssKiB: value.maxRssKiB,
    maxRssBytes: value.maxRssBytes, cgroup: { version: 2, currentBytes: cg.currentBytes, peakBytes: cg.peakBytes,
      limitBytes: cg.limitBytes, swapMaxBytes: 0, cpuMax: cg.cpuMax, events: { ...events } as Record<string, number> } };
}

function parseRuntime(value: unknown, architecture: LinuxMemoryScenarioInput['architecture']): LinuxMemoryScenarioResult['runtime'] {
  if (!exact(value, ['node', 'platform', 'arch', 'uid', 'execArgv', 'allocatorArenaMax', 'sharpConcurrency']) || value.node !== PROFILE_NODE_VERSION
    || value.platform !== 'linux' || value.arch !== (architecture === 'amd64' ? 'x64' : 'arm64')
    || !integer(value.uid, 1, 4_294_967_294) || !sameStrings(value.execArgv, PROFILE_WORKER_NODE_ARGS)
    || value.allocatorArenaMax !== 2 || value.sharpConcurrency !== 1) return null;
  return { node: PROFILE_NODE_VERSION, platform: 'linux', arch: value.arch as 'x64' | 'arm64',
    uid: value.uid, execArgv: [...PROFILE_WORKER_NODE_ARGS], allocatorArenaMax: 2, sharpConcurrency: 1 };
}

export function assertLinuxMemoryStartup(ready: unknown, architecture: LinuxMemoryScenarioInput['architecture']): void {
  if (!exact(ready, ['schemaVersion', 'kind', 'runtime', 'baseline']) || ready.schemaVersion !== '1' || ready.kind !== 'ready'
    || !['amd64', 'arm64'].includes(architecture) || !parseRuntime(ready.runtime, architecture)) {
    throw new Error('API startup runtime or baseline is invalid; workload was not started.');
  }
  const baseline = parseMemory(ready.baseline);
  if (!baseline || baseline.maxRssBytes > PROFILE_TARGET_BYTES || baseline.cgroup.peakBytes > PROFILE_TARGET_BYTES
    || baseline.cgroup.events.max !== 0 || baseline.cgroup.events.oom !== 0 || baseline.cgroup.events.oom_kill !== 0
    || (baseline.cgroup.events.oom_group_kill ?? 0) !== 0) {
    throw new Error('API startup runtime or baseline is invalid; workload was not started.');
  }
}

function validContainerConfiguration(value: unknown): boolean {
  if (!record(value) || !record(value.HostConfig) || !record(value.Config) || !record(value.NetworkSettings)) return false;
  const host = value.HostConfig;
  if (host.Memory !== PROFILE_SERVICE_BYTES || host.MemorySwap !== PROFILE_SERVICE_BYTES || host.NanoCpus !== 1_000_000_000
    || host.ReadonlyRootfs !== true || host.Privileged !== false || host.PublishAllPorts !== false
    || !sameStrings(host.CapDrop, ['ALL']) || !emptyList(host.CapAdd)
    || !emptyList(host.Binds) || !emptyList(host.VolumesFrom) || !emptyList(host.Devices) || !emptyList(host.DeviceRequests)
    || !emptyList(host.DeviceCgroupRules)
    || !emptyObject(host.Sysctls) || !emptyObject(host.PortBindings)
    || typeof host.NetworkMode !== 'string' || host.NetworkMode.length === 0 || host.NetworkMode === 'host'
    || host.NetworkMode.startsWith('container:') || host.PidMode !== '' || host.IpcMode !== 'private'
    || host.UTSMode !== '' || !record(host.RestartPolicy) || host.RestartPolicy.Name !== 'no'
    || host.RestartPolicy.MaximumRetryCount !== 0 || !Array.isArray(host.SecurityOpt)
    || !host.SecurityOpt.some(item => item === 'no-new-privileges' || item === 'no-new-privileges=true')) return false;
  const user = value.Config.User;
  if (typeof user !== 'string' || user.length === 0 || /^(?:0|root)(?::|$)/.test(user)) return false;
  if (!Array.isArray(value.Mounts) || value.Mounts.some(mount => !record(mount) || mount.Type !== 'volume' || mount.RW !== false)) return false;
  if (host.Mounts !== undefined && host.Mounts !== null
    && (!Array.isArray(host.Mounts) || host.Mounts.some(mount => !record(mount) || mount.Type !== 'volume' || mount.ReadOnly !== true))) return false;
  const ports = value.NetworkSettings.Ports;
  return ports === null || (record(ports) && Object.values(ports).every(emptyList));
}

function validContainerState(value: unknown, running: boolean): boolean {
  if (!record(value) || !record(value.State)) return false;
  const state = value.State;
  return state.Running === running && state.Status === (running ? 'running' : 'exited')
    && state.OOMKilled === false && state.Dead === false && state.Error === '' && state.ExitCode === 0;
}

function containerOutcome(value: unknown): ApiContainerOutcome {
  const state = record(value) && record(value.State) ? value.State : {};
  return { running: typeof state.Running === 'boolean' ? state.Running : null,
    exitCode: integer(state.ExitCode, 0, 255) ? state.ExitCode : null,
    oomKilled: typeof state.OOMKilled === 'boolean' ? state.OOMKilled : null };
}

function parseWorkload(value: unknown, scenario: MemoryScenario, mode: WorkloadMode): LinuxMemoryScenarioResult['workload'] {
  const sessionMode = mode !== 'boundary';
  const iterations = sessionMode ? sessionIterations(mode) : REPEAT_SCENARIOS.includes(scenario) ? 3 : 1;
  const fields = ['schemaVersion', 'kind', 'scenario', 'status', 'iterations', 'workload', 'assertions', 'iterationElapsedMs'];
  if (sessionMode) fields.push('mode', 'iterationStartElapsedMs', 'elapsedMs', 'renderRequests', 'newGenerationRequests', 'retryGenerationRequests');
  if (!exact(value, fields)
    || value.schemaVersion !== '1' || value.kind !== 'workload' || value.scenario !== scenario
    || !['passed', 'failed'].includes(String(value.status)) || value.iterations !== iterations
    || !Array.isArray(value.iterationElapsedMs) || value.iterationElapsedMs.length !== iterations
    || !value.iterationElapsedMs.every(item => integer(item, 1))
    || !exact(value.workload, ['inputBytes', 'selectedEvidenceBytes', 'selectedEvidencePixels'])
    || !record(value.assertions) || Object.keys(value.assertions).length > 32
    || Object.entries(value.assertions).some(([key, flag]) => !/^[a-zA-Z]{1,64}$/.test(key) || typeof flag !== 'boolean')) return null;
  const sizes = value.workload;
  const expectedPixels = scenario === 'pdf-six-16mp' ? 15_996_000 : scenario === 'upload-near8mb-jpeg' ? 7_290_000
    : scenario === 'reject-oversize' ? 32_000_000 : 16_000_000;
  if (!integer(sizes.inputBytes, 1, 24 * MIB) || !integer(sizes.selectedEvidenceBytes, 1, (scenario === 'reject-oversize' ? 48 : 24) * MIB)
    || sizes.selectedEvidencePixels !== expectedPixels) return null;
  if (scenario.startsWith('pdf-') && sizes.selectedEvidenceBytes !== sizes.inputBytes * (scenario === 'pdf-six-16mp' ? 6 : 1)) return null;
  if (['pdf-near24mb', 'pdf-repeat-16mp'].includes(scenario) && sizes.inputBytes < 23 * MIB) return null;
  if (scenario.startsWith('upload-') && !integer(sizes.inputBytes,
    (scenario === 'upload-near8mb-jpeg' ? 7.5 : 6) * MIB, 8 * MIB)) return null;
  let session: NonNullable<LinuxMemoryScenarioResult['workload']>['session'] = null;
  if (sessionMode) {
    const intervalMs = sessionIntervalMs(mode);
    const starts = value.iterationStartElapsedMs, durations = value.iterationElapsedMs;
    if (value.mode !== mode || !Array.isArray(starts) || starts.length !== iterations
      || !starts.every(item => integer(item)) || !integer(value.elapsedMs, intervalMs * (iterations - 1))
      || starts.some((item, index) => index > 0 && (item - starts[index - 1] < intervalMs
        || item < starts[index - 1] + durations[index - 1]))
      || value.elapsedMs < starts.at(-1)! + durations.at(-1)!) return null;
    const isPdf = scenario.startsWith('pdf-');
    const generations = mode === 'soak' ? Math.ceil(iterations / SOAK_GENERATION_INTERVAL) : 1;
    if (value.renderRequests !== (isPdf ? iterations : 0) || value.newGenerationRequests !== (isPdf ? generations : 0)
      || value.retryGenerationRequests !== (isPdf ? iterations - generations : 0)) return null;
    session = { iterationStartElapsedMs: [...starts], elapsedMs: value.elapsedMs,
      renderRequests: Number(value.renderRequests), newGenerationRequests: Number(value.newGenerationRequests),
      retryGenerationRequests: Number(value.retryGenerationRequests) };
  }
  return { iterations, inputBytes: sizes.inputBytes, selectedEvidenceBytes: sizes.selectedEvidenceBytes,
    selectedEvidencePixels: expectedPixels, iterationElapsedMs: [...value.iterationElapsedMs],
    assertions: { ...value.assertions } as Record<string, boolean>, session };
}

function parseCheckpoints(value: unknown, mode: WorkloadMode): { valid: boolean; checkpoints: LinuxMemoryCheckpoint[] } {
  if (mode === 'boundary') return { valid: value === undefined || (Array.isArray(value) && value.length === 0), checkpoints: [] };
  if (!Array.isArray(value)) return { valid: false, checkpoints: [] };
  const iterations = sessionIterations(mode);
  let valid = value.length === iterations;
  const checkpoints: LinuxMemoryCheckpoint[] = [];
  for (const [index, candidate] of value.slice(0, iterations).entries()) {
    if (!exact(candidate, ['iteration', 'elapsedMs', 'memory']) || !integer(candidate.iteration, 1, iterations)
      || !integer(candidate.elapsedMs, 1)) { valid = false; continue; }
    const memory = parseMemory(candidate.memory);
    if (!memory) { valid = false; continue; }
    if (candidate.iteration !== index + 1 || (checkpoints.length > 0 && candidate.elapsedMs <= checkpoints.at(-1)!.elapsedMs)) valid = false;
    checkpoints.push({ iteration: candidate.iteration, elapsedMs: candidate.elapsedMs, memory });
  }
  return { valid, checkpoints };
}

function retentionTrend(checkpoints: LinuxMemoryCheckpoint[]): LinuxMemoryRetentionTrend {
  const early = checkpoints.slice(0, 3), late = checkpoints.slice(-3);
  const mean = (values: LinuxMemoryCheckpoint[], metric: (item: LinuxMemorySnapshot) => number) =>
    Math.round(values.reduce((sum, item) => sum + metric(item.memory), 0) / values.length);
  const earlyRss = mean(early, item => item.rssBytes), lateRss = mean(late, item => item.rssBytes);
  const earlyCurrent = mean(early, item => item.cgroup.currentBytes), lateCurrent = mean(late, item => item.cgroup.currentBytes);
  const first = checkpoints[0], last = checkpoints.at(-1)!;
  return { interpretation: 'descriptive_samples_not_proof_of_no_leaks', sampleCount: checkpoints.length,
    earlyIterations: early.map(item => item.iteration), lateIterations: late.map(item => item.iteration),
    firstCheckpointElapsedMs: first.elapsedMs, lastCheckpointElapsedMs: last.elapsedMs,
    earlyMeanRssBytes: earlyRss, lateMeanRssBytes: lateRss, rssMeanDeltaBytes: lateRss - earlyRss,
    earlyMeanCgroupCurrentBytes: earlyCurrent, lateMeanCgroupCurrentBytes: lateCurrent,
    cgroupCurrentMeanDeltaBytes: lateCurrent - earlyCurrent,
    maxRssGrowthBytes: last.memory.maxRssBytes - first.memory.maxRssBytes,
    cgroupPeakGrowthBytes: last.memory.cgroup.peakBytes - first.memory.cgroup.peakBytes };
}

export function evaluateLinuxMemoryScenario(input: LinuxMemoryScenarioInput): LinuxMemoryScenarioResult {
  const failures: string[] = [];
  const fail = (code: string) => { if (!failures.includes(code)) failures.push(code); };
  const mode = input.expectedMode ?? 'boundary';
  const result: LinuxMemoryScenarioResult = { schemaVersion: '1', scenario: input.scenario, architecture: input.architecture,
    mode,
    status: 'failed', failures, thresholds: { headroomTargetBytes: PROFILE_TARGET_BYTES, serviceReferenceBytes: PROFILE_SERVICE_BYTES },
    runtime: null, baseline: null, memory: null, checkpoints: [], retentionTrend: null, cgroupEventsDelta: null, workload: null,
    api: { beforeStop: containerOutcome(input.beforeStopInspect), afterStop: containerOutcome(input.afterStopInspect) } };
  if (!MEMORY_SCENARIOS.includes(input.scenario) || !['amd64', 'arm64'].includes(input.architecture)
    || !['boundary', 'long', 'soak'].includes(mode) || (mode !== 'boundary' && !REPEAT_SCENARIOS.includes(input.scenario))) {
    fail('scenario_configuration_invalid'); return result;
  }
  if (exact(input.ready, ['schemaVersion', 'kind', 'runtime', 'baseline']) && input.ready.schemaVersion === '1' && input.ready.kind === 'ready') {
    result.runtime = parseRuntime(input.ready.runtime, input.architecture);
    result.baseline = parseMemory(input.ready.baseline);
  }
  if (!result.runtime) fail('runtime_invalid');
  if (!result.baseline) fail('baseline_memory_invalid');
  result.memory = parseMemory(input.memory);
  if (!result.memory) fail('final_memory_invalid');
  const parsedCheckpoints = parseCheckpoints(input.checkpoints, mode);
  if (!parsedCheckpoints.valid) fail('iteration_checkpoints_invalid');
  result.checkpoints = parsedCheckpoints.checkpoints;
  const snapshots = [result.baseline, ...result.checkpoints.map(item => item.memory), result.memory];
  let previous: LinuxMemorySnapshot | null = null;
  for (const snapshot of snapshots) {
    if (!snapshot) continue;
    if (snapshot.cgroup.events.oom !== 0 || snapshot.cgroup.events.oom_kill !== 0
      || (snapshot.cgroup.events.oom_group_kill ?? 0) !== 0) fail('oom_detected');
    if (snapshot.cgroup.events.max !== 0) fail('cgroup_hard_limit_pressure_detected');
    if (snapshot.maxRssBytes > PROFILE_TARGET_BYTES) fail('rss_headroom_target_exceeded');
    if (snapshot.cgroup.peakBytes > PROFILE_TARGET_BYTES) fail('cgroup_headroom_target_exceeded');
    if (snapshot.maxRssBytes >= PROFILE_SERVICE_BYTES || snapshot.cgroup.peakBytes >= snapshot.cgroup.limitBytes) fail('service_reference_exceeded');
    if (previous && (snapshot.maxRssBytes < previous.maxRssBytes || snapshot.cgroup.peakBytes < previous.cgroup.peakBytes
      || snapshot.cgroup.limitBytes !== previous.cgroup.limitBytes || snapshot.cgroup.cpuMax !== previous.cgroup.cpuMax
      || Object.keys(previous.cgroup.events).length !== Object.keys(snapshot.cgroup.events).length
      || Object.entries(previous.cgroup.events).some(([key, count]) => snapshot.cgroup.events[key] === undefined || snapshot.cgroup.events[key] < count))) {
      fail('memory_counters_regressed');
    }
    previous = snapshot;
  }
  if (result.baseline && result.memory) {
    const a = result.baseline, b = result.memory;
    if (!failures.includes('memory_counters_regressed')) result.cgroupEventsDelta = Object.fromEntries(Object.entries(b.cgroup.events).map(([key, count]) => [key, count - (a.cgroup.events[key] ?? 0)]));
  }
  if (mode !== 'boundary' && parsedCheckpoints.valid && !failures.includes('memory_counters_regressed')) {
    result.retentionTrend = retentionTrend(result.checkpoints);
  }
  if (!validContainerConfiguration(input.beforeStopInspect) || !validContainerConfiguration(input.afterStopInspect)) fail('container_configuration_invalid');
  if (!record(input.beforeStopInspect) || !record(input.afterStopInspect) || typeof input.beforeStopInspect.Id !== 'string'
    || !/^[a-f0-9]{64}$/.test(input.beforeStopInspect.Id) || input.beforeStopInspect.Id !== input.afterStopInspect.Id) fail('container_identity_mismatch');
  if (!validContainerState(input.beforeStopInspect, true)) fail('api_not_running');
  if (!validContainerState(input.afterStopInspect, false)) fail('api_exit_failed');
  if (input.clientExitCode !== 0) fail('client_exit_failed');
  if (input.apiHealthyAfterWorkload !== true) fail('api_unhealthy');
  result.workload = parseWorkload(input.workload, input.scenario, mode);
  if (!result.workload) fail('workload_invalid');
  else {
    if (mode !== 'boundary' && result.workload.session && parsedCheckpoints.valid) {
      const session = result.workload.session;
      if (result.checkpoints.some((checkpoint, index) => checkpoint.elapsedMs < session.iterationStartElapsedMs[index]
        + result.workload!.iterationElapsedMs[index] - 1 || checkpoint.elapsedMs > session.elapsedMs
        || (index + 1 < result.workload!.iterations && checkpoint.elapsedMs > session.iterationStartElapsedMs[index + 1]))) {
        fail('checkpoint_timing_invalid'); result.retentionTrend = null;
      }
    }
    const required = [...COMMON_ASSERTIONS, ...(input.scenario.startsWith('pdf-') ? PDF_ASSERTIONS
      : input.scenario.startsWith('upload-') ? UPLOAD_ASSERTIONS : REJECTION_ASSERTIONS),
    ...(mode !== 'boundary' ? LONG_ASSERTIONS : []), ...(mode !== 'boundary' && input.scenario.startsWith('pdf-') ? LONG_PDF_ASSERTIONS : []),
    ...(mode === 'soak' && input.scenario.startsWith('pdf-') ? SOAK_PDF_ASSERTIONS : [])];
    if (!exact(result.workload.assertions, required)) fail('workload_assertions_incomplete');
    if (!record(input.workload) || input.workload.status !== 'passed'
      || Object.values(result.workload.assertions).some(flag => flag !== true)) fail('workload_failed');
  }
  result.status = failures.length === 0 ? 'passed' : 'failed';
  return result;
}
