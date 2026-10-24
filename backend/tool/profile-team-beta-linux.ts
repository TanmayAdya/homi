import { createHash, randomBytes } from 'node:crypto';
import { chmod, cp, lstat, mkdir, mkdtemp, open, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { apiContainerArgs, localDockerEnvironment, parseLinuxOptions, runCommand } from './linux-memory/container-harness.ts';
import { assertLinuxMemoryStartup, validContainerConfiguration } from './linux-memory/report.ts';
import { PROFILE_NODE_VERSION } from './memory/profile-harness.ts';
import { scenarios } from './profile-team-beta.ts';
import { createTeamProgressWriter, TEAM_SESSION, validTeamCheckpoint, validTeamSession, type TeamMemoryMode } from './memory/team-session.ts';

const BACKEND = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const NODE_IMAGE = 'node:24.22.0-bookworm-slim';
const FIXTURES = '/lab/sah-memory-fixtures';
const LABEL = 'safeathome.synthetic-team-memory';
const runtimeFiles = ['package.json', 'package-lock.json', 'src', 'migrations', 'certs/supabase-root-2021.crt',
  'assets/forms/scfhp-41567.pdf', 'assets/forms/hpsm-eaa-inert.pdf', 'assets/forms/rtp-preparation-worksheet.pdf'];

export function parseTeamLinuxOptions(args: string[]) {
  if (![6, 8].includes(args.length) || args.filter((_, index) => index % 2 === 0)
    .some(key => !['--socket', '--architecture', '--output', '--mode'].includes(key))) throw new Error('Explicit socket, architecture and new output required.');
  const parsed = parseLinuxOptions([...args, '--emulation', 'none', '--image-source', 'cache']);
  if (parsed.mode !== 'boundary' && parsed.mode !== 'soak') throw new Error('Only bounded boundary or one-hour soak mode is supported.');
  return { ...parsed, mode: parsed.mode as TeamMemoryMode };
}

export function validateTeamLinuxResult(value: any, inspection: any, scenario: string, architecture: 'arm64' | 'amd64', mode: TeamMemoryMode = 'boundary'): boolean {
  try {
    if (!value || value.scenario !== scenario || !scenarios.includes(scenario as typeof scenarios[number]) || value.status !== 'passed' ||
      !validContainerConfiguration(inspection) || inspection.State?.Running !== false || inspection.State?.Status !== 'exited' ||
      inspection.State?.ExitCode !== 0 || inspection.State?.OOMKilled !== false || inspection.State?.Dead !== false || inspection.State?.Error !== '') return false;
    const repeated = scenario === 'hpsm-near24-repeat', iterations = mode === 'soak' ? TEAM_SESSION.iterations : repeated ? 12 : 1;
    if (mode === 'soak' ? !repeated || value.mode !== 'soak' || !validTeamSession(value.session)
      : value.mode !== undefined || value.session !== undefined) return false;
    if (value.iterations !== iterations || value.selectedPhotos !== (repeated ? 1 : 6) || value.boxesPerPhoto !== 20 ||
      value.labelCharactersPerPhoto !== 800 || value.retryIdentityPreserved !== true ||
      !Number.isSafeInteger(value.selectedBytes) || value.selectedBytes < (repeated ? 23.5 * 1024 * 1024 : 1) || value.selectedBytes > 24 * 1024 * 1024 ||
      value.selectedPixels !== (repeated ? 16_000_000 : 15_996_000) ||
      !Array.isArray(value.pageCounts) || value.pageCounts.length !== iterations || value.pageCounts.some((n: unknown) => !Number.isSafeInteger(n) || Number(n) < (repeated ? 8 : scenario === 'scfhp-six' ? 12 : scenario === 'hpsm-six' ? 13 : 8)) ||
      !Array.isArray(value.iterationRssBytes) || value.iterationRssBytes.length !== iterations ||
      value.iterationRssBytes.some((n: unknown) => !Number.isSafeInteger(n) || Number(n) < 1 || Number(n) > value.peakBytes) ||
      !Number.isSafeInteger(value.peakBytes) || value.peakBytes > 400_000_000 || value.peakBytes < 1) return false;
    if (mode === 'soak' && value.session.checkpoints.some((c: any, i: number) => c.rssBytes !== value.iterationRssBytes[i]
      || c.pageCount !== value.pageCounts[i] || c.peakBytes > value.peakBytes)) return false;
    for (const baseline of [value.baseline, value.memory]) {
      assertLinuxMemoryStartup({ schemaVersion: '1', kind: 'ready', runtime: value.runtime, baseline }, architecture);
    }
    return value.memory.maxRssBytes >= value.peakBytes && value.memory.maxRssBytes >= value.baseline.maxRssBytes &&
      value.memory.cgroup.peakBytes >= value.baseline.cgroup.peakBytes;
  } catch { return false; }
}

async function sourceHashes(directory: string, prefix = ''): Promise<Record<string, string>> {
  const hashes: Record<string, string> = {};
  for (const entry of (await readdir(directory)).sort()) {
    const path = join(directory, entry), relative = prefix ? `${prefix}/${entry}` : entry;
    const stat = await lstat(path);
    if (stat.isSymbolicLink()) throw new Error('Source context must not contain symlinks.');
    if (stat.isDirectory()) Object.assign(hashes, await sourceHashes(path, relative));
    else if (stat.isFile()) hashes[relative] = createHash('sha256').update(await readFile(path)).digest('hex');
    else throw new Error('Unexpected source context entry.');
  }
  return hashes;
}

async function main() {
  if (process.versions.node !== PROFILE_NODE_VERSION) throw new Error('Use Node 24.22.0.');
  const options = parseTeamLinuxOptions(process.argv.slice(2));
  const socket = await lstat(options.socket);
  if (!socket.isSocket() || socket.isSymbolicLink() || ![0, process.getuid?.()].includes(socket.uid)) throw new Error('Local owned Docker socket required.');
  await mkdir(dirname(options.output), { recursive: true, mode: 0o700 });
  const parent = await lstat(dirname(options.output));
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== process.getuid?.()) throw new Error('Owned report directory required.');
  const output = await open(options.output, 'wx', 0o600);
  let progress: Awaited<ReturnType<typeof createTeamProgressWriter>> | undefined;
  try { progress = options.mode === 'soak' ? await createTeamProgressWriter(options.output) : undefined; }
  catch (error) { await output.close(); throw error; }
  const temporary = await mkdtemp(join(dirname(options.output), 'sah-team-memory-')); await chmod(temporary, 0o700);
  const config = join(temporary, 'docker-config'); await mkdir(config, { mode: 0o700 });
  const env = localDockerEnvironment(options.socket, config);
  const id = `sah-team-memory-${randomBytes(6).toString('hex')}`;
  const resources: { kind: 'container' | 'volume' | 'image'; name: string }[] = [];
  const abort = new AbortController(), cancel = () => abort.abort();
  const deadline = options.mode === 'soak' ? setTimeout(cancel, TEAM_SESSION.deadlineMs) : undefined;
  process.on('SIGINT', cancel); process.on('SIGTERM', cancel);
  const report: Record<string, any> = { schemaVersion: '1', status: 'failed', startedAt: new Date().toISOString(),
    scope: options.mode === 'soak' ? 'native Linux one-hour single-process v2 renderer session; synthetic memory repository; not HTTP/PostgreSQL or hosted acceptance'
      : 'native Linux synthetic memory repository; not HTTP/PostgreSQL, hosted acceptance or an hours-long soak', mode: options.mode,
    architecture: options.architecture, emulation: 'none', targetBytes: 400_000_000, limitBytes: 500_000_000,
    reports: [], cleanup: { status: 'pending' } };
  const checked = async (args: string[], timeout = 120_000) => {
    if (abort.signal.aborted) throw new Error('Interrupted.');
    const result = await runCommand(options.docker, args, env, timeout, abort.signal);
    if (result.code !== 0 || result.timedOut) {
      await writeFile(join(temporary, 'diagnostic.txt'), result.stdout + result.stderr, { mode: 0o600 });
      throw new Error('Synthetic Docker operation failed.');
    }
    return result.stdout;
  };
  const inspect = async (name: string) => JSON.parse(await checked(['inspect', name]))[0];
  const create = async (kind: 'container' | 'volume' | 'image', name: string, args: string[], timeout?: number) => {
    resources.push({ kind, name }); return checked(args, timeout);
  };
  try {
    const info = JSON.parse(await checked(['info', '--format', '{{json .}}']));
    if (info.OSType !== 'linux' || info.CgroupVersion !== '2' ||
      !(options.architecture === 'arm64' ? ['aarch64', 'arm64'] : ['x86_64', 'amd64']).includes(info.Architecture)) throw new Error('Matching native Linux engine required.');
    report.engine = { version: info.ServerVersion, architecture: info.Architecture, kernel: info.KernelVersion, cgroupVersion: info.CgroupVersion };
    const base = (await inspect(NODE_IMAGE));
    if (base.Architecture !== options.architecture || base.Os !== 'linux' || !base.RepoDigests?.length) throw new Error('Cached pinned Node image required.');
    report.baseImage = { id: base.Id, digest: base.RepoDigests[0] };
    const context = join(temporary, 'runtime'); await mkdir(context, { mode: 0o700 });
    for (const path of runtimeFiles) {
      await mkdir(dirname(join(context, path)), { recursive: true });
      await cp(join(BACKEND, path), join(context, path), { recursive: true, dereference: false });
    }
    const dockerfile = await readFile(join(BACKEND, 'Dockerfile'), 'utf8');
    if (!dockerfile.startsWith(`FROM ${NODE_IMAGE}\n`)) throw new Error('Production base changed.');
    await writeFile(join(context, 'Dockerfile'), dockerfile.replace(`FROM ${NODE_IMAGE}`, `FROM ${base.RepoDigests[0]}`));
    report.runtimeSources = await sourceHashes(context);
    const runtime = `${id}-runtime`, lab = `${id}-lab`, volume = `${id}-fixtures`;
    console.log('Building current production source and all three draft templates.');
    await create('image', runtime, ['build', '--force-rm', '--platform', `linux/${options.architecture}`, '--label', `${LABEL}=${id}`, '--tag', runtime, context], 900_000);
    report.runtimeImage = (await inspect(runtime)).Id;
    const labContext = join(temporary, 'lab'); await mkdir(labContext, { mode: 0o700 });
    for (const name of ['memory', 'linux-memory', 'profile-team-beta.ts']) {
      await cp(join(BACKEND, 'tool', name), join(labContext, 'tool', name), { recursive: true, dereference: false });
    }
    await writeFile(join(labContext, 'Dockerfile'), `FROM ${runtime}\nCOPY --chown=node:node tool ./tool\n`);
    report.labSources = await sourceHashes(labContext);
    await create('image', lab, ['build', '--force-rm', '--platform', `linux/${options.architecture}`, '--label', `${LABEL}=${id}`, '--tag', lab, labContext], 300_000);
    report.labImage = (await inspect(lab)).Id;
    await create('volume', volume, ['volume', 'create', '--label', `${LABEL}=${id}`, volume]);
    const prepare = `${id}-prepare`;
    await create('container', prepare, ['create', '--name', prepare, '--label', `${LABEL}=${id}`, '--network', 'none',
      '--memory', '1200000000', '--memory-swap', '1200000000', '--cpus', '1', '--pids-limit', '128',
      '--read-only', '--security-opt', 'no-new-privileges', '--user', '0:0', '--mount', `type=volume,src=${volume},dst=/lab`,
      '--tmpfs', '/tmp:rw,noexec,nosuid,size=16777216', lab, 'node', '--input-type=module', '-e',
      `import{mkdir,chown}from'node:fs/promises';await mkdir('${FIXTURES}',{mode:0o700});await chown('${FIXTURES}',1000,1000);process.setgid(1000);process.setuid(1000);const{prepareFixtures}=await import('./tool/memory/fixture.ts');console.log(JSON.stringify(await prepareFixtures('${FIXTURES}')));`]);
    console.log('Generating fictional fixtures outside the measured containers.');
    report.fixtures = JSON.parse((await checked(['start', '--attach', prepare], 600_000)).trim());
    const prepared = await inspect(prepare);
    if (prepared.State.ExitCode !== 0 || prepared.State.OOMKilled || report.fixtures.status !== 'prepared') throw new Error('Fixture generation failed.');
    const selected = options.mode === 'soak' ? ['hpsm-near24-repeat'] as const : scenarios;
    for (const [index, scenario] of selected.entries()) {
      console.log(`Measuring ${scenario} in a fresh 500 MB container.`);
      const name = `${id}-worker-${index}`;
      const args = apiContainerArgs(name, 'none', volume, lab, id);
      args.splice(args.indexOf('--network-alias'), 2);
      args.splice(args.indexOf('tool/linux-memory/server.ts'), 1, 'tool/profile-team-beta.ts', 'linux-worker', scenario, FIXTURES,
        ...(options.mode === 'soak' ? ['soak'] : []));
      await create('container', name, args);
      let pending = '', checkpoints = 0, progressFailed = false, progressWrites = Promise.resolve();
      const result = await runCommand(options.docker, ['start', '--attach', name], env,
        options.mode === 'soak' ? TEAM_SESSION.deadlineMs + 30_000 : 240_000, abort.signal, chunk => {
          if (options.mode !== 'soak') return;
          pending += chunk; const lines = pending.split('\n'); pending = lines.pop()!;
          for (const line of lines) {
            const value = JSON.parse(line);
            if (value.kind !== 'team-memory-checkpoint') continue;
            if (!validTeamCheckpoint(value, ++checkpoints)) throw new Error('Invalid checkpoint.');
            progressWrites = progressWrites.then(() => progress!({ schemaVersion: '1', mode: 'soak', architecture: options.architecture,
              startedAt: report.startedAt, latest: value })).catch(() => { progressFailed = true; abort.abort(); });
          }
        });
      await progressWrites;
      const inspection = await inspect(name);
      let value: any = null;
      try { value = JSON.parse(result.stdout.trim().split('\n').at(-1)!); } catch {   }
      const passed = result.code === 0 && !result.timedOut && !progressFailed && (options.mode !== 'soak' || checkpoints === TEAM_SESSION.iterations)
        && validateTeamLinuxResult(value, inspection, scenario, options.architecture, options.mode);
      report.reports.push({ scenario, status: passed ? 'passed' : 'failed', measurements: value,
        container: { exitCode: inspection.State?.ExitCode, oomKilled: inspection.State?.OOMKilled, running: inspection.State?.Running,
          configurationValid: validContainerConfiguration(inspection) } });
      if (!passed) await writeFile(join(temporary, `${scenario}-diagnostic.txt`), result.stdout + result.stderr, { mode: 0o600 });
    }
    report.status = report.reports.length === selected.length && report.reports.every((r: any) => r.status === 'passed') ? 'passed' : 'failed';
  } catch {
    report.status = 'failed'; report.failure = abort.signal.aborted ? 'interrupted' : 'setup_or_measurement_failed';
  } finally {
    if (deadline) clearTimeout(deadline);
    const remaining = [];
    for (const resource of resources.reverse()) {
      const args = resource.kind === 'container' ? ['rm', '--force', resource.name] : [resource.kind, 'rm', '--force', resource.name];
      const removed = await runCommand(options.docker, args, env, options.mode === 'soak' ? 30_000 : 120_000).catch(() => null);
      if (!removed || removed.code !== 0) remaining.push(resource);
    }
    try {
      if (report.status === 'passed') await rm(temporary, { recursive: true, force: true });
      else {
        for (const path of ['runtime', 'lab', 'docker-config']) await rm(join(temporary, path), { recursive: true, force: true });
        report.diagnosticDirectory = temporary;
      }
    } catch { remaining.push({ kind: 'directory', name: 'owned-working-directory' }); }
    report.cleanup = { status: remaining.length ? 'failed' : 'removed', remaining };
    if (remaining.length) report.status = 'failed';
    report.finishedAt = new Date().toISOString();
    await output.writeFile(JSON.stringify(report, null, 2) + '\n'); await output.sync(); await output.close();
    process.off('SIGINT', cancel); process.off('SIGTERM', cancel);
  }
  console.log(`Native ${options.architecture} team beta memory profile ${report.status}; report written privately.`);
  if (report.status !== 'passed') process.exitCode = 1;
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) main().catch(() => {
  console.error('Team beta Linux acceptance failed. No private cloud configuration was used.'); process.exitCode = 1;
});
