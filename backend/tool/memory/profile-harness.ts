import { spawn } from 'node:child_process';
import { chmod, mkdtemp, rm } from 'node:fs/promises';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROFILE_NODE_VERSION = '24.22.0';
export const PROFILE_WORKER_NODE_ARGS = ['--max-old-space-size=64', '--max-semi-space-size=1'] as const;
export const PROFILE_TARGET_BYTES = 400_000_000;
export const PROFILE_SERVICE_BYTES = 500_000_000;
export const PROFILE_STDOUT_BYTES = 256 * 1024;
export const PROFILE_STDERR_BYTES = 64 * 1024;
export const PROFILE_CHILD_TIMEOUT_MS = 180_000;
export const MEMORY_SCENARIOS = ['pdf-solid-16mp', 'pdf-alpha-16mp', 'pdf-six-16mp', 'pdf-near24mb',
  'upload-near8mb-jpeg', 'upload-16mp-jpeg', 'upload-repeat-16mp', 'pdf-repeat-16mp', 'reject-oversize'] as const;
export type MemoryScenario = typeof MEMORY_SCENARIOS[number];
type Failure = 'spawn_failed' | 'timed_out' | 'output_limit' | 'aborted' | 'invalid_report' | 'nonzero_exit'
  | 'worker_failed' | 'assertion_failed' | 'headroom_target_exceeded' | 'service_reference_exceeded';
export interface MemoryWorkerReport {
  schemaVersion: '1'; scenario: MemoryScenario; status: 'passed' | 'failed'; iterations: number;
  memory: { startupRssBytes: number; baselineRssBytes: number; finalRssBytes: number; maxRssKiB: number;
    maxRssBytes: number; iterationRssBytes: number[] };
  workload: { inputBytes: number; selectedEvidenceBytes: number; selectedEvidencePixels: number };
  assertions: Record<string, boolean>;
}
export interface FixtureReport { schemaVersion: '1'; status: 'prepared'; files: number; bytes: number }
export interface ChildRequest { kind: 'fixture' | 'worker'; directory: string; scenario?: MemoryScenario }
export interface ChildResult { exitCode: number | null; stdout: Buffer; failure?: 'spawn_failed' | 'timed_out' | 'output_limit' | 'aborted' }
export interface ProfileReport {
  schemaVersion: '1'; status: 'passed' | 'failed'; capturedAt: string;
  runtime: { node: string; platform: string; arch: string; workerExecArgv: string[] };
  source: 'generated_fictional_local_only';
  interpretation: 'local_process_peak_not_linux_container_or_hosting_certification';
  thresholds: { headroomTargetBytes: number; serviceReferenceBytes: number };
  fixture: { status: 'prepared' | 'failed'; failures: Failure[]; report: FixtureReport | null };
  scenarios: { scenario: MemoryScenario; status: 'passed' | 'failed'; failures: Failure[];
    worker: MemoryWorkerReport | null; remainingReferenceBytes: number | null }[];
  cleanup: 'removed' | 'failed' | 'not_created';
}
export interface ProfileDependencies {
  createDirectory(): Promise<string>;
  removeDirectory(directory: string): Promise<void>;
  runChild(request: ChildRequest, signal?: AbortSignal): Promise<ChildResult>;
  now(): Date;
}
export class MemoryProfileError extends Error {
  constructor() { super('Memory profile report or local runtime is invalid.'); this.name = 'MemoryProfileError'; }
}
function check(value: unknown): asserts value { if (!value) throw new MemoryProfileError(); }
function exact(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
function integer(value: unknown, maximum = Number.MAX_SAFE_INTEGER): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0 && Number(value) <= maximum;
}
function parse(bytes: Buffer): unknown {
  check(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= PROFILE_STDOUT_BYTES);
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}
export function parseFixtureReport(bytes: Buffer): FixtureReport {
  try {
    const value = parse(bytes);
    check(exact(value, ['schemaVersion', 'status', 'files', 'bytes']) && value.schemaVersion === '1'
      && value.status === 'prepared' && integer(value.files, 64) && value.files > 0
      && integer(value.bytes, 1024 * 1024 * 1024) && value.bytes > 0);
    return value as unknown as FixtureReport;
  } catch { throw new MemoryProfileError(); }
}
export function parseMemoryWorkerReport(bytes: Buffer, scenario: MemoryScenario): MemoryWorkerReport {
  try {
    const value = parse(bytes);
    check(exact(value, ['schemaVersion', 'scenario', 'status', 'iterations', 'memory', 'workload', 'assertions'])
      && value.schemaVersion === '1' && value.scenario === scenario && (value.status === 'passed' || value.status === 'failed')
      && value.iterations === (scenario === 'pdf-repeat-16mp' || scenario === 'upload-repeat-16mp' ? 3 : 1));
    const memory = value.memory;
    check(exact(memory, ['startupRssBytes', 'baselineRssBytes', 'finalRssBytes', 'maxRssKiB', 'maxRssBytes', 'iterationRssBytes'])
      && ['startupRssBytes', 'baselineRssBytes', 'finalRssBytes', 'maxRssKiB', 'maxRssBytes'].every(key => integer(memory[key]) && Number(memory[key]) > 0)
      && Array.isArray(memory.iterationRssBytes) && memory.iterationRssBytes.length === value.iterations
      && memory.iterationRssBytes.every(item => integer(item) && item > 0)
      && memory.maxRssBytes === Number(memory.maxRssKiB) * 1024);
    check(Number(memory.maxRssBytes) >= Math.max(Number(memory.startupRssBytes), Number(memory.baselineRssBytes),
      Number(memory.finalRssBytes), ...memory.iterationRssBytes));
    check(exact(value.workload, ['inputBytes', 'selectedEvidenceBytes', 'selectedEvidencePixels'])
      && Object.values(value.workload).every(item => integer(item)));
    const assertions = value.assertions;
    check(assertions !== null && typeof assertions === 'object' && !Array.isArray(assertions)
      && Object.keys(assertions).length > 0 && Object.keys(assertions).length <= 64
      && Object.entries(assertions).every(([key, item]) => /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(key) && typeof item === 'boolean'));
    return value as unknown as MemoryWorkerReport;
  } catch { throw new MemoryProfileError(); }
}

