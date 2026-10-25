import { createHash } from 'node:crypto';
import { handleDraftExport, type DraftExportDependencies } from '../../src/api/draft-export.ts';
import { MemoryCaseRepository } from '../../src/api/memory-case-repository.ts';
import { handleUploadEvidence } from '../../src/api/write-evidence.ts';
import type { SanitizedEvidenceImage } from '../../src/evidence/types.ts';
import { createFormAnswerContext } from '../../src/forms/form-answers.ts';
import { loadRuntimeBenefitsBundle } from '../../src/programs/runtime-bundle.ts';
import type { CaseSnapshot } from '../../src/types.ts';
import { readFixture, type FixtureName } from './fixture.ts';

export const SCENARIOS = ['pdf-solid-16mp', 'pdf-alpha-16mp', 'pdf-six-16mp', 'pdf-near24mb',
  'upload-near8mb-jpeg', 'upload-16mp-jpeg', 'upload-repeat-16mp', 'pdf-repeat-16mp', 'reject-oversize'] as const;
export type Scenario = typeof SCENARIOS[number];
export interface WorkloadMetrics { inputBytes: number; selectedEvidenceBytes: number; selectedEvidencePixels: number }
export interface MemoryWorkload {
  metrics: WorkloadMetrics;
  run(): Promise<Record<string, boolean>>;
}
const NOW = '2026-10-18T19:00:00.000Z';
const OWNER = 'synthetic-memory-owner';
const CASE_ID = 'synthetic-memory-case';
const TOKEN = 'synthetic-memory-token';
const base = { schemaVersion: '1', caseId: CASE_ID, expectedCaseRevision: 1 };
const snapshot = (count: number): CaseSnapshot => ({ schemaVersion: '1', caseId: CASE_ID, revision: 1,
  profile: { city: null, county: null, healthPlan: null, tenure: null, ageYears: null,
    householdSize: null, annualIncomeUsd: null, ownerConsentReported: null }, unresolvedFields: [],
  findings: [{ id: 'synthetic-finding', room: 'entrance', observation: 'Generated pixels for local capacity testing only.',
    reviewState: 'confirmed', evidenceIds: Array.from({ length: count }, (_, index) => `synthetic-photo-${index + 1}`), measurements: [] }] });
const authenticate = async (token: string) => token === TOKEN ? { userId: OWNER } : null;
const hash = (value: Uint8Array) => createHash('sha256').update(value).digest('hex');

async function seed(directory: string, name: FixtureName, count: number) {
  const fixture = await readFixture(directory, name);
  const checked = { width: fixture.metadata.width, height: fixture.metadata.height,
    byteLength: fixture.bytes.length, sha256: fixture.metadata.sha256 };
  const image: SanitizedEvidenceImage = { ...checked, bytes: fixture.bytes, mediaType: 'image/png', processingVersion: 'evidence-png-v1' };
  const cases = new MemoryCaseRepository([{ userId: OWNER, snapshot: snapshot(count) }]);
  for (let index = 0; index < count; index++) {
    const saved = await cases.saveEvidenceIfCurrent({ userId: OWNER, caseId: CASE_ID, revision: 1,
      expectedCatalogRevision: index, evidenceId: `synthetic-photo-${index + 1}`, expectedEvidenceRevision: 0,
      findingId: 'synthetic-finding', image, capturedAt: null, preparedAt: NOW });
    if (saved.status !== 'saved') throw new Error('Synthetic evidence setup failed.');
  }
  return { cases, metrics: { inputBytes: fixture.bytes.length, selectedEvidenceBytes: fixture.bytes.length * count,
    selectedEvidencePixels: checked.width * checked.height * count } };
}

