import { setTimeout as pause } from 'node:timers/promises';
import { constants } from 'node:fs';
import { open, rename, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { dirname } from 'node:path';
import { SOAK_CLIENT_DEADLINE_MS, sessionConfiguration } from '../linux-memory/protocol.ts';

export const TEAM_SESSION = Object.freeze({ ...sessionConfiguration('soak'), deadlineMs: SOAK_CLIENT_DEADLINE_MS });

export async function createTeamProgressWriter(output: string) {
  const path = `${output}.progress.json`, initial = await open(path, 'wx', 0o600);
  try { await initial.sync(); } finally { await initial.close(); }
  return async (value: unknown) => {
    const temporary = `${path}.${randomUUID()}.tmp`;
    try {
      const file = await open(temporary, 'wx', 0o600);
      try { await file.writeFile(JSON.stringify(value) + '\n'); await file.sync(); } finally { await file.close(); }
      await rename(temporary, path);
      const parent = await open(dirname(path), constants.O_RDONLY | constants.O_NOFOLLOW);
      try { await parent.sync(); } finally { await parent.close(); }
    } finally { await rm(temporary, { force: true }); }
  };
}
export type TeamMemoryMode = 'boundary' | 'soak';
export interface TeamIteration {
  status: 'passed' | 'failed'; iterations: number; selectedPhotos: number; boxesPerPhoto: number;
  labelCharactersPerPhoto: number; selectedBytes: number; selectedPixels: number; peakBytes: number;
  iterationRssBytes: number[]; pageCounts: number[]; retryIdentityPreserved: boolean;
}
export interface TeamCheckpoint {
  schemaVersion: '1'; kind: 'team-memory-checkpoint'; mode: 'soak'; iteration: number;
  plannedIterations: number; capturedAt: string; elapsedMs: number; iterationElapsedMs: number;
  rssBytes: number; peakBytes: number; pageCount: number; storedArtifactsReleased: true;
}
export interface TeamSessionResult {
  mode: 'soak'; status: 'passed' | 'failed'; startedAt: string; finishedAt: string; elapsedMs: number;
  plannedIterations: number; iterations: number; intervalMs: number; deadlineMs: number;
  operationsPerIteration: 2; repositoryLifetime: 'one-iteration'; storedArtifactsReleased: true;
  checkpoints: TeamCheckpoint[]; failure?: 'aborted' | 'deadline_exceeded' | 'workload_failed';
}
const integer = (value: unknown, min: number, max = Number.MAX_SAFE_INTEGER): value is number =>
  Number.isSafeInteger(value) && Number(value) >= min && Number(value) <= max;
const instant = (value: unknown): value is string => typeof value === 'string' &&
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value) && Number.isFinite(Date.parse(value));

export function validTeamCheckpoint(value: any, expectedIteration: number): value is TeamCheckpoint {
  return value?.schemaVersion === '1' && value.kind === 'team-memory-checkpoint' && value.mode === 'soak'
    && value.iteration === expectedIteration && integer(expectedIteration, 1, TEAM_SESSION.iterations)
    && value.plannedIterations === TEAM_SESSION.iterations && instant(value.capturedAt)
    && integer(value.elapsedMs, (expectedIteration - 1) * TEAM_SESSION.intervalMs, TEAM_SESSION.deadlineMs)
    && integer(value.iterationElapsedMs, 0, value.elapsedMs)
    && integer(value.rssBytes, 1, value.peakBytes) && integer(value.peakBytes, 1, 400_000_000)
    && integer(value.pageCount, 8, 32) && value.storedArtifactsReleased === true;
}

export function validTeamSession(value: any): value is TeamSessionResult {
  if (!value || value.mode !== 'soak' || value.status !== 'passed' || value.failure !== undefined
    || !instant(value.startedAt) || !instant(value.finishedAt) || Date.parse(value.finishedAt) < Date.parse(value.startedAt)
    || value.plannedIterations !== TEAM_SESSION.iterations || value.iterations !== TEAM_SESSION.iterations
    || value.intervalMs !== TEAM_SESSION.intervalMs || value.deadlineMs !== TEAM_SESSION.deadlineMs
    || value.operationsPerIteration !== 2 || value.repositoryLifetime !== 'one-iteration' || value.storedArtifactsReleased !== true
    || !integer(value.elapsedMs, (TEAM_SESSION.iterations - 1) * TEAM_SESSION.intervalMs, TEAM_SESSION.deadlineMs)
    || !Array.isArray(value.checkpoints) || value.checkpoints.length !== TEAM_SESSION.iterations
    || Math.abs(Date.parse(value.finishedAt) - Date.parse(value.startedAt) - value.elapsedMs) > 5000) return false;
  return value.checkpoints.every((checkpoint: TeamCheckpoint, i: number) => validTeamCheckpoint(checkpoint, i + 1)
    && checkpoint.elapsedMs <= value.elapsedMs
    && Math.abs(Date.parse(checkpoint.capturedAt) - Date.parse(value.startedAt) - checkpoint.elapsedMs) <= 5000
    && (i === 0 || checkpoint.elapsedMs - checkpoint.iterationElapsedMs >=
        value.checkpoints[i - 1].elapsedMs - value.checkpoints[i - 1].iterationElapsedMs + TEAM_SESSION.intervalMs
      && checkpoint.peakBytes >= value.checkpoints[i - 1].peakBytes))
    && value.checkpoints.at(-1).elapsedMs <= value.elapsedMs;
}

