import { spawn } from 'node:child_process';
import { mkdtemp, chmod, rm, mkdir, lstat, open } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { readFixture } from './memory/fixture.ts';
import { profileChildEnvironment, PROFILE_WORKER_NODE_ARGS, PROFILE_NODE_VERSION } from './memory/profile-harness.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import { createFormAnswerContext, createSavedFormAnswers } from '../src/forms/form-answers.ts';
import { handleDraftExport, type DraftExportDependencies } from '../src/api/draft-export.ts';
import { intakeDefinition } from '../src/programs/intake.ts';
import type { CaseSnapshot } from '../src/types.ts';
import { createTeamProgressWriter, runTeamSession, TEAM_SESSION, validTeamCheckpoint, validTeamSession, type TeamMemoryMode, type TeamCheckpoint } from './memory/team-session.ts';
export const scenarios = ['scfhp-six', 'hpsm-six', 'rtp-six', 'hpsm-near24-repeat'] as const;
type Scenario = typeof scenarios[number];
const owner = 'fictional-memory-owner', caseId = 'fictional-v2-memory', at = '2026-10-22T22:00:00.000Z';
const sha = (v: Uint8Array) => createHash('sha256').update(v).digest('hex');
const chineseGlyphs = (offset: number, count: number) => Array.from({ length: count },
  (_, index) => String.fromCodePoint(0x4e00 + offset + index)).join('');
export const TEAM_MEMORY_OBSERVATION = '虚构測試：门槛、門檻。' + chineseGlyphs(0, 200);
export const teamMemoryLabel = (index: number) => chineseGlyphs(200 + index * 40, 40);
export const TEAM_MEMORY_INTAKE = '虚构維修說明：' + chineseGlyphs(1000, 580);
async function seed(directory: string, programId: string, repeated: boolean, count: number) {
  const snapshot: CaseSnapshot = { schemaVersion: '1', caseId, revision: 1,
    profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [],
    findings: [{ id: 'fictional-finding', room: 'entrance', observation: TEAM_MEMORY_OBSERVATION, reviewState: 'confirmed', measurements: [],
      evidenceIds: Array.from({ length: count }, (_, i) => `photo-${i}`) }] };
  const cases = new MemoryCaseRepository([{ userId: owner, snapshot }]);
  const fixture = await readFixture(directory, repeated ? 'near24.png' : 'six.png');
  const descriptors = [];
  let catalogRevision = 0;
  for (let i = 0; i < count; i++) {
    const saved = await cases.saveEvidenceIfCurrent({ userId: owner, caseId, revision: 1, expectedCatalogRevision: catalogRevision,
      evidenceId: `photo-${i}`, expectedEvidenceRevision: 0, findingId: 'fictional-finding', capturedAt: null, preparedAt: at,
      image: { bytes: fixture.bytes, mediaType: 'image/png', processingVersion: 'evidence-png-v1', byteLength: fixture.bytes.length,
        sha256: fixture.metadata.sha256, width: fixture.metadata.width, height: fixture.metadata.height } });
    if (saved.status !== 'saved') throw new Error('Fixture setup failed.');
    catalogRevision++; descriptors.push(saved.asset.descriptor);
  }
  const definition = intakeDefinition(programId)!;
  const intake = await cases.saveProgramIntakeIfCurrent({ userId: owner, caseId, revision: 1, programId, expectedIntakeRevision: 0,
    intake: { schemaVersion: '2', caseId, caseRevision: 2, programId, questionnaireVersion: definition.questionnaireVersion,
      intakeRevision: 1, updatedAt: at, updatedBy: owner, answers: definition.questions.map(q => ({ key: q.key,
        value: q.kind === 'money' ? 9000 : q.kind === 'boolean' ? false : TEAM_MEMORY_INTAKE, reviewState: 'reported' })) } });
  if (intake.status !== 'saved') throw new Error('Fixture intake failed.');
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const form = (await bundle.loadFormTemplate(programId))!;
  const answerSave = await cases.saveFormAnswersIfCurrent({ userId: owner, caseId, revision: 2,
    programId, expectedAnswerRevision: 0, answers: createSavedFormAnswers({
      snapshot: { ...snapshot, revision: 3 }, context: createFormAnswerContext(form.template), answerRevision: 1,
      answers: [{ key: 'memberFirstName', value: '陈美华 陳美華', reviewState: 'reviewed' }],
      updatedAt: at, updatedBy: owner,
    }) });
  if (answerSave.status !== 'saved') throw new Error('Fixture form answers failed.');
  for (const d of descriptors) {
    const result = await cases.saveAnnotationsForUser(owner, { schemaVersion: '2', caseId, expectedCaseRevision: 3,
      expectedCatalogRevision: catalogRevision, evidenceId: d.evidenceId, expectedEvidenceRevision: 1,
      expectedAnnotationRevision: 0, expectedImageSha256: d.sha256, expectedImageWidth: d.width, expectedImageHeight: d.height,
      marks: Array.from({ length: 20 }, (_, i) => ({ id: `box-${i}`, rect: [(i % 4) * 200000, Math.floor(i / 4) * 150000, 150000, 100000] as [number, number, number, number],
        label: teamMemoryLabel(i) })), reviewedForExport: true }, at);
    if (result.status !== 'found') throw new Error('Fixture annotations failed.');
    catalogRevision++;
  }
  return { cases, descriptors, catalogRevision, metrics: {
    selectedBytes: fixture.bytes.length * count,
    selectedPixels: fixture.metadata.width * fixture.metadata.height * count,
  } };
}