export function profileChildEnvironment(execPath = process.execPath): NodeJS.ProcessEnv {
  return { PATH: dirname(execPath), LANG: 'C', LC_ALL: 'C', TZ: 'UTC' };
}
export interface BoundedChildOptions { timeoutMs?: number; stdoutBytes?: number; stderrBytes?: number; signal?: AbortSignal }

export async function runBoundedProfileChild(args: readonly string[], options: BoundedChildOptions = {}): Promise<ChildResult> {
  const timeoutMs = options.timeoutMs ?? PROFILE_CHILD_TIMEOUT_MS;
  const stdoutBytes = options.stdoutBytes ?? PROFILE_STDOUT_BYTES, stderrBytes = options.stderrBytes ?? PROFILE_STDERR_BYTES;
  check(integer(timeoutMs, PROFILE_CHILD_TIMEOUT_MS) && timeoutMs > 0
    && integer(stdoutBytes, PROFILE_STDOUT_BYTES) && stdoutBytes > 0
    && integer(stderrBytes, PROFILE_STDERR_BYTES) && stderrBytes > 0);
  if (options.signal?.aborted) return { exitCode: null, stdout: Buffer.alloc(0), failure: 'aborted' };
  return new Promise(resolve => {
    const stdout: Buffer[] = []; let size = 0, errorSize = 0;
    let failure: ChildResult['failure']; let forcedKill: NodeJS.Timeout | undefined;
    const child = spawn(process.execPath, [...args], { env: profileChildEnvironment(), stdio: ['ignore', 'pipe', 'pipe'],
      cwd: fileURLToPath(new URL('../../', import.meta.url)), shell: false });
    const stop = (reason: NonNullable<ChildResult['failure']>) => {
      if (failure) return; failure = reason;
      child.kill('SIGTERM');
      forcedKill = setTimeout(() => child.kill('SIGKILL'), 1000);
      forcedKill.unref();
    };
    const timer = setTimeout(() => stop('timed_out'), timeoutMs); timer.unref();
    const abort = () => stop('aborted'); options.signal?.addEventListener('abort', abort, { once: true });
    child.stdout.on('data', (chunk: Buffer) => {
      if (size + chunk.length > stdoutBytes) { stop('output_limit'); return; }
      size += chunk.length; stdout.push(chunk);
    });
    child.stderr.on('data', (chunk: Buffer) => { errorSize += chunk.length; if (errorSize > stderrBytes) stop('output_limit'); });
    child.on('error', () => { failure ??= 'spawn_failed'; });
    child.on('close', code => {
      clearTimeout(timer); if (forcedKill) clearTimeout(forcedKill);
      options.signal?.removeEventListener('abort', abort);
      resolve({ exitCode: code, stdout: Buffer.concat(stdout), ...(failure ? { failure } : {}) });
    });
  });
}

