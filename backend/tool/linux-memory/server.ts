import { readFile, statfs } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import type { Pool } from 'pg';
import sharp from 'sharp';
import { createDurableServer } from '../../src/api/durable-server.ts';
import { loadRuntimeBenefitsBundle } from '../../src/programs/runtime-bundle.ts';
import { AUTH, syntheticAuthFetch, syntheticDiagnostic, syntheticPool } from './protocol.ts';

export async function createSyntheticMemoryServer(pool: Pool) {
  const bundle = await loadRuntimeBenefitsBundle('scfhp-eaa-draft-v1');
  return createDurableServer({ pool, auth: AUTH, fetchImpl: syntheticAuthFetch,
    loadRegistry: bundle.loadRegistry, loadFormTemplate: bundle.loadFormTemplate });
}
export function allocatorArenaMax(value = process.env.MALLOC_ARENA_MAX): number | null {
  return value !== undefined && /^(0|[1-9][0-9]*)$/.test(value) && Number.isSafeInteger(Number(value)) ? Number(value) : null;
}
export function parseCgroupInteger(value: string): number {
  if (!/^(0|[1-9][0-9]*)\n?$/.test(value) || !Number.isSafeInteger(Number(value))) throw new Error('Invalid cgroup measurement.');
  return Number(value);
}
export function parseCgroupEvents(value: string): Record<string, number> {
  const result: Record<string, number> = {};
  for (const line of value.trimEnd().split('\n')) {
    const match = /^(low|high|max|oom|oom_kill|oom_group_kill|sock_throttled) (0|[1-9][0-9]*)$/.exec(line);
    if (!match || Object.hasOwn(result, match[1])) throw new Error('Invalid cgroup events.');
    result[match[1]] = parseCgroupInteger(match[2]);
  }
  if (!['low', 'high', 'max', 'oom', 'oom_kill'].every(key => Object.hasOwn(result, key))) throw new Error('Incomplete cgroup events.');
  return result;
}
type CgroupFile = 'memory.current' | 'memory.peak' | 'memory.max' | 'memory.swap.max' | 'memory.events' | 'cpu.max';
export interface MemorySnapshotSampler {
  cgroupV2(): Promise<boolean>;
  readCgroup(name: CgroupFile): Promise<string>;
  rssBytes(): number;
  maxRssKiB(): number;
}
export async function memorySnapshot(sampler: MemorySnapshotSampler = {
  cgroupV2: async () => (await statfs('/sys/fs/cgroup')).type === 0x63677270,
  readCgroup: name => readFile(`/sys/fs/cgroup/${name}`, 'utf8'),
  rssBytes: () => process.memoryUsage().rss,
  maxRssKiB: () => process.resourceUsage().maxRSS,
}) {
  if (!await sampler.cgroupV2()) throw new Error('cgroup v2 required.');
  const currentBytes = parseCgroupInteger(await sampler.readCgroup('memory.current'));
  const names = ['memory.max', 'memory.swap.max', 'memory.events', 'cpu.max'] as const;
  const values = await Promise.all(names.map(name => sampler.readCgroup(name)));
  const cgroup = { version: 2, currentBytes, peakBytes: parseCgroupInteger(await sampler.readCgroup('memory.peak')),
    limitBytes: parseCgroupInteger(values[0]), swapMaxBytes: parseCgroupInteger(values[1]),
    events: parseCgroupEvents(values[2]), cpuMax: values[3].trim() };
  const rssBytes = sampler.rssBytes();
  const maxRssKiB = sampler.maxRssKiB();
  return { schemaVersion: '1', kind: 'memory', rssBytes, maxRssKiB, maxRssBytes: maxRssKiB * 1024, cgroup };
}
let phase = 'arguments';
async function main() {
  if (process.argv.length !== 2 || process.platform !== 'linux') throw new Error('Linux container required.');
  phase = 'database-tls';
  const pool = await syntheticPool();
  phase = 'durable-server-startup';
  const { server } = await createSyntheticMemoryServer(pool).catch(async error => { await pool.end(); throw error; });
  let reporting = false, closing = false;
  process.on('SIGUSR2', () => {
    if (reporting || closing) return;
    reporting = true;
    void memorySnapshot().then(value => console.log(JSON.stringify(value)), error => {
      syntheticDiagnostic('memory-snapshot', error);
      console.log(JSON.stringify({ schemaVersion: '1', kind: 'memory', status: 'failed' }));
    }).finally(() => { reporting = false; });
  });
  const stop = () => {
    if (closing) return;
    closing = true;
    const deadline = setTimeout(() => process.exit(1), 15_000); deadline.unref();
    server.close(() => { void pool.end().then(() => { clearTimeout(deadline); }, () => { process.exitCode = 1; }); });
    server.closeIdleConnections();
  };
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
  phase = 'listener';
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(8788, '0.0.0.0', () => { server.off('error', reject); resolve(); });
  });
  phase = 'baseline-memory';
  console.log(JSON.stringify({ schemaVersion: '1', kind: 'ready', runtime: { node: process.versions.node,
    platform: process.platform, arch: process.arch, uid: process.getuid!(), execArgv: process.execArgv,
    allocatorArenaMax: allocatorArenaMax(), sharpConcurrency: sharp.concurrency() }, baseline: await memorySnapshot() }));
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(error => { syntheticDiagnostic(phase, error); process.exit(1); });
}
