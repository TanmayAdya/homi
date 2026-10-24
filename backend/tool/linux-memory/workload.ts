import { createHash } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import type { UploadEvidenceResponse } from '../../src/api/write-evidence.ts';
import type { EvidenceCatalog } from '../../src/evidence/types.ts';
import type { ExportArtifactMetadata } from '../../src/exports/types.ts';
import { createFormAnswerContext } from '../../src/forms/form-answers.ts';
import { loadRuntimeBenefitsBundle } from '../../src/programs/runtime-bundle.ts';
import type { CaseSnapshot } from '../../src/types.ts';
import { readFixture } from '../memory/fixture.ts';
import type { Scenario, WorkloadMetrics } from '../memory/workload.ts';
import { AGGREGATE_CASE_ID, API_ORIGIN, CASE_ID, OTHER_TOKEN, TOKEN, baseRequest, parseScenario,
  scenarioFixture, syntheticDiagnostic, syntheticDraft, assertWorkloadMode, parseWorkloadMode,
  sessionConfiguration, SOAK_PDF_GENERATION_ITERATIONS, type LinuxWorkloadMode } from './protocol.ts';

export interface LinuxWorkloadReport {
  schemaVersion: '1'; kind: 'workload'; scenario: Scenario; status: 'passed' | 'failed'; iterations: number;
  workload: WorkloadMetrics; assertions: Record<string, boolean>; iterationElapsedMs: number[];
  mode?: 'long' | 'soak'; iterationStartElapsedMs?: number[]; elapsedMs?: number;
  renderRequests?: number; newGenerationRequests?: number; retryGenerationRequests?: number;
}
export interface LinuxWorkloadProgress {
  schemaVersion: '1'; kind: 'workload-progress'; scenario: Scenario; mode: 'long' | 'soak';
  iteration: number; plannedIterations: number; iterationElapsedMs: number; elapsedMs: number;
}
export interface LinuxWorkloadOptions {
  mode?: LinuxWorkloadMode; signal?: AbortSignal;
  now?: () => number;
  wait?: (milliseconds: number, signal?: AbortSignal) => Promise<void>;
  onProgress?: (progress: LinuxWorkloadProgress) => void | Promise<void>;
}

export async function runPacedLongSession(operation: (index: number, started: number) => Promise<void>, options: LinuxWorkloadOptions = {}) {
  const mode = options.mode ?? 'long';
  if (mode === 'boundary') throw new Error('Paced session mode required.');
  const config = sessionConfiguration(mode);
  const now = options.now ?? (() => Math.floor(performance.now()));
  const wait = options.wait ?? ((milliseconds, signal) => sleep(milliseconds, undefined, { signal }));
  let lastObserved = -1;
  const clock = () => {
    const value = now();
    if (!Number.isSafeInteger(value) || value < 0 || value < lastObserved) throw new Error('Invalid synthetic pacing clock.');
    lastObserved = value; return value;
  };
  options.signal?.throwIfAborted();
  const initial = clock();
  const starts: number[] = [], durations: number[] = [];
  for (let index = 0; index < config.iterations; index++) {
    options.signal?.throwIfAborted();
    const earliest = index === 0 ? initial : initial + starts[index - 1] + config.intervalMs;
    if (!Number.isSafeInteger(earliest)) throw new Error('Invalid synthetic pacing clock.');
    let start = clock(), waits = 0;
    while (start < earliest) {
      if (waits++ >= 8) throw new Error('Synthetic pacing timer did not reach its deadline.');
      options.signal?.throwIfAborted();
      await wait(earliest - start, options.signal);
      options.signal?.throwIfAborted();
      start = clock();
    }
    options.signal?.throwIfAborted();
    starts.push(start - initial);
    await operation(index, start);
    options.signal?.throwIfAborted();
    const end = clock();
    if (end <= start) throw new Error('Invalid synthetic operation clock.');
    durations.push(end - start);
  }
  return { starts, durations, elapsedMs: clock() - initial };
}