const defaults: ProfileDependencies = {
  async createDirectory() {
    const directory = await mkdtemp('/tmp/sah-memory-');
    try { await chmod(directory, 0o700); return directory; }
    catch { await rm(directory, { recursive: true, force: true }); throw new MemoryProfileError(); }
  },
  async removeDirectory(directory) { await rm(directory, { recursive: true, force: true }); },
  runChild(request, signal) {
    const script = fileURLToPath(new URL(request.kind === 'fixture' ? './fixture.ts' : './worker.ts', import.meta.url));
    return runBoundedProfileChild(request.kind === 'fixture' ? [script, request.directory]
      : [...PROFILE_WORKER_NODE_ARGS, script, request.scenario!, request.directory], { signal });
  },
  now: () => new Date(),
};

export async function runMemoryProfile(deps: ProfileDependencies = defaults, signal?: AbortSignal): Promise<ProfileReport> {
  const report: ProfileReport = { schemaVersion: '1', status: 'failed', capturedAt: deps.now().toISOString(),
    runtime: { node: process.versions.node, platform: process.platform, arch: process.arch,
      workerExecArgv: [...PROFILE_WORKER_NODE_ARGS] }, source: 'generated_fictional_local_only',
    interpretation: 'local_process_peak_not_linux_container_or_hosting_certification',
    thresholds: { headroomTargetBytes: PROFILE_TARGET_BYTES, serviceReferenceBytes: PROFILE_SERVICE_BYTES },
    fixture: { status: 'failed', failures: [], report: null }, scenarios: [], cleanup: 'not_created' };
  let directory: string | undefined;
  try {
    directory = await deps.createDirectory();
    const prepared = await deps.runChild({ kind: 'fixture', directory }, signal);
    if (prepared.failure) report.fixture.failures.push(prepared.failure);
    if (prepared.exitCode !== 0) report.fixture.failures.push('nonzero_exit');
    try { report.fixture.report = parseFixtureReport(prepared.stdout); }
    catch { report.fixture.failures.push('invalid_report'); }
    if (report.fixture.failures.length > 0) return report;
    report.fixture.status = 'prepared';
    for (const scenario of MEMORY_SCENARIOS) {
      const result: ProfileReport['scenarios'][number] = { scenario, status: 'failed', failures: [], worker: null, remainingReferenceBytes: null };
      report.scenarios.push(result);
      let child: ChildResult;
      try { child = await deps.runChild({ kind: 'worker', directory, scenario }, signal); }
      catch { child = { exitCode: null, stdout: Buffer.alloc(0), failure: 'spawn_failed' }; }
      if (child.failure) result.failures.push(child.failure);
      if (child.exitCode !== 0) result.failures.push('nonzero_exit');
      try { result.worker = parseMemoryWorkerReport(child.stdout, scenario); }
      catch { result.failures.push('invalid_report'); }
      if (result.worker) {
        if (result.worker.status !== 'passed') result.failures.push('worker_failed');
        if (!Object.values(result.worker.assertions).every(Boolean)) result.failures.push('assertion_failed');
        const peak = result.worker.memory.maxRssBytes;
        result.remainingReferenceBytes = PROFILE_SERVICE_BYTES - peak;
        if (peak > PROFILE_TARGET_BYTES) result.failures.push('headroom_target_exceeded');
        if (peak >= PROFILE_SERVICE_BYTES) result.failures.push('service_reference_exceeded');
      }
      if (result.failures.length === 0) result.status = 'passed';
      if (signal?.aborted) break;
    }
  } catch { report.fixture.failures.push('spawn_failed'); }
  finally {
    if (directory) try { await deps.removeDirectory(directory); report.cleanup = 'removed'; }
    catch { report.cleanup = 'failed'; }
    report.status = report.fixture.status === 'prepared' && report.fixture.failures.length === 0
      && report.scenarios.length === MEMORY_SCENARIOS.length && report.scenarios.every(item => item.status === 'passed')
      && report.cleanup === 'removed' ? 'passed' : 'failed';
  }
  return report;
}