async function exportAndVerify(request: unknown, deps: DraftExportDependencies,
  count: number, minimumPages: number, retained: string | undefined) {
  const result = await handleDraftExport({ body: request, bearerToken: 'fictional' }, deps, 'create-draft-export', 2);
  if (result.status !== 200 || !('artifactId' in result.body)) throw new Error('V2 export rejected.');
  const m = result.body;
  if (m.schemaVersion !== '2' || m.selectedEvidence.length !== count || m.pageCount < minimumPages ||
    (retained !== undefined && retained !== m.artifactId)) throw new Error('Invalid v2 export binding.');
  const file = await handleDraftExport({ body: { schemaVersion: '2', caseId, expectedCaseRevision: 3, artifactId: m.artifactId }, bearerToken: 'fictional' }, deps, 'download-draft-export', 2);
  if (file.status !== 200 || !(file.body instanceof Uint8Array) || file.body.length !== m.byteLength ||
    Buffer.from(file.body.subarray(0, 5)).toString('ascii') !== '%PDF-' || sha(file.body) !== m.sha256 ||
    file.headers['Cache-Control'] !== 'no-store' || file.headers['X-Content-Type-Options'] !== 'nosniff') {
    throw new Error('Invalid v2 download.');
  }
  return { artifactId: m.artifactId, pageCount: m.pageCount, sha256: m.sha256 };
}