async function pdfWorkload(directory: string, scenario: Scenario): Promise<MemoryWorkload> {
  const name: FixtureName = scenario === 'pdf-alpha-16mp' ? 'alpha.png'
    : scenario === 'pdf-six-16mp' ? 'six.png' : scenario === 'pdf-near24mb' || scenario === 'pdf-repeat-16mp' ? 'near24.png' : 'solid.png';
  const count = scenario === 'pdf-six-16mp' ? 6 : 1;
  const { cases, metrics } = await seed(directory, name, count);
  const bundle = await loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1');
  const form = await bundle.loadFormTemplate('scfhp-eaa');
  if (!form || form.template.pageCount !== 5) throw new Error('Bundled draft form unavailable.');
  let sequence = 0, retainedArtifact: string | undefined;
  const deps: DraftExportDependencies = { authenticate, cases, now: () => new Date(NOW),
    loadRegistry: bundle.loadRegistry, loadFormTemplate: bundle.loadFormTemplate,
    newArtifactId: () => `synthetic-export-${++sequence}` };
  const request = { ...base, programId: 'scfhp-eaa', expectedFormContextId: createFormAnswerContext(form.template).formContextId,
    expectedAnswerRevision: 0, expectedEvidenceCatalogRevision: count, generationKey: 'synthetic-memory-attempt',
    selectedEvidence: Array.from({ length: count }, (_, index) => ({ evidenceId: `synthetic-photo-${index + 1}`,
      expectedEvidenceRevision: 1, reviewedForExport: true })) };
  return { metrics, async run() {
    const created = await handleDraftExport({ body: request, bearerToken: TOKEN }, deps, 'create-draft-export');
    const assertions: Record<string, boolean> = { createAccepted: created.status === 200, draftOnly: false,
      expectedPages: false, exactSelections: false, downloadAccepted: false, pdfMagic: false,
      downloadDigestMatches: false, privateNoStore: false, retryIdentityPreserved: false };
    if (created.status !== 200 || !('artifactId' in created.body)) return assertions;
    const artifact = created.body;
    assertions.draftOnly = artifact.status === 'draft' && artifact.warnings.includes('INCOMPLETE_DRAFT')
      && artifact.warnings.includes('NOT_SUBMITTED') && artifact.warnings.includes('POLICY_CURRENTNESS_UNKNOWN');
    assertions.expectedPages = artifact.pageCount === 5 + count;
    assertions.exactSelections = artifact.selectedEvidence.length === count;
    assertions.retryIdentityPreserved = retainedArtifact === undefined || retainedArtifact === artifact.artifactId;
    retainedArtifact = artifact.artifactId;
    const downloaded = await handleDraftExport({ body: { ...base, artifactId: artifact.artifactId }, bearerToken: TOKEN },
      deps, 'download-draft-export');
    assertions.downloadAccepted = downloaded.status === 200;
    if (downloaded.body instanceof Uint8Array) {
      assertions.pdfMagic = Buffer.from(downloaded.body.subarray(0, 5)).toString('ascii') === '%PDF-';
      assertions.downloadDigestMatches = downloaded.body.length === artifact.byteLength && hash(downloaded.body) === artifact.sha256;
      assertions.privateNoStore = downloaded.headers['Cache-Control'] === 'no-store'
        && downloaded.headers['X-Content-Type-Options'] === 'nosniff';
    }
    return assertions;
  } };
}

function uploadRequest(bytes: Buffer) {
  return { ...base, expectedCatalogRevision: 0, evidenceId: 'synthetic-photo-1', expectedEvidenceRevision: 0,
    findingId: 'synthetic-finding', capturedAt: null, imageBase64: bytes.toString('base64') };
}
async function uploadWorkload(directory: string, scenario: Scenario): Promise<MemoryWorkload> {
  const fullPixels = scenario !== 'upload-near8mb-jpeg';
  const fixture = await readFixture(directory, fullPixels ? 'full16mp.jpg' : 'near8.jpg');
  const { width, height } = fixture.metadata;
  const cases = new MemoryCaseRepository([{ userId: OWNER, snapshot: snapshot(1) }]);
  const metrics = { inputBytes: fixture.bytes.length, selectedEvidenceBytes: 0,
    selectedEvidencePixels: width * height };
  const body = uploadRequest(fixture.bytes);
  const deps = { authenticate, cases, now: () => new Date(NOW) };
  let revision = 0, retainedDigest: string | undefined;
  return { metrics, async run() {
    const expectedRevision = revision + 1;
    const result = await handleUploadEvidence({ body: { ...body, expectedCatalogRevision: revision,
      expectedEvidenceRevision: revision }, bearerToken: TOKEN }, deps);
    const assertions: Record<string, boolean> = { inputBounds: metrics.inputBytes >= (fullPixels ? 6 : 7.5) * 1024 * 1024
      && metrics.inputBytes <= 8 * 1024 * 1024, uploadAccepted: result.status === 200,
      fixturePixelCoverage: metrics.selectedEvidencePixels === (fullPixels ? 16_000_000 : 7_290_000),
      pngMetadata: false, exactDimensions: false, savedBytesMatch: false, replacementRevision: false,
      stableSanitizedDigest: false, currentCatalog: false, singleStoredEvidence: false,
      privateNoStore: result.headers['Cache-Control'] === 'no-store' };
    if (result.status !== 200 || !('evidence' in result.body)) return assertions;
    const descriptor = result.body.evidence;
    metrics.selectedEvidenceBytes = descriptor.byteLength;
    assertions.pngMetadata = descriptor.mediaType === 'image/png' && descriptor.processingVersion === 'evidence-png-v1';
    assertions.exactDimensions = descriptor.width === width && descriptor.height === height;
    assertions.replacementRevision = result.body.catalogRevision === expectedRevision && descriptor.evidenceRevision === expectedRevision;
    assertions.stableSanitizedDigest = retainedDigest === undefined || retainedDigest === descriptor.sha256;
    retainedDigest = descriptor.sha256;
    const saved = await cases.readEvidenceForUser({ userId: OWNER, caseId: CASE_ID, revision: 1,
      expectedCatalogRevision: expectedRevision, evidenceId: descriptor.evidenceId, expectedEvidenceRevision: expectedRevision });
    assertions.savedBytesMatch = saved.status === 'found' && hash(saved.asset.bytes) === descriptor.sha256
      && saved.asset.bytes.length === descriptor.byteLength;
    const catalog = await cases.readEvidenceCatalogForUser(OWNER, CASE_ID);
    assertions.currentCatalog = catalog.status === 'found' && catalog.catalog.catalogRevision === expectedRevision
      && catalog.catalog.caseRevision === 1 && catalog.catalog.evidence[0]?.evidenceRevision === expectedRevision;
    assertions.singleStoredEvidence = catalog.status === 'found' && catalog.catalog.evidence.length === 1
      && catalog.catalog.evidence[0].evidenceId === 'synthetic-photo-1' && catalog.catalog.evidence[0].sha256 === descriptor.sha256;
    revision = expectedRevision;
    return assertions;
  } };
}