export function createProgressAcknowledger(publish: (progress: LinuxWorkloadProgress) => void,
  signals: { on(event: 'SIGUSR2', listener: () => void): unknown; off(event: 'SIGUSR2', listener: () => void): unknown } = process,
  timeoutMs = 30_000) {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30_000) throw new Error('Invalid acknowledgement deadline.');
  let pending: { resolve: () => void; reject: (error: Error) => void; timer: NodeJS.Timeout } | undefined;
  let disposed = false;
  const acknowledge = () => { if (pending) { const current = pending; pending = undefined; clearTimeout(current.timer); current.resolve(); } };
  signals.on('SIGUSR2', acknowledge);
  return {
    report(progress: LinuxWorkloadProgress): Promise<void> {
      if (disposed || pending) return Promise.reject(new Error('Invalid progress acknowledgement state.'));
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending = undefined; reject(new Error('Memory checkpoint acknowledgement timed out.')); }, timeoutMs);
        pending = { resolve, reject, timer };
        try { publish(progress); } catch (error) {
          if (pending) { clearTimeout(pending.timer); pending = undefined; }
          reject(error);
        }
      });
    },
    dispose() {
      disposed = true; signals.off('SIGUSR2', acknowledge);
      if (pending) { const current = pending; pending = undefined; clearTimeout(current.timer); current.reject(new Error('Memory checkpoint cancelled.')); }
    },
  };
}

export function artifactIsFresh(artifact: Pick<ExportArtifactMetadata, 'generatedAt' | 'expiresAt' | 'recheckAfter'>, now: number) {
  const generated = Date.parse(artifact.generatedAt), expires = Date.parse(artifact.expiresAt);
  const policyDeadline = artifact.recheckAfter === null ? expires : Date.parse(artifact.recheckAfter);
  return Number.isFinite(now) && Number.isFinite(generated) && Number.isFinite(expires) && Number.isFinite(policyDeadline)
    && generated <= now && now < expires && now < policyDeadline;
}
const privateResponse = (response: Response) => response.headers.get('cache-control') === 'no-store'
  && response.headers.get('x-content-type-options') === 'nosniff';

export async function digestResponse(response: Response, maximum: number) {
  if (!response.body) throw new Error('Missing private response body.');
  const digest = createHash('sha256'); let length = 0;
  const prefix = Buffer.alloc(8); let prefixLength = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (length + value.length > maximum) throw new Error('Private response exceeds its contract.');
      digest.update(value); length += value.length;
      const copied = Math.min(prefix.length - prefixLength, value.length);
      prefix.set(value.subarray(0, copied), prefixLength); prefixLength += copied;
    }
    return { bytes: length, sha256: digest.digest('hex'), prefix: prefix.subarray(0, prefixLength) };
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}