async function measureTeamWorkload(directory: string, scenario: Scenario, explicitIterations?: number) {
  const programId = scenario.startsWith('scfhp') ? 'scfhp-eaa' : scenario.startsWith('rtp') ? 'rtp-home-repair' : 'hpsm-eaa';
  const repeated = scenario === 'hpsm-near24-repeat', count = repeated ? 1 : 6, iterations = explicitIterations ?? (repeated ? 12 : 1);
  const { cases, descriptors, catalogRevision, metrics } = await seed(directory, programId, repeated, count);
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const form = (await bundle.loadFormTemplate(programId))!;
  const deps = { cases, authenticate: async () => ({ userId: owner }), loadRegistry: bundle.loadRegistry,
    loadFormTemplate: bundle.loadFormTemplate, now: () => new Date(at) };
  const request = { schemaVersion: '2', caseId, expectedCaseRevision: 3, programId,
    expectedFormContextId: createFormAnswerContext(form.template).formContextId, expectedAnswerRevision: 1,
    expectedEvidenceCatalogRevision: catalogRevision, generationKey: 'fictional-v2-memory-attempt',
    selectedEvidence: descriptors.map(d => ({ evidenceId: d.evidenceId, expectedEvidenceRevision: 1, expectedAnnotationRevision: 1, reviewedForExport: true })) };
  const rss = [], pages = [], digests = []; let retained: string | undefined;
  for (let i = 0; i < iterations; i++) {
    const m = await exportAndVerify(request, deps, count, form.template.pageCount + count + 1, retained);
    retained = m.artifactId;
    pages.push(m.pageCount); digests.push(m.sha256); rss.push(process.memoryUsage().rss);
  }
  const peakBytes = process.resourceUsage().maxRSS * 1024;
  return { scenario, status: peakBytes <= 400000000 ? 'passed' as const : 'failed' as const, platform: process.platform, arch: process.arch,
    node: process.version, iterations, selectedPhotos: count, boxesPerPhoto: 20, labelCharactersPerPhoto: 800,
    ...metrics,
    peakBytes, iterationRssBytes: rss, pageCounts: pages, retryIdentityPreserved: new Set(digests).size === 1 };
}
export async function runTeamBetaMemoryWorker(directory: string, scenario: Scenario, mode: TeamMemoryMode = 'boundary',
  checkpoint: (value: TeamCheckpoint) => Promise<void> = async value => { console.log(JSON.stringify(value)); }) {
  if (mode === 'boundary') return measureTeamWorkload(directory, scenario);
  if (mode !== 'soak' || scenario !== 'hpsm-near24-repeat') throw new Error('Unsupported session.');
  let last: Awaited<ReturnType<typeof measureTeamWorkload>> | undefined;
  const session = await runTeamSession({ checkpoint, runIteration: async () => {
    last = await measureTeamWorkload(directory, scenario, 2); return last;
  } });
  return { ...last, scenario, mode, status: session.status, iterations: session.iterations,
    peakBytes: process.resourceUsage().maxRSS * 1024,
    iterationRssBytes: session.checkpoints.map(c => c.rssBytes), pageCounts: session.checkpoints.map(c => c.pageCount), session };
}
async function child(file: string, args: string[], options: {
  timeoutMs?: number; signal?: AbortSignal; checkpoint?: (value: TeamCheckpoint) => Promise<void>;
} = {}) {
  return await new Promise<unknown>((resolve, reject) => {
    const run = spawn(process.execPath, [...PROFILE_WORKER_NODE_ARGS, file, ...args], {
      env: { ...profileChildEnvironment(), MALLOC_ARENA_MAX: '2', VIPS_CONCURRENCY: '1' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', bytes = 0, failed = false, pending = '', checkpoints = 0, progress = Promise.resolve();
    const stop = () => { failed = true; run.kill('SIGKILL'); };
    const timer = setTimeout(stop, options.timeoutMs ?? 180000);
    options.signal?.addEventListener('abort', stop, { once: true }); if (options.signal?.aborted) stop();
    const closed = () => { clearTimeout(timer); options.signal?.removeEventListener('abort', stop); };
    run.stdout.on('data', chunk => {
      bytes += chunk.length; if (bytes > 262144) { stop(); return; } out += chunk; pending += chunk;
      const lines = pending.split('\n'); pending = lines.pop()!;
      for (const line of lines) try {
        const value = JSON.parse(line);
        if (value.kind === 'team-memory-checkpoint') {
          if (!validTeamCheckpoint(value, ++checkpoints)) { stop(); return; }
          progress = progress.then(() => options.checkpoint?.(value)).catch(stop);
        }
      } catch { stop(); }
    });
    run.stderr.on('data', chunk => { bytes += chunk.length; if (bytes > 262144) { failed = true; run.kill('SIGKILL'); } });
    run.on('error', () => { closed(); reject(new Error('Memory worker failed.')); });
    run.on('close', async code => { closed(); await progress; if (failed || code !== 0) reject(new Error('Memory worker failed.'));
      else { try { resolve(JSON.parse(out.trim().split('\n').at(-1)!)); } catch { reject(new Error('Invalid memory report.')); } } });
  });
}

export function parseTeamLocalOptions(args: string[]) {
  if (args.length === 1 && args[0] === 'run') return { mode: 'boundary' as const, output: undefined };
  if (args.length !== 5 || args[0] !== 'run' || args[1] !== '--mode' || args[2] !== 'soak' || args[3] !== '--output') throw new Error('Invalid memory arguments.');
  const output = args[4], backend = fileURLToPath(new URL('../', import.meta.url));
  if (output !== resolve(output) || dirname(output) !== join(backend, 'local-artifacts') || !/^[A-Za-z0-9_-]+\.json$/.test(output.split('/').at(-1)!)) throw new Error('Private new report required.');
  return { mode: 'soak' as const, output };
}
async function main() {
  const args = process.argv.slice(2);
  if (process.versions.node !== PROFILE_NODE_VERSION) throw new Error('Use Node 24.22.0.');
  const workerMode = args.length === 4 && args[3] === 'soak' ? 'soak' : 'boundary';
  const workerArgs = args.length === 3 || args.length === 4 && workerMode === 'soak' && args[1] === 'hpsm-near24-repeat';
  if (workerArgs && args[0] === 'linux-worker' && scenarios.includes(args[1] as Scenario)) {
    if (process.platform !== 'linux' || !['x64', 'arm64'].includes(process.arch)) throw new Error('Native Linux worker required.');
    const { memorySnapshot, allocatorArenaMax } = await import('./linux-memory/server.ts');
    const { assertLinuxMemoryStartup } = await import('./linux-memory/report.ts');
    const { default: sharp } = await import('sharp');
    const architecture = process.arch === 'x64' ? 'amd64' : 'arm64';
    const runtime = { node: process.versions.node, platform: process.platform, arch: process.arch, uid: process.getuid!(),
      execArgv: process.execArgv, allocatorArenaMax: allocatorArenaMax(), sharpConcurrency: sharp.concurrency() };
    const baseline = await memorySnapshot();
    assertLinuxMemoryStartup({ schemaVersion: '1', kind: 'ready', runtime, baseline }, architecture);
    const workload = await runTeamBetaMemoryWorker(args[2], args[1] as Scenario, workerMode);
    const memory = await memorySnapshot();
    let containerPassed = true;
    try { assertLinuxMemoryStartup({ schemaVersion: '1', kind: 'ready', runtime, baseline: memory }, architecture); }
    catch { containerPassed = false; }
    console.log(JSON.stringify({ ...workload, status: workload.status === 'passed' && containerPassed ? 'passed' : 'failed',
      runtime, baseline, memory }));
    return;
  }
  if (workerArgs && args[0] === 'worker' && scenarios.includes(args[1] as Scenario)) {
    console.log(JSON.stringify(await runTeamBetaMemoryWorker(args[2], args[1] as Scenario, workerMode))); return;
  }
  const options = parseTeamLocalOptions(args);
  const abort = new AbortController(), stop = () => abort.abort();
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
  let output: Awaited<ReturnType<typeof open>> | undefined, progress: Awaited<ReturnType<typeof createTeamProgressWriter>> | undefined;
  if (options.output) {
    await mkdir(dirname(options.output), { recursive: true, mode: 0o700 });
    const stat = await lstat(dirname(options.output));
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.()) throw new Error('Private owned directory required.');
    output = await open(options.output, 'wx', 0o600);
    try { progress = await createTeamProgressWriter(options.output); }
    catch (error) { await output.close(); throw error; }
  }
  const startedAt = new Date().toISOString();
  const directory = await mkdtemp(join(tmpdir(), 'sah-memory-team-v2-')); await chmod(directory, 0o700);
  const reports: unknown[] = [];
  let failure: string | undefined, cleanup = 'removed';
  try {
    await child(fileURLToPath(new URL('memory/fixture.ts', import.meta.url)), [directory], { signal: abort.signal });
    for (const scenario of options.mode === 'soak' ? ['hpsm-near24-repeat'] as const : scenarios) {
      reports.push(await child(fileURLToPath(import.meta.url), ['worker', scenario, directory, ...(options.mode === 'soak' ? ['soak'] : [])], {
        signal: abort.signal, timeoutMs: options.mode === 'soak' ? TEAM_SESSION.deadlineMs + 30_000 : 180000,
        checkpoint: async value => { await progress?.({ startedAt, scope: 'local native single-process session; not Linux or hosted acceptance', latest: value }); },
      }));
    }
  } catch { failure = abort.signal.aborted ? 'interrupted' : 'setup_or_measurement_failed'; }
  finally {
    try { await rm(directory, { recursive: true, force: true }); } catch { cleanup = 'failed'; }
    process.off('SIGINT', stop); process.off('SIGTERM', stop);
  }
  const passed = !failure && cleanup === 'removed' && reports.length === (options.mode === 'soak' ? 1 : scenarios.length)
    && reports.every(r => (r as { status: string }).status === 'passed')
    && (options.mode !== 'soak' || validTeamSession((reports[0] as any).session));
  const report = { schemaVersion: '1', status: passed ? 'passed' : 'failed', capturedAt: new Date().toISOString(), startedAt, finishedAt: new Date().toISOString(), mode: options.mode,
    scope: 'local native process; synthetic memory repository; not Linux, AMD64 or hosted acceptance',
    headroomTargetBytes: 400000000, workerExecArgv: [...PROFILE_WORKER_NODE_ARGS], reports, cleanup, ...(failure ? { failure } : {}) };
  if (output) { try { await output.writeFile(JSON.stringify(report, null, 2) + '\n'); await output.sync(); } finally { await output.close(); } }
  console.log(JSON.stringify(report));
  if (!passed) process.exitCode = 1;
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) main().catch(() => { console.error('Team beta local memory acceptance failed. No private configuration was used.'); process.exitCode = 1; });