async function rejectedWorkload(directory: string): Promise<MemoryWorkload> {
  const fixture = await readFixture(directory, 'oversize.png');
  const cases = new MemoryCaseRepository([{ userId: OWNER, snapshot: snapshot(1) }]);
  const deps = { authenticate, cases, now: () => new Date(NOW) };
  const aggregate = await seed(directory, 'solid.png', 2);
  const metrics = { inputBytes: fixture.bytes.length, selectedEvidenceBytes: aggregate.metrics.selectedEvidenceBytes,
    selectedEvidencePixels: aggregate.metrics.selectedEvidencePixels };
  return { metrics, async run() {
    const pixelResult = await handleUploadEvidence({ body: uploadRequest(fixture.bytes), bearerToken: TOKEN }, deps);
    const byteResult = await handleUploadEvidence({ body: uploadRequest(Buffer.alloc(8 * 1024 * 1024 + 1)), bearerToken: TOKEN }, deps);
    let formsLoaded = false, published = false;
    aggregate.cases.publishExportIfCurrent = async () => { published = true; return { status: 'quota_exceeded' }; };
    const result = await handleDraftExport({ bearerToken: TOKEN, body: { ...base, programId: 'scfhp-eaa',
      expectedFormContextId: 'a'.repeat(64), expectedAnswerRevision: 0, expectedEvidenceCatalogRevision: 2,
      generationKey: 'synthetic-rejected-attempt', selectedEvidence: [1, 2].map(index => ({
        evidenceId: `synthetic-photo-${index}`, expectedEvidenceRevision: 1, reviewedForExport: true })) } },
    { ...deps, cases: aggregate.cases, loadRegistry: async () => { formsLoaded = true; return []; },
      loadFormTemplate: async () => { formsLoaded = true; return null; } }, 'create-draft-export');
    const catalog = await cases.readEvidenceCatalogForUser(OWNER, CASE_ID);
    return { pixelLimitRejected: pixelResult.status === 422 && 'error' in pixelResult.body && pixelResult.body.error.code === 'INVALID_IMAGE',
      inputByteLimitRejected: byteResult.status === 400 && 'error' in byteResult.body && byteResult.body.error.code === 'INVALID_REQUEST',
      aggregateLimitRejected: result.status === 422 && 'error' in result.body && result.body.error.code === 'EXPORT_REVIEW_REQUIRED',
      rejectedBeforeForms: !formsLoaded, rejectedBeforePublication: !published,
      noPartialUpload: catalog.status === 'found' && catalog.catalog.evidence.length === 0 && catalog.catalog.catalogRevision === 0 };
  } };
}

export async function createMemoryWorkload(directory: string, scenario: Scenario): Promise<MemoryWorkload> {
  if (scenario.startsWith('upload-')) return uploadWorkload(directory, scenario);
  if (scenario === 'reject-oversize') return rejectedWorkload(directory);
  return pdfWorkload(directory, scenario);
}