export async function runLinuxWorkload(scenario: Scenario, directory: string, transport: typeof fetch = fetch,
  options: LinuxWorkloadOptions = {}): Promise<LinuxWorkloadReport> {
  const mode = parseWorkloadMode(options.mode);
  assertWorkloadMode(scenario, mode);
  const long = mode !== 'boundary', now = options.now ?? (() => Math.floor(performance.now())), sessionStarted = now();
  const config = long ? sessionConfiguration(mode) : null;
  const iterations = config ? config.iterations : scenario === 'pdf-repeat-16mp' || scenario === 'upload-repeat-16mp' ? 3 : 1;
  let caseRevision = 1;
  const report: LinuxWorkloadReport = { schemaVersion: '1', kind: 'workload', scenario, status: 'failed', iterations,
    workload: { inputBytes: 0, selectedEvidenceBytes: 0, selectedEvidencePixels: 0 }, assertions: {}, iterationElapsedMs: [],
    ...(mode !== 'boundary' ? { mode, iterationStartElapsedMs: [], elapsedMs: 0, renderRequests: 0, newGenerationRequests: 0, retryGenerationRequests: 0 } : {}) };
  const check = (name: string, value: boolean) => { report.assertions[name] = (report.assertions[name] ?? true) && value; };
  const post = async (route: string, body: unknown, token = TOKEN) => {
    const timeout = AbortSignal.timeout(120_000);
    const response = await transport(`${API_ORIGIN}/v1/${route}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify(body), redirect: 'error', signal: options.signal ? AbortSignal.any([timeout, options.signal]) : timeout,
    });
    if (long) check('noRateLimitResponses', response.status !== 429);
    return response;
  };
  const runIterations = async (operation: (index: number) => Promise<void>) => {
    const iteration = async (index: number, started = now()) => {
      if (long) report.iterationStartElapsedMs!.push(started - sessionStarted);
      await operation(index);
      const elapsed = now() - started;
      if (!Number.isSafeInteger(elapsed) || elapsed < 1) throw new Error('Invalid synthetic operation clock.');
      report.iterationElapsedMs.push(elapsed);
      if (long) {
        if (!Object.values(report.assertions).every(Boolean)) throw new Error('Synthetic iteration assertions failed.');
        await options.onProgress?.({ schemaVersion: '1', kind: 'workload-progress', scenario, mode: mode as 'long' | 'soak',
          iteration: index + 1, plannedIterations: iterations, iterationElapsedMs: elapsed, elapsedMs: now() - sessionStarted });
      }
    };
    if (long) {
      await runPacedLongSession(iteration, { ...options, mode, now });
      check('pacingRespected', report.iterationStartElapsedMs!.every((start, index, all) => index === 0 || start - all[index - 1] >= config!.intervalMs));
      check('completeSession', report.iterationElapsedMs.length === iterations);
    } else for (let index = 0; index < iterations; index++) await iteration(index);
  };
  const json = async <T>(route: string, body: unknown, token = TOKEN, expectedStatus = 200): Promise<T> => {
    const response = await post(route, body, token);
    check('privateNoStore', privateResponse(response));
    if (response.status !== expectedStatus) {
      console.error(JSON.stringify({ kind: 'synthetic-http-status', route, expectedStatus, status: response.status }));
      await response.body?.cancel();
      throw new Error('Unexpected synthetic API status.');
    }
    return await response.json() as T;
  };
  const failure = async (route: string, body: unknown, status: number, code: string, token = TOKEN) => {
    const value = await json<{ schemaVersion: string; error: { code: string } }>(route, body, token, status);
    return value.schemaVersion === '1' && value.error?.code === code;
  };
  const ordinaryRead = async () => {
    const value = await json<CaseSnapshot>('read-case', { schemaVersion: '1', caseId: CASE_ID });
    check('ordinaryReadAccepted', value.caseId === CASE_ID && value.revision === caseRevision);
  };
  try {
    options.signal?.throwIfAborted();
    if (scenario.startsWith('upload-') || scenario === 'reject-oversize') {
      const created = await json<CaseSnapshot>('create-case', syntheticDraft(1));
      check('httpCaseCreated', created.caseId === CASE_ID && created.revision === 1);
    }
    await ordinaryRead();
    check('crossOwnerCaseDenied', await failure('read-case', { schemaVersion: '1', caseId: CASE_ID }, 404, 'CASE_NOT_FOUND', OTHER_TOKEN));
    check('invalidSessionDenied', await failure('read-case', { schemaVersion: '1', caseId: CASE_ID }, 401, 'UNAUTHENTICATED', 'invalid-synthetic-token'));

    if (scenario.startsWith('pdf-')) {
      const { name, count } = scenarioFixture(scenario);
      const fixture = await readFixture(directory, name);
      report.workload = { inputBytes: fixture.bytes.length, selectedEvidenceBytes: fixture.bytes.length * count,
        selectedEvidencePixels: fixture.metadata.width * fixture.metadata.height * count };
      const bundle = await loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1');
      const form = await bundle.loadFormTemplate('scfhp-eaa');
      if (!form || form.template.pageCount !== 5) throw new Error('Bundled form unavailable.');
      const body = { ...baseRequest, programId: 'scfhp-eaa',
        expectedFormContextId: createFormAnswerContext(form.template).formContextId, expectedAnswerRevision: 0,
        expectedEvidenceCatalogRevision: count, generationKey: 'synthetic-linux-memory-retry',
        selectedEvidence: Array.from({ length: count }, (_, index) => ({ evidenceId: `synthetic-photo-${index + 1}`,
          expectedEvidenceRevision: 1, reviewedForExport: true })) };
      let artifactId: string | undefined, artifactDigest: string | undefined;
      const generations = new Set<string>();
      await runIterations(async index => {
        const newGeneration = index === 0 || (mode === 'soak' && index % SOAK_PDF_GENERATION_ITERATIONS === 0);
        let priorArtifact: string | undefined;
        if (newGeneration && index > 0) {
          priorArtifact = artifactId;
          const saved = await json<CaseSnapshot>('save-case', { ...syntheticDraft(count), expectedCaseRevision: caseRevision });
          check('generationRotationVerified', saved.caseId === CASE_ID && saved.revision === caseRevision + 1);
          caseRevision++;
          check('priorGenerationInvalidated', await failure('download-draft-export',
            { ...baseRequest, expectedCaseRevision: caseRevision - 1, artifactId: priorArtifact }, 409, 'CASE_REVISION_MISMATCH'));
          body.expectedCaseRevision = caseRevision;
          body.generationKey = `synthetic-soak-generation-${Math.floor(index / SOAK_PDF_GENERATION_ITERATIONS)}`;
          artifactId = undefined; artifactDigest = undefined;
        }
        if (long) {
          report.renderRequests!++; if (newGeneration) report.newGenerationRequests!++; else report.retryGenerationRequests!++;
        }
        const [artifact] = await Promise.all([json<ExportArtifactMetadata>('create-draft-export', body), ordinaryRead()]);
        if (mode === 'soak' && newGeneration) {
          check('generationRotationVerified', !generations.has(artifact.artifactId) && artifact.artifactId !== priorArtifact
            && artifact.caseRevision === caseRevision);
          generations.add(artifact.artifactId);
        }
        check('draftOnly', artifact.status === 'draft' && artifact.warnings.includes('INCOMPLETE_DRAFT')
          && artifact.warnings.includes('NOT_SUBMITTED') && artifact.warnings.includes('POLICY_CURRENTNESS_UNKNOWN'));
        check('exactPagesAndSelection', artifact.pageCount === 5 + count && artifact.selectedEvidence.length === count);
        check('retryIdentityPreserved', artifactId === undefined || artifactId === artifact.artifactId);
        if (long) {
          check('artifactFreshEachIteration', artifactIsFresh(artifact, Date.now()));
          check('retryBytesStable', artifactDigest === undefined || artifactDigest === artifact.sha256);
        }
        check('boundToExactEvidence', artifact.selectedEvidence.every((selected, selectedIndex) =>
          selected.evidenceId === `synthetic-photo-${selectedIndex + 1}` && selected.evidenceRevision === 1 && selected.sha256 === fixture.metadata.sha256));
        artifactId = artifact.artifactId; artifactDigest = artifact.sha256;
        const response = await post('download-draft-export', { ...baseRequest, expectedCaseRevision: caseRevision, artifactId });
        check('privateNoStore', privateResponse(response));
        check('downloadAccepted', response.status === 200 && response.headers.get('content-type') === 'application/pdf');
        const downloaded = await digestResponse(response, 32 * 1024 * 1024);
        check('pdfMagic', downloaded.prefix.subarray(0, 5).toString('ascii') === '%PDF-');
        check('downloadDigestMatches', downloaded.bytes === artifact.byteLength && downloaded.sha256 === artifact.sha256);
        if (long) check('artifactFreshEachIteration', artifactIsFresh(artifact, Date.now()));
      });
      check('crossOwnerArtifactDenied', await failure('download-draft-export', { ...baseRequest, expectedCaseRevision: caseRevision, artifactId }, 404, 'ARTIFACT_NOT_FOUND', OTHER_TOKEN));
    } else if (scenario.startsWith('upload-')) {
      const { name } = scenarioFixture(scenario);
      const fixture = await readFixture(directory, name), fullPixels = name === 'full16mp.jpg';
      report.workload = { inputBytes: fixture.bytes.length, selectedEvidenceBytes: 0,
        selectedEvidencePixels: fixture.metadata.width * fixture.metadata.height };
      check('fixtureInputBounds', fixture.bytes.length >= (fullPixels ? 6 : 7.5) * 1024 * 1024 && fixture.bytes.length <= 8 * 1024 * 1024);
      check('fixturePixelCoverage', report.workload.selectedEvidencePixels === (fullPixels ? 16_000_000 : 7_290_000));
      const body = { ...baseRequest, evidenceId: 'synthetic-photo-1', findingId: 'synthetic-finding', capturedAt: null,
        imageBase64: fixture.bytes.toString('base64') };
      let previousHash: string | undefined;
      await runIterations(async index => {
        const revision = index + 1;
        const [uploaded] = await Promise.all([json<UploadEvidenceResponse>('upload-evidence', { ...body,
          expectedCatalogRevision: index, expectedEvidenceRevision: index }), ordinaryRead()]);
        const descriptor = uploaded.evidence;
        report.workload.selectedEvidenceBytes = descriptor.byteLength;
        check('uploadAccepted', uploaded.catalogRevision === revision && uploaded.caseRevision === 1 && descriptor.evidenceRevision === revision);
        check('exactDimensions', descriptor.width === fixture.metadata.width && descriptor.height === fixture.metadata.height);
        check('pngMetadata', descriptor.mediaType === 'image/png' && descriptor.processingVersion === 'evidence-png-v1');
        check('replacementDigestStable', previousHash === undefined || previousHash === descriptor.sha256); previousHash = descriptor.sha256;
        const response = await post('download-evidence', { ...baseRequest, expectedCatalogRevision: revision,
          evidenceId: 'synthetic-photo-1', expectedEvidenceRevision: revision });
        check('privateNoStore', privateResponse(response));
        check('previewAccepted', response.status === 200 && response.headers.get('content-type') === 'image/png');
        const downloaded = await digestResponse(response, 24 * 1024 * 1024);
        check('previewDigestMatches', downloaded.bytes === descriptor.byteLength && downloaded.sha256 === descriptor.sha256);
        check('pngMagic', downloaded.prefix.equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])));
        const catalog = await json<EvidenceCatalog>('list-evidence', baseRequest);
        check('singleCurrentPhoto', catalog.catalogRevision === revision && catalog.caseRevision === 1
          && catalog.evidence.length === 1 && catalog.evidence[0].evidenceRevision === revision && catalog.evidence[0].sha256 === descriptor.sha256);
      });
      check('crossOwnerArtifactDenied', await failure('download-evidence', { ...baseRequest, expectedCatalogRevision: iterations,
        evidenceId: 'synthetic-photo-1', expectedEvidenceRevision: iterations }, 404, 'ARTIFACT_NOT_FOUND', OTHER_TOKEN));
    } else {
      const started = performance.now(), fixture = await readFixture(directory, 'oversize.png');
      const solid = await readFixture(directory, 'solid.png');
      report.workload = { inputBytes: fixture.bytes.length, selectedEvidenceBytes: solid.bytes.length * 2,
        selectedEvidencePixels: solid.metadata.width * solid.metadata.height * 2 };
      const body = { ...baseRequest, expectedCatalogRevision: 0, evidenceId: 'synthetic-photo-1', expectedEvidenceRevision: 0,
        findingId: 'synthetic-finding', capturedAt: null };
      check('pixelLimitRejected', await failure('upload-evidence', { ...body, imageBase64: fixture.bytes.toString('base64') }, 422, 'INVALID_IMAGE'));
      check('inputByteLimitRejected', await failure('upload-evidence', { ...body, imageBase64: Buffer.alloc(8 * 1024 * 1024 + 1).toString('base64') }, 400, 'INVALID_REQUEST'));
      check('aggregateLimitRejected', await failure('create-draft-export', { ...baseRequest, caseId: AGGREGATE_CASE_ID, programId: 'scfhp-eaa',
        expectedFormContextId: 'a'.repeat(64), expectedAnswerRevision: 0, expectedEvidenceCatalogRevision: 2,
        generationKey: 'synthetic-linux-rejected-attempt', selectedEvidence: [1, 2].map(index => ({
          evidenceId: `synthetic-photo-${index}`, expectedEvidenceRevision: 1, reviewedForExport: true })) }, 422, 'EXPORT_REVIEW_REQUIRED'));
      const catalog = await json<EvidenceCatalog>('list-evidence', baseRequest);
      check('noPartialUpload', catalog.catalogRevision === 0 && catalog.evidence.length === 0);
      report.iterationElapsedMs.push(Math.ceil(performance.now() - started));
    }
    await ordinaryRead();
    check('workerCompleted', true);
  } catch (error) { syntheticDiagnostic('http-workload', error); check('workerCompleted', false); }
  if (long) report.elapsedMs = now() - sessionStarted;
  report.status = Object.values(report.assertions).every(Boolean) && report.iterationElapsedMs.length === iterations ? 'passed' : 'failed';
  return report;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4 && process.argv.length !== 5) { console.error('Synthetic HTTP workload arguments are invalid.'); process.exitCode = 1; }
  else {
    let acknowledger: ReturnType<typeof createProgressAcknowledger> | undefined;
    Promise.resolve().then(() => {
      const mode = parseWorkloadMode(process.argv[4]);
      if (mode !== 'boundary') acknowledger = createProgressAcknowledger(progress => console.log(JSON.stringify(progress)));
      return runLinuxWorkload(parseScenario(process.argv[2]), process.argv[3], fetch, { mode,
        ...(acknowledger ? { onProgress: acknowledger.report } : {}) });
    }).then(report => {
      console.log(JSON.stringify(report)); if (report.status !== 'passed') process.exitCode = 1;
    }, () => { console.error('Synthetic HTTP workload failed.'); process.exitCode = 1; }).finally(() => { acknowledger?.dispose(); });
  }
}
