import { randomBytes } from 'node:crypto';
import { createDemoEvidenceImage } from '../fixtures/demo-evidence.ts';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';

async function main() {
  if (process.argv.length !== 2 || process.env.NODE_ENV !== 'test') throw new Error('Local test mode required.');
  const alice = randomBytes(32).toString('base64url'), bob = randomBytes(32).toString('base64url');
  const tokens = new Map([[alice, 'fictional-team-alice'], [bob, 'fictional-team-bob']]);
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const image = await createDemoEvidenceImage();
  const cases = new MemoryCaseRepository([]);
  const dependencies = { cases, authenticate: async (token: string) => tokens.has(token) ? { userId: tokens.get(token)! } : null,
    loadRegistry: bundle.loadRegistry, loadFormTemplate: bundle.loadFormTemplate, now: () => new Date() };
  const server = createMatchingServer(dependencies, dependencies, dependencies, dependencies, dependencies, dependencies,
    { assessmentDependencies: dependencies, programIntakeDependencies: dependencies,
      caseListDependencies: dependencies, planNameDependencies: dependencies, requestTrackingDependencies: dependencies });
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const address = server.address(); if (!address || typeof address === 'string') throw new Error('Local listener unavailable.');
  console.log(JSON.stringify({ type: 'team-beta-ready', baseUri: `http://127.0.0.1:${address.port}`,
    alice, bob, imageBase64: Buffer.from(image.bytes).toString('base64') }));
  const stop = () => { server.close(); server.closeAllConnections(); };
  const deadline = setTimeout(stop, 120_000); deadline.unref();
  process.once('SIGINT', stop); process.once('SIGTERM', stop);
}
main().catch(() => { console.error('Fictional team HTTP fixture failed. No session details logged.'); process.exitCode = 1; });