export async function runTeamSession(deps: {
  runIteration(): Promise<TeamIteration>;
  checkpoint(value: TeamCheckpoint): Promise<void>;
  nowMs?: () => number; wallTime?: () => Date; sleep?: (ms: number) => Promise<void>; signal?: AbortSignal;
}): Promise<TeamSessionResult> {
  const now = deps.nowMs ?? (() => performance.now()), wall = deps.wallTime ?? (() => new Date());
  const sleep = deps.sleep ?? (async ms => { await pause(ms, undefined, { signal: deps.signal }); });
  const started = now(); let observed = started;
  const result: TeamSessionResult = { mode: 'soak', status: 'failed', startedAt: wall().toISOString(), finishedAt: '', elapsedMs: 0,
    plannedIterations: TEAM_SESSION.iterations, iterations: 0, intervalMs: TEAM_SESSION.intervalMs,
    deadlineMs: TEAM_SESSION.deadlineMs, operationsPerIteration: 2, repositoryLifetime: 'one-iteration',
    storedArtifactsReleased: true, checkpoints: [] };
  const elapsed = () => {
    const current = now();
    if (!Number.isFinite(current) || current < observed) throw new Error('Invalid session clock.');
    observed = current;
    if (deps.signal?.aborted) { result.failure = 'aborted'; throw new Error('Session stopped.'); }
    if (current - started >= TEAM_SESSION.deadlineMs) { result.failure = 'deadline_exceeded'; throw new Error('Session deadline.'); }
    return Math.floor(current - started);
  };
  try {
    let previousStart = -TEAM_SESSION.intervalMs;
    for (let i = 0; i < TEAM_SESSION.iterations; i++) {
      const due = Math.max(i * TEAM_SESSION.intervalMs, previousStart + TEAM_SESSION.intervalMs);
      for (let waits = 0; ; waits++) {
        const remaining = due - elapsed(); if (remaining <= 0) break;
        if (waits >= 8) throw new Error('Session timer did not advance.');
        await sleep(Math.min(60_000, remaining));
      }
      const before = elapsed(); previousStart = before;
      const measured = await deps.runIteration(), after = elapsed();
      if (measured.status !== 'passed' || measured.iterations !== 2 || measured.selectedPhotos !== 1
        || measured.selectedPixels !== 16_000_000 || !integer(measured.selectedBytes, Math.ceil(23.5 * 1024 * 1024), 24 * 1024 * 1024)
        || measured.boxesPerPhoto !== 20 || measured.labelCharactersPerPhoto !== 800 || !measured.retryIdentityPreserved
        || measured.iterationRssBytes.length !== 2 || measured.pageCounts.length !== 2) throw new Error('Incomplete iteration.');
      const checkpoint: TeamCheckpoint = { schemaVersion: '1', kind: 'team-memory-checkpoint', mode: 'soak', iteration: i + 1,
        plannedIterations: TEAM_SESSION.iterations, capturedAt: wall().toISOString(), elapsedMs: after, iterationElapsedMs: after - before,
        rssBytes: measured.iterationRssBytes.at(-1)!, peakBytes: measured.peakBytes, pageCount: measured.pageCounts.at(-1)!, storedArtifactsReleased: true };
      if (!validTeamCheckpoint(checkpoint, i + 1)) throw new Error('Invalid checkpoint.');
      result.checkpoints.push(checkpoint); result.iterations++;
      await deps.checkpoint(checkpoint);
    }
    result.elapsedMs = elapsed(); result.finishedAt = wall().toISOString(); result.status = 'passed';
    if (!validTeamSession(result)) throw new Error('Incomplete session.');
  } catch {
    result.status = 'failed'; result.failure ??= deps.signal?.aborted ? 'aborted' : 'workload_failed';
  } finally {
    result.elapsedMs = Math.max(0, Math.floor(now() - started)); result.finishedAt = wall().toISOString();
  }
  return result;
}
