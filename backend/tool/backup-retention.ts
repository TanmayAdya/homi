import { pathToFileURL } from 'node:url';
import { MAX_SCHEDULED_ENVELOPE_BYTES } from '../src/storage/backup-envelope.ts';

const PREFIX = 'safeathome-encrypted-backup-';
const NAME = /^safeathome-encrypted-backup-([1-9][0-9]{0,15})-([1-9][0-9]{0,5})$/;
const DAY = 86_400_000;
const fail = (): never => { throw Error('Private backup artifact checks failed.'); };
const positive = (n: unknown): n is number => typeof n === 'number' && Number.isSafeInteger(n) && n > 0;
export interface BackupArtifact {
  id: number; name: string; runId: number; createdAt: string; expiresAt: string;
  sizeBytes: number; expired: boolean; completed: boolean; successful: boolean;
}
function validateArtifacts(items: readonly BackupArtifact[], now: number) {
  if (items.length > 20 || !Number.isFinite(now)) fail();
  const ids = new Set<number>();
  for (const item of items) {
    const name = NAME.exec(item.name), created = Date.parse(item.createdAt), expires = Date.parse(item.expiresAt);
    if (!positive(item.id) || ids.has(item.id) || !positive(item.runId) || !name || Number(name[1]) !== item.runId
      || !Number.isFinite(created) || created > now + 300_000 || !Number.isFinite(expires) || expires <= created
      || expires - created > 91 * DAY || !positive(item.sizeBytes) || item.sizeBytes > MAX_SCHEDULED_ENVELOPE_BYTES + 65_536
      || typeof item.expired !== 'boolean' || typeof item.completed !== 'boolean' || typeof item.successful !== 'boolean'
      || item.successful && !item.completed) fail();
    ids.add(item.id);
  }
}
function active(items: readonly BackupArtifact[], now: number) {
  return items.filter(item => !item.expired && Date.parse(item.expiresAt) > now);
}
function newestSuccessful(items: readonly BackupArtifact[]) {
  return items.filter(item => item.completed && item.successful)
    .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt) || b.id - a.id);
}
export function planBackupRetention(items: readonly BackupArtifact[], currentId: number, now = Date.now()) {
  validateArtifacts(items, now);
  if (!positive(currentId)) fail();
  const available = active(items, now);
  const current = available.find(item => item.id === currentId);
  if (!current || !current.completed || !current.successful) fail();
  const keep = newestSuccessful(available).slice(0, 3).map(item => item.id);
  if (!keep.includes(currentId)) fail();
  const remove = available.filter(item => item.completed && !keep.includes(item.id)).map(item => item.id);
  return { keep, remove };
}
export function summarizeBackupRecoveryWindow(items: readonly BackupArtifact[], now = Date.now()) {
  validateArtifacts(items, now);
  const available = active(items, now), successful = newestSuccessful(available);
  const newest = successful[0];
  const latestSuccessfulAgeSeconds = newest ? Math.max(0, Math.floor((now - Date.parse(newest.createdAt)) / 1000)) : null;
  const expiries = successful.map(item => Date.parse(item.expiresAt));
  const nextExpirySeconds = expiries.length ? Math.max(0, Math.floor((Math.min(...expiries) - now) / 1000)) : null;
  const lastRecoveryExpiresAt = expiries.length ? new Date(Math.max(...expiries)).toISOString() : null;
  const warnings: string[] = [];
  if (!newest) warnings.push('no_successful_backup');
  if (latestSuccessfulAgeSeconds !== null && latestSuccessfulAgeSeconds > 36 * 3600) warnings.push('backup_stale');
  if (nextExpirySeconds !== null && nextExpirySeconds < 7 * 86400) warnings.push('backup_expiry_near');
  if (available.length > 3) warnings.push('backup_pruning_required');
  if (available.some(item => item.completed && !item.successful)) warnings.push('backup_run_failed');
  return { mode: 'private_backup_health', activeCopies: available.length, successfulCopies: successful.length,
    latestSuccessfulAgeSeconds, nextExpirySeconds, lastRecoveryExpiresAt, warnings };
}
export function checkBackupPreflight(items: readonly BackupArtifact[], now = Date.now()) {
  validateArtifacts(items, now);
  const available = active(items, now);
  if (available.length >= 4) fail();
  return { mode: 'private_backup_preflight', activeCopies: available.length, maximumTransientCopies: 4 };
}
function integerText(value: string | undefined) {
  if (!value || !/^[1-9][0-9]{0,15}$/.test(value) || !positive(Number(value))) fail();
  return Number(value);
}
async function request(fetcher: typeof fetch, token: string, route: string, method = 'GET'): Promise<any> {
  const response = await fetcher(`https://api.github.com${route}`, { method, redirect: 'error', signal: AbortSignal.timeout(10_000),
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2026-03-10' } });
  if (response.redirected) fail();
  if (method === 'DELETE') {
    try { await response.body?.cancel(); } catch {}
    if (![204, 404].includes(response.status)) fail();
    return null;
  }
  if (response.status !== 200 || response.headers.get('content-type')?.split(';')[0].trim() !== 'application/json' || !response.body) fail();
  const reader = response.body!.getReader(); const parts: Uint8Array[] = []; let total = 0;
  try {
    while (true) {
      const next = await reader.read(); if (next.done) break;
      total += next.value.length; if (total > 1024 * 1024) fail(); parts.push(next.value);
    }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(parts)));
  } finally { try { await reader.cancel(); } catch {} reader.releaseLock(); }
}
async function readManagedArtifacts(env: NodeJS.ProcessEnv, fetcher: typeof fetch, currentId?: number) {
  const repository = env.GITHUB_REPOSITORY ?? '', token = env.GITHUB_TOKEN ?? '';
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) || !token || token.length > 4096 || /\s/.test(token)) fail();
  const base = `/repos/${repository}`, repo = await request(fetcher, token, base);
  if (repo.private !== true || !positive(repo.id) || repo.default_branch !== env.GITHUB_REF_NAME) fail();
  const workflow = await request(fetcher, token, `${base}/actions/workflows/private-operations.yml`);
  if (!positive(workflow.id) || workflow.path !== '.github/workflows/private-operations.yml') fail();
  const candidates: any[] = []; let complete = false, totalCount: number | undefined;
  for (let page = 1; page <= 5; page++) {
    const result = await request(fetcher, token, `${base}/actions/artifacts?per_page=100&page=${page}`);
    if (!Number.isSafeInteger(result.total_count) || result.total_count < 0 || result.total_count > 500
      || !Array.isArray(result.artifacts) || result.artifacts.length > 100) fail();
    if (totalCount !== undefined && totalCount !== result.total_count) fail(); totalCount = result.total_count;
    candidates.push(...result.artifacts.filter((item: any) => typeof item?.name === 'string' && item.name.startsWith(PREFIX)));
    if (candidates.length > 20) fail();
    if (page * 100 >= result.total_count) { complete = true; break; }
  }
  if (!complete) fail();
  const managed: BackupArtifact[] = [], runs = new Map<number, any>();
  for (const item of candidates) {
    const source = item.workflow_run;
    if (!positive(source?.id) || source.repository_id !== repo.id || source.head_repository_id !== repo.id) fail();
    let run = runs.get(source.id);
    if (!run) { run = await request(fetcher, token, `${base}/actions/runs/${source.id}`); runs.set(source.id, run); }
    if (run.id !== source.id || run.workflow_id !== workflow.id || run.head_repository?.id !== repo.id || run.repository?.id !== repo.id
      || run.head_branch !== repo.default_branch || !['schedule', 'workflow_dispatch'].includes(run.event)) fail();
    const current = item.id === currentId;
    if (current && (run.id !== integerText(env.GITHUB_RUN_ID) || run.head_sha !== env.GITHUB_SHA
      || !['in_progress', 'completed'].includes(run.status) || run.status === 'completed' && run.conclusion !== 'success')) fail();
    managed.push({ id: item.id, name: item.name, runId: run.id, createdAt: item.created_at, expiresAt: item.expires_at,
      sizeBytes: item.size_in_bytes, expired: item.expired, completed: current || run.status === 'completed',
      successful: current || run.status === 'completed' && run.conclusion === 'success' });
  }
  return { managed, token, base };
}
export async function inspectPrivateBackupArtifacts(env: NodeJS.ProcessEnv, mode: 'health' | 'preflight', fetcher: typeof fetch = fetch, now = Date.now()) {
  const { managed } = await readManagedArtifacts(env, fetcher);
  return mode === 'health' ? summarizeBackupRecoveryWindow(managed, now) : checkBackupPreflight(managed, now);
}
export async function retainPrivateBackupArtifacts(env: NodeJS.ProcessEnv, fetcher: typeof fetch = fetch, now = Date.now()) {
  const currentId = integerText(env.SAFEATHOME_BACKUP_ARTIFACT_ID);
  const { managed, token, base } = await readManagedArtifacts(env, fetcher, currentId);
  const plan = planBackupRetention(managed, currentId, now);
  for (const id of plan.remove) await request(fetcher, token, `${base}/actions/artifacts/${id}`, 'DELETE');
  return { mode: 'private_backup_retention', keptSuccessful: plan.keep.length, removed: plan.remove.length, maximumSuccessfulCopies: 3 };
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  const mode = process.argv[2];
  if (process.argv.length > 3 || mode !== undefined && !['health', 'preflight'].includes(mode)) {
    console.error('Backup artifact checks accept only health, preflight, or no arguments for post-upload retention.'); process.exitCode = 1;
  } else {
    const operation = mode === 'health' || mode === 'preflight'
      ? inspectPrivateBackupArtifacts(process.env, mode) : retainPrivateBackupArtifacts(process.env);
    operation.then(report => {
      console.log(JSON.stringify(report));
      if ('warnings' in report && report.warnings.length) process.exitCode = 2;
    }).catch(() => {
      console.error('Private backup artifact checks failed. Check recovery-copy expiry, workflow provenance, copy limits and Actions permissions. No pre-upload recovery copies are deleted.');
      process.exitCode = 1;
    });
  }
}
