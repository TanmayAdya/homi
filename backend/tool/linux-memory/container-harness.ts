import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmod, cp, lstat, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SCENARIOS, type Scenario } from '../memory/workload.ts';
import { assertLinuxMemoryStartup, evaluateLinuxMemoryScenario, type LinuxMemoryScenarioInput } from './report.ts';
import { sessionConfiguration, SOAK_CLIENT_DEADLINE_MS, SOAK_PROFILE_DEADLINE_MS, type SessionMode } from './protocol.ts';

const BACKEND = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const FIXTURES = '/lab/sah-memory-fixtures';
const LABEL = 'safeathome.synthetic-memory';
const NODE_IMAGE = 'node:24.22.0-bookworm-slim';
const POSTGRES_IMAGE = 'postgres:18.4-bookworm';
export interface LinuxOptions {
  socket: string; architecture: 'amd64' | 'arm64'; emulation: 'none' | 'qemu-system';
  output: string; scenarios: Scenario[]; docker: string; openssl: string;
  mode: SessionMode;
  imageSource?: 'registry' | 'cache';
}
export function parseLinuxOptions(args: string[]): LinuxOptions {
  const values: Record<string, string> = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i], value = args[i + 1];
    if (!['--socket', '--architecture', '--emulation', '--output', '--scenario', '--docker', '--openssl', '--mode', '--image-source'].includes(key)
      || !value || value.startsWith('--') || Object.hasOwn(values, key)) throw new Error('Invalid Linux profile arguments.');
    values[key] = value;
  }
  const socket = values['--socket'], output = values['--output'];
  if (!socket || socket !== resolve(socket) || !output || output !== resolve(output)
    || !['amd64', 'arm64'].includes(values['--architecture'])
    || !['none', 'qemu-system'].includes(values['--emulation'])) throw new Error('Explicit local socket, architecture, emulation and report path required.');
  if (dirname(output) !== join(BACKEND, 'local-artifacts') || !/^[A-Za-z0-9_-]+\.json$/.test(output.split('/').at(-1)!)) {
    throw new Error('Report must be a new JSON file directly under backend/local-artifacts.');
  }
  const selected = values['--scenario'] ?? 'all';
  if (selected !== 'all' && !SCENARIOS.includes(selected as Scenario)) throw new Error('Unknown scenario.');
  const mode = values['--mode'] ?? 'boundary';
  if (mode !== 'boundary' && mode !== 'long' && mode !== 'soak') throw new Error('Unknown session mode.');
  if (mode === 'soak' && values['--emulation'] !== 'none') throw new Error('Soak requires a native local Linux engine.');
  const imageSource = values['--image-source'] ?? 'registry';
  if (imageSource !== 'registry' && imageSource !== 'cache') throw new Error('Unknown image source.');
  const repeated: Scenario[] = ['upload-repeat-16mp', 'pdf-repeat-16mp'];
  if (mode !== 'boundary' && selected !== 'all' && !repeated.includes(selected as Scenario)) throw new Error('Paced sessions require a repeated upload or PDF scenario.');
  return { socket, output, architecture: values['--architecture'] as LinuxOptions['architecture'],
    emulation: values['--emulation'] as LinuxOptions['emulation'], mode, imageSource,
    scenarios: selected === 'all' ? mode !== 'boundary' ? repeated : [...SCENARIOS] : [selected as Scenario],
    docker: values['--docker'] ?? 'docker', openssl: values['--openssl'] ?? 'openssl' };
}
export interface CommandResult { code: number | null; stdout: string; stderr: string; timedOut: boolean }
export function runCommand(file: string, args: string[], env: NodeJS.ProcessEnv, timeoutMs = 120_000,
  signal?: AbortSignal, onStdout?: (chunk: string) => void): Promise<CommandResult> {
  return new Promise((resolveResult, reject) => {
    const child = spawn(file, args, { shell: false, env, stdio: ['ignore', 'pipe', 'pipe'] });
    const cancel = () => child.kill('SIGKILL');
    signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) cancel();
    let stdout = '', stderr = '', timedOut = false, overflow = false, observerFailed = false;
    const append = (isError: boolean, data: Buffer) => {
      if (stdout.length + stderr.length + data.length > 2 * 1024 * 1024) { overflow = true; child.kill('SIGKILL'); return; }
      if (isError) stderr += data.toString('utf8'); else {
        const text = data.toString('utf8'); stdout += text;
        try { onStdout?.(text); } catch { observerFailed = true; child.kill('SIGKILL'); }
      }
    };
    child.stdout.on('data', data => append(false, data)); child.stderr.on('data', data => append(true, data));
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, timeoutMs);
    child.on('error', error => { clearTimeout(timer); signal?.removeEventListener('abort', cancel); reject(error); });
    child.on('close', code => { clearTimeout(timer); signal?.removeEventListener('abort', cancel); resolveResult({ code: overflow || observerFailed || signal?.aborted ? -1 : code, stdout, stderr, timedOut }); });
  });
}
export function localDockerEnvironment(socket: string, config: string): NodeJS.ProcessEnv {
  return { PATH: process.env.PATH, DOCKER_HOST: `unix://${socket}`, DOCKER_CONFIG: config, DOCKER_BUILDKIT: '0' };
}
export function apiContainerArgs(name: string, network: string, volume: string, image: string, runId: string): string[] {
  return ['create', '--name', name, '--label', `${LABEL}=${runId}`, '--network', network, '--network-alias', 'api',
    '--memory', '500000000', '--memory-swap', '500000000', '--cpus', '1', '--pids-limit', '128',
    '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--restart', 'no',
    '--user', '1000:1000', '--tmpfs', '/tmp:rw,noexec,nosuid,size=16777216',
    '--mount', `type=volume,src=${volume},dst=/lab,readonly`, image,
    'node', '--max-old-space-size=64', '--max-semi-space-size=1', 'tool/linux-memory/server.ts'];
}
function jsonLines(output: string, kind: string): unknown | undefined {
  return allJsonLines(output, kind).reverse()[0];
}
function allJsonLines(output: string, kind: string): unknown[] {
  return output.split('\n').filter(line => line.startsWith('{')).map(line => {
    try { return JSON.parse(line); } catch { return undefined; }
  }).filter(value => value?.kind === kind);
}
export function parseCheckpointProgress(line: string, scenario: Scenario, expectedIteration: number,
  mode: Exclude<SessionMode, 'boundary'> = 'long'): { iteration: number; elapsedMs: number } | undefined {
  if (!line.startsWith('{')) return;
  const value = JSON.parse(line);
  if (value.kind !== 'workload-progress') return;
  const keys = ['schemaVersion', 'kind', 'scenario', 'mode', 'iteration', 'plannedIterations', 'iterationElapsedMs', 'elapsedMs'];
  if (Object.keys(value).length !== keys.length || !keys.every(key => Object.hasOwn(value, key))
    || value.schemaVersion !== '1' || value.scenario !== scenario || value.mode !== mode
    || value.plannedIterations !== sessionConfiguration(mode).iterations || value.iteration !== expectedIteration
    || expectedIteration < 1 || expectedIteration > sessionConfiguration(mode).iterations
    || !Number.isSafeInteger(value.elapsedMs) || value.elapsedMs < 1
    || !Number.isSafeInteger(value.iterationElapsedMs) || value.iterationElapsedMs < 1) throw new Error('Invalid session checkpoint progress.');
  return { iteration: value.iteration, elapsedMs: value.elapsedMs };
}
export async function createProgressWriter(output: string) {
  const path = `${output}.progress.json`;
  await writeFile(path, '', { flag: 'wx', mode: 0o600 });
  return async (value: unknown) => {
    const temporary = `${path}.${randomBytes(6).toString('hex')}.tmp`;
    try {
      await writeFile(temporary, JSON.stringify(value, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
      await rename(temporary, path);
    } finally { await rm(temporary, { force: true }); }
  };
}
const delay = (ms: number) => new Promise(resolveDelay => setTimeout(resolveDelay, ms));

type MeasuredScenario = Pick<LinuxMemoryScenarioInput,
  'scenario' | 'architecture' | 'expectedMode' | 'ready' | 'checkpoints' | 'workload' | 'clientExitCode'>;
interface ScenarioFinalization {
  inspect: () => Promise<unknown>;
  snapshot: () => Promise<unknown>;
  stop: () => Promise<void>;
}
function inspectionRunning(value: unknown): boolean | undefined {
  if (!value || typeof value !== 'object' || !('State' in value) || !value.State || typeof value.State !== 'object'
    || !('Running' in value.State) || typeof value.State.Running !== 'boolean') return;
  return value.State.Running;
}

export async function finalizeMeasuredScenario(input: MeasuredScenario, operations: ScenarioFinalization) {
  let before: unknown, after: unknown, memory: unknown;
  const failures: string[] = [];
  try { before = await operations.inspect(); } catch { failures.push('api_initial_inspection_failed'); }
  if (inspectionRunning(before) === true) {
    try { memory = await operations.snapshot(); } catch { failures.push('final_memory_capture_failed'); }
  }
  if (inspectionRunning(before) !== false) {
    try { await operations.stop(); } catch { failures.push('api_graceful_stop_failed'); }
  }
  try { after = await operations.inspect(); } catch { failures.push('api_final_inspection_failed'); }
  const workload = input.workload as { assertions?: Record<string, boolean> } | undefined;
  const result = evaluateLinuxMemoryScenario({ ...input, memory, beforeStopInspect: before, afterStopInspect: after,
    apiHealthyAfterWorkload: inspectionRunning(before) === true && workload?.assertions?.ordinaryReadAccepted === true
      && workload?.assertions?.workerCompleted === true });
  if (failures.length) { result.failures.push(...failures); result.status = 'failed'; }
  return result;
}

export async function profileLinux(options: LinuxOptions): Promise<boolean> {
  const socket = await lstat(options.socket);
  if (!socket.isSocket() || socket.isSymbolicLink() || ![0, process.getuid?.()].includes(socket.uid)) {
    throw new Error('User-owned or root-owned local Unix Docker socket required.');
  }
  const artifactDirectory = dirname(options.output);
  await mkdir(artifactDirectory, { recursive: true, mode: 0o700 });
  const artifactStat = await lstat(artifactDirectory);
  if (!artifactStat.isDirectory() || artifactStat.isSymbolicLink() || artifactStat.uid !== process.getuid?.()) throw new Error('Unsafe report directory.');
  const reportHandle = await import('node:fs/promises').then(fs => fs.open(options.output, 'wx', 0o600));
  const temporary = await mkdtemp(join(artifactDirectory, 'sah-linux-memory-'));
  await chmod(temporary, 0o700);
  const config = join(temporary, 'docker-config'); await mkdir(config, { mode: 0o700 });
  const env = localDockerEnvironment(options.socket, config);
  const id = `sah-memory-${randomBytes(6).toString('hex')}`;
  const resources: { kind: 'container' | 'volume' | 'network' | 'image'; name: string }[] = [];
  const abort = new AbortController();
  const cancel = () => abort.abort();
  let deadlineExceeded = false;
  const deadline = options.mode === 'soak' ? setTimeout(() => {
    deadlineExceeded = true; abort.abort();
  }, SOAK_PROFILE_DEADLINE_MS) : undefined;
  deadline?.unref();
  process.on('SIGINT', cancel); process.on('SIGTERM', cancel);
  const report: Record<string, unknown> = { schemaVersion: '1', kind: 'linux-memory-profile', status: 'failed',
    startedAt: new Date().toISOString(), architecture: options.architecture, emulation: options.emulation, mode: options.mode,
    imageSource: options.imageSource ?? 'registry',
    host: { platform: process.platform, arch: process.arch }, targetBytes: 400_000_000, limitBytes: 500_000_000,
    cases: [], cleanup: { status: 'pending' }, boundaries: ['synthetic auth transport', 'internal HTTP, verified database TLS',
      'API cgroup excludes PostgreSQL/client/fixture generation',
      'no production API or Supabase/Railway requests; hosted runner usage may apply'] };
  let writeProgress: Awaited<ReturnType<typeof createProgressWriter>> | undefined;
  let active: { scenario: Scenario; checkpoints: { iteration: number; elapsedMs: number; memory: unknown }[] } | null = null;
  const progress = async (status: 'running' | 'passed' | 'failed', phase: 'setup' | 'scenario' | 'cleanup' | 'finished') => {
    await writeProgress?.({ schemaVersion: '1', kind: 'linux-memory-progress', status, phase, pid: process.pid,
      startedAt: report.startedAt, updatedAt: new Date().toISOString(), mode: options.mode, architecture: options.architecture,
      plannedScenarios: options.scenarios.length,
      plannedIterations: options.mode === 'boundary' ? null : sessionConfiguration(options.mode).iterations,
      deadlineAt: options.mode === 'soak' ? new Date(Date.parse(String(report.startedAt)) + SOAK_PROFILE_DEADLINE_MS).toISOString() : null,
      completedCases: report.cases, active, cleanup: report.cleanup });
  };
  const checked = async (args: string[], timeout = 120_000) => {
    if (abort.signal.aborted) throw new Error('Linux profile interrupted; cleaning up owned resources.');
    const result = await runCommand(options.docker, args, env, timeout, abort.signal);
    if (result.code !== 0 || result.timedOut) {
      await writeFile(join(temporary, 'last-command-error.txt'), result.stderr + result.stdout, { mode: 0o600 });
      throw new Error(`Docker ${args[0]} failed${result.timedOut ? ' (deadline)' : ''}; inspect the private diagnostic directory.`);
    }
    return result.stdout;
  };
  const create = async (kind: 'container' | 'volume' | 'network', name: string, args: string[]) => {
    resources.push({ kind, name }); return checked(args, 300_000);
  };
  const inspect = async (name: string) => JSON.parse(await checked(['inspect', name]))[0];
  const waitFor = async (description: string, check: () => Promise<boolean>, milliseconds = 180_000) => {
    const end = Date.now() + milliseconds;
    do { if (await check()) return; await delay(500); } while (Date.now() < end);
    throw new Error(`${description} deadline exceeded.`);
  };
  const toolContainer = async (suffix: string, network: string, volume: string, image: string, command: string[], user = '1000:1000',
    onLine?: (line: string) => Promise<void>) => {
    const name = `${id}-${suffix}`;
    await create('container', name, ['create', '--name', name, '--label', `${LABEL}=${id}`, '--network', network,
      '--memory', '1200000000', '--memory-swap', '1200000000', '--cpus', '1', '--pids-limit', '128',
      '--read-only', '--security-opt', 'no-new-privileges', '--user', user,
      '--mount', `type=volume,src=${volume},dst=/lab${suffix === 'prepare' ? '' : ',readonly'}`,
      '--tmpfs', '/tmp:rw,noexec,nosuid,size=16777216', image, ...command]);
    let remaining = '', observed: Promise<void> = Promise.resolve(), observationError: unknown;
    const result = await runCommand(options.docker, ['start', '--attach', name], env,
      options.mode === 'soak' && suffix.startsWith('client-') ? SOAK_CLIENT_DEADLINE_MS : 600_000, abort.signal, onLine ? chunk => {
      remaining += chunk;
      const lines = remaining.split('\n'); remaining = lines.pop()!;
      for (const line of lines) observed = observed.then(async () => {
        if (!observationError) await onLine(line);
      }).catch(error => { observationError = error; });
    } : undefined);
    await observed;
    await writeFile(join(temporary, `${suffix}-log.txt`), result.stdout + result.stderr, { mode: 0o600 });
    const state = (await inspect(name)).State;
    if (state.Running) await checked(['stop', '--time', '10', name]);
    if (observationError) console.error('Session checkpoint observation failed; retaining partial measurements as a failed run.');
    return { ...result, code: observationError || result.code !== 0 || state.Running || state.OOMKilled || result.timedOut ? -1 : state.ExitCode };
  };
  let success = false;
  try {
    if (options.mode === 'soak') writeProgress = await createProgressWriter(options.output);
    await progress('running', 'setup');
    const info = JSON.parse(await checked(['info', '--format', '{{json .}}']));
    const expected = options.architecture === 'amd64' ? ['x86_64', 'amd64'] : ['aarch64', 'arm64'];
    if (info.OSType !== 'linux' || !expected.includes(info.Architecture) || info.CgroupVersion !== '2') throw new Error('Matching Linux architecture and cgroup v2 required.');
    report.engine = { version: info.ServerVersion, architecture: info.Architecture, kernel: info.KernelVersion, cgroupVersion: info.CgroupVersion };
    const imageDetails: Record<string, unknown> = {};
    for (const tag of [NODE_IMAGE, POSTGRES_IMAGE]) {
      if (options.imageSource === 'cache') console.log(`Inspecting cached ${tag} for linux/${options.architecture}.`);
      else {
        console.log(`Pulling public ${tag} for linux/${options.architecture}.`);
        await checked(['pull', '--platform', `linux/${options.architecture}`, tag], 600_000);
      }
      const image = JSON.parse(await checked(['image', 'inspect', tag]))[0];
      if (image.Architecture !== options.architecture || image.Os !== 'linux' || !image.RepoDigests?.length) throw new Error('Pinned image identity unavailable.');
      imageDetails[tag] = { id: image.Id, digest: image.RepoDigests[0], architecture: image.Architecture };
    }
    report.images = imageDetails;
    const context = join(temporary, 'runtime-context'); await mkdir(context, { mode: 0o700 });
    for (const path of ['package.json', 'package-lock.json', 'src', 'migrations', 'certs/supabase-root-2021.crt', 'assets/forms/scfhp-41567.pdf']) {
      await mkdir(dirname(join(context, path)), { recursive: true }); await cp(join(BACKEND, path), join(context, path), { recursive: true, dereference: false });
    }
    const nodeDigest = (imageDetails[NODE_IMAGE] as { digest: string }).digest;
    const productionDockerfile = await readFile(join(BACKEND, 'Dockerfile'), 'utf8');
    if (!productionDockerfile.startsWith(`FROM ${NODE_IMAGE}\n`)) throw new Error('Runtime image version changed; update the Linux profile.');
    await writeFile(join(context, 'Dockerfile'), productionDockerfile.replace(`FROM ${NODE_IMAGE}`, `FROM ${nodeDigest}`));
    const runtimeImage = `${id}-runtime`, labImage = `${id}-lab`;
    resources.push({ kind: 'image', name: runtimeImage });
    console.log('Building the production runtime from public allowlisted inputs.');
    await checked(['build', '--force-rm', '--platform', `linux/${options.architecture}`, '--label', `${LABEL}=${id}`, '--tag', runtimeImage, context], 900_000);
    const labContext = join(temporary, 'lab-context'); await mkdir(labContext, { mode: 0o700 });
    for (const name of ['memory', 'linux-memory']) await cp(join(BACKEND, 'tool', name), join(labContext, 'tool', name), { recursive: true });
    await writeFile(join(labContext, 'Dockerfile'), `FROM ${runtimeImage}\nCOPY --chown=node:node tool ./tool\n`);
    resources.push({ kind: 'image', name: labImage });
    await checked(['build', '--force-rm', '--platform', `linux/${options.architecture}`, '--label', `${LABEL}=${id}`, '--tag', labImage, labContext], 300_000);
    report.runtimeImage = (await inspect(runtimeImage)).Id; report.labImage = (await inspect(labImage)).Id;
    const tls = join(temporary, 'tls'); await mkdir(tls, { mode: 0o700 });
    const generated = await runCommand(options.openssl, ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=postgres', '-addext', 'subjectAltName=DNS:postgres', '-keyout', join(tls, 'server.key'), '-out', join(tls, 'server.crt')], { PATH: process.env.PATH });
    if (generated.code !== 0) throw new Error('Disposable TLS certificate generation failed.');
    await chmod(join(tls, 'server.key'), 0o600);
    const network = `${id}-net`, volume = `${id}-fixtures`, certVolume = `${id}-certs`;
    await create('network', network, ['network', 'create', '--internal', '--label', `${LABEL}=${id}`, network]);
    for (const name of [volume, certVolume]) await create('volume', name, ['volume', 'create', '--label', `${LABEL}=${id}`, name]);
    const copyContainer = `${id}-copy`;
    await create('container', copyContainer, ['create', '--name', copyContainer, '--label', `${LABEL}=${id}`, '--network', 'none',
      '--user', '0:0', '--mount', `type=volume,src=${volume},dst=/lab`, '--mount', `type=volume,src=${certVolume},dst=/tls`,
      labImage, 'node', '-e', "const fs=require('node:fs');for(const f of ['server.key','server.crt']){fs.chownSync('/tls/'+f,999,999);fs.chmodSync('/tls/'+f,0o600)}fs.chmodSync('/lab/ca.crt',0o444)"]);
    await checked(['cp', join(tls, 'server.key'), `${copyContainer}:/tls/server.key`]);
    await checked(['cp', join(tls, 'server.crt'), `${copyContainer}:/tls/server.crt`]);
    await checked(['cp', join(tls, 'server.crt'), `${copyContainer}:/lab/ca.crt`]);
    await checked(['start', '--attach', copyContainer]);
    console.log('Generating fictional boundary images outside the measured API container.');
    const prepared = await toolContainer('prepare', network, volume, labImage, ['node', 'tool/linux-memory/prepare.ts'], '0:0');
    if (prepared.code !== 0) throw new Error('Synthetic fixture preparation failed.');
    report.fixtures = JSON.parse(prepared.stdout.trim());
    for (const [index, scenario] of options.scenarios.entries()) {
      console.log(`Measuring ${scenario} (${index + 1}/${options.scenarios.length}).`);
      const db = `${id}-db-${index}`, data = `${id}-data-${index}`, api = `${id}-api-${index}`;
      await create('volume', data, ['volume', 'create', '--label', `${LABEL}=${id}`, data]);
      const pgDigest = (imageDetails[POSTGRES_IMAGE] as { digest: string }).digest;
      await create('container', db, ['create', '--name', db, '--label', `${LABEL}=${id}`, '--network', network, '--network-alias', 'postgres',
        '--memory', '700000000', '--memory-swap', '700000000', '--cpus', '1', '--pids-limit', '128', '--security-opt', 'no-new-privileges',
        '--mount', `type=volume,src=${data},dst=/var/lib/postgresql`, '--mount', `type=volume,src=${certVolume},dst=/tls,readonly`,
        '--env', 'POSTGRES_DB=safememory', '--env', 'POSTGRES_PASSWORD=sah-synthetic-admin', pgDigest,
        'postgres', '-c', 'ssl=on', '-c', 'ssl_cert_file=/tls/server.crt', '-c', 'ssl_key_file=/tls/server.key',
        '-c', 'shared_buffers=32MB', '-c', 'max_connections=20']);
      await checked(['start', db]);
      await waitFor('Disposable PostgreSQL startup', async () => {
        const result = await runCommand(options.docker, ['exec', db, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'safememory'], env, 10_000);
        return result.code === 0;
      });
      const seeded = await toolContainer(`seed-${index}`, network, volume, labImage, ['node', 'tool/linux-memory/seed.ts', scenario, FIXTURES]);
      if (seeded.code !== 0) { await writeFile(join(temporary, 'seed-error.txt'), seeded.stderr + seeded.stdout, { mode: 0o600 }); throw new Error('Disposable database setup failed.'); }
      await create('container', api, apiContainerArgs(api, network, volume, labImage, id)); await checked(['start', api]);
      let ready: unknown, startupLogs = '';
      await waitFor('API startup', async () => {
        const logs = await runCommand(options.docker, ['logs', api], env, 30_000, abort.signal);
        startupLogs = logs.stdout + logs.stderr;
        ready = jsonLines(logs.stdout, 'ready');
        if (!(await inspect(api)).State.Running) {
          await writeFile(join(temporary, 'api-error.txt'), logs.stdout + logs.stderr, { mode: 0o600 });
          throw new Error('API exited before becoming ready.');
        }
        return ready !== undefined;
      });
      await writeFile(join(temporary, `api-${index}-startup-log.txt`), startupLogs, { mode: 0o600 });
      try { assertLinuxMemoryStartup(ready, options.architecture); }
      catch (error) {
        report.startupFailure = { scenario, reason: 'runtime_or_baseline_invalid', workloadStarted: false };
        throw error;
      }
      let samples = 0;
      const checkpointMemory = async () => {
        const previousCount = samples;
        await checked(['kill', '--signal', 'SIGUSR2', api]);
        let snapshot: unknown;
        await waitFor('Cgroup snapshot', async () => {
          const entries = allJsonLines(await checked(['logs', api]), 'memory');
          if (entries.length > previousCount + 1) throw new Error('Unexpected extra memory snapshot.');
          if (entries.length === previousCount + 1) { snapshot = entries[previousCount]; samples++; return true; }
          return false;
        }, 30_000);
        return snapshot;
      };
      const checkpoints: { iteration: number; elapsedMs: number; memory: unknown }[] = [];
      active = { scenario, checkpoints }; await progress('running', 'scenario');
      const onProgress = async (line: string) => {
        const checkpoint = parseCheckpointProgress(line, scenario, checkpoints.length + 1, options.mode as 'long' | 'soak');
        if (!checkpoint) return;
        const memory = await checkpointMemory();
        checkpoints.push({ ...checkpoint, memory });
        await progress('running', 'scenario');
        console.log(`Checkpoint ${checkpoint.iteration}/${sessionConfiguration(options.mode as 'long' | 'soak').iterations}: ${scenario}.`);
        await checked(['kill', '--signal', 'SIGUSR2', `${id}-client-${index}`]);
      };
      let client: CommandResult | undefined;
      const observationFailures: string[] = [];
      try {
        client = await toolContainer(`client-${index}`, network, volume, labImage,
        ['node', 'tool/linux-memory/workload.ts', scenario, FIXTURES, ...(options.mode !== 'boundary' ? [options.mode] : [])],
        '1000:1000', options.mode !== 'boundary' ? onProgress : undefined);
      } catch { observationFailures.push('client_observation_failed'); }
      try {
        const apiLogs = await runCommand(options.docker, ['logs', api], env, 30_000, abort.signal);
        await writeFile(join(temporary, `api-${index}-log.txt`), apiLogs.stdout + apiLogs.stderr, { mode: 0o600 });
        if (apiLogs.code !== 0 || apiLogs.timedOut) observationFailures.push('api_diagnostic_capture_failed');
      } catch { observationFailures.push('api_diagnostic_capture_failed'); }
      const result = await finalizeMeasuredScenario({ scenario, architecture: options.architecture, ready,
        workload: client ? jsonLines(client.stdout, 'workload') : undefined, expectedMode: options.mode, checkpoints,
        clientExitCode: client?.code ?? null }, { inspect: () => inspect(api), snapshot: checkpointMemory,
        stop: async () => { await checked(['stop', '--time', '30', api]); } });
      if (observationFailures.length) { result.failures.push(...observationFailures); result.status = 'failed'; }
      (report.cases as unknown[]).push(result);
      active = null; await progress('running', 'scenario');
      console.log(JSON.stringify(result));
      await checked(['rm', '--force', db, api]); await checked(['volume', 'rm', data]);
    }
    success = (report.cases as { status: string }[]).length === options.scenarios.length
      && (report.cases as { status: string }[]).every(value => value.status === 'passed');
  } catch (error) {
    report.error = deadlineExceeded ? 'Soak work deadline exceeded; cleaning up owned resources.'
      : error instanceof Error ? error.message : 'Linux profile failed.';
    console.error(report.error);
  } finally {
    if (deadline) clearTimeout(deadline);
    await progress('running', 'cleanup').catch(() => {
      success = false; report.error = 'Cleanup progress persistence failed.';
    });
    const failed: string[] = [];
    for (const resource of [...resources].reverse()) {
      const result = await runCommand(options.docker,
        resource.kind === 'container' ? ['rm', '--force', resource.name]
          : [resource.kind, 'rm', resource.name], env, 60_000).catch(() => undefined);
      if (!result || result.timedOut || (result.code !== 0 && !/No such (container|volume|network|image)/i.test(result.stderr))) failed.push(resource.name);
    }
    let temporaryFilesRemoved = true;
    const deletions = await Promise.allSettled(['tls', 'runtime-context', 'lab-context']
      .map(name => rm(join(temporary, name), { recursive: true, force: true })));
    if (deletions.some(result => result.status === 'rejected')) temporaryFilesRemoved = false;
    if (success && !failed.length && temporaryFilesRemoved) {
      try { await rm(temporary, { recursive: true, force: true }); }
      catch { temporaryFilesRemoved = false; }
    }
    report.cleanup = { status: failed.length || !temporaryFilesRemoved ? 'failed' : 'passed',
      remainingOwnedResources: failed, temporaryFilesRemoved };
    report.finishedAt = new Date().toISOString();
    report.status = success && !failed.length && temporaryFilesRemoved ? 'passed' : 'failed';
    if (report.status !== 'passed') report.diagnosticDirectory = basename(temporary);
    try {
      await reportHandle.writeFile(JSON.stringify(report, null, 2) + '\n'); await reportHandle.close();
      await progress(report.status as 'passed' | 'failed', 'finished');
    } catch {
      report.status = 'failed'; report.error = 'Final profile report persistence failed.';
      await reportHandle.close().catch(() => {});
      await Promise.allSettled([
        writeFile(options.output, JSON.stringify(report, null, 2) + '\n', { flag: 'w', mode: 0o600 }),
        progress('failed', 'finished'),
      ]);
    } finally {
      process.off('SIGINT', cancel); process.off('SIGTERM', cancel);
    }
  }
  return report.status === 'passed';
}
