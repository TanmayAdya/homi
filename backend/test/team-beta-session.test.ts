import assert from 'node:assert/strict';
import test from 'node:test';
import { resolve } from 'node:path';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createTeamProgressWriter, runTeamSession, TEAM_SESSION, validTeamSession, type TeamCheckpoint, type TeamIteration } from '../tool/memory/team-session.ts';
import { parseTeamLocalOptions } from '../tool/profile-team-beta.ts';
import { parseTeamLinuxOptions } from '../tool/profile-team-beta-linux.ts';

const iteration = (): TeamIteration => ({ status: 'passed', iterations: 2, selectedPhotos: 1, selectedBytes: 25_128_933,
  selectedPixels: 16_000_000, boxesPerPhoto: 20, labelCharactersPerPhoto: 800, peakBytes: 300_000_000,
  iterationRssBytes: [240_000_000, 230_000_000], pageCounts: [8, 8], retryIdentityPreserved: true });
function clock() {
  let time = 0, calls = 0, active = false;
  const checkpoints: TeamCheckpoint[] = [], starts: number[] = [];
  return { checkpoints, starts, advance(ms: number) { time += ms; }, calls: () => calls,
    deps: { nowMs: () => time, wallTime: () => new Date(Date.UTC(2026, 9, 23) + time),
      sleep: async (ms: number) => { assert.ok(ms > 0 && ms <= 60_000); time += ms; },
      runIteration: async () => { assert.equal(active, false); active = true; calls++; starts.push(time); time += 500; active = false; return iteration(); },
      checkpoint: async (value: TeamCheckpoint) => { checkpoints.push(structuredClone(value)); } } };
}

test('fixed single-worker schedule completes minute0 through60 with exact retry work and bounded scalar checkpoints', async () => {
  const fake = clock(), result = await runTeamSession(fake.deps);
  assert.equal(result.status, 'passed'); assert.equal(validTeamSession(result), true);
  assert.equal(fake.calls(), 61); assert.equal(fake.checkpoints.length, 61);
  assert.deepEqual(fake.starts, Array.from({ length: 61 }, (_, i) => i * 60_000));
  assert.equal(result.elapsedMs, 3_600_500); assert.equal(result.operationsPerIteration, 2);
  assert.equal(result.repositoryLifetime, 'one-iteration'); assert.equal(result.storedArtifactsReleased, true);
});

test('late work never causes overlapping work or a catch-up burst', async () => {
  const fake = clock(); let first = true;
  const original = fake.deps.runIteration;
  fake.deps.runIteration = async () => { if (first) { first = false; fake.advance(90_000); } return original(); };
  const result = await runTeamSession(fake.deps);
  assert.equal(result.status, 'passed');
  for (let i = 2; i < fake.starts.length; i++) assert.ok(fake.starts[i] - fake.starts[i - 1] >= 60_000);
});

test('scheduler rechecks early wakeups and cannot shorten the one-hour evidence', async () => {
  const fake = clock(); let early = true;
  fake.deps.sleep = async ms => { fake.advance(early ? Math.max(1, Math.floor(ms / 2)) : ms); early = false; };
  const result = await runTeamSession(fake.deps);
  assert.equal(result.status, 'passed'); assert.ok(result.elapsedMs >= 3_600_000);
  assert.equal(validTeamSession(result), true);
});

test('nonadvancing waiters and backward clocks fail finitely before further renderer work', async () => {
  const stuck = clock(); let sleeps = 0;
  stuck.deps.sleep = async () => { sleeps++; };
  const timed = await runTeamSession(stuck.deps);
  assert.equal(timed.status, 'failed'); assert.equal(timed.iterations, 1); assert.equal(sleeps, 8); assert.equal(stuck.calls(), 1);
  const backwards = clock(); backwards.deps.sleep = async () => { backwards.advance(-1); };
  const invalid = await runTeamSession(backwards.deps);
  assert.equal(invalid.status, 'failed'); assert.equal(invalid.iterations, 1);
});

test('memory or retry failure stops the session instead of waiting out the advertised duration', async () => {
  for (const change of [(v: TeamIteration) => { v.peakBytes = 400_000_001; }, (v: TeamIteration) => { v.retryIdentityPreserved = false; },
    (v: TeamIteration) => { v.iterations = 1; }, (v: TeamIteration) => { v.selectedPixels = 1; }]) {
    const fake = clock(); fake.deps.runIteration = async () => { const value = iteration(); change(value); return value; };
    const result = await runTeamSession(fake.deps);
    assert.equal(result.status, 'failed'); assert.equal(validTeamSession(result), false);
    assert.equal(result.iterations, 0); assert.equal(result.failure, 'workload_failed');
  }
});

test('deadline, interruption and checkpoint write failure retain partial progress without a passing aggregate', async () => {
  const late = clock(); late.deps.runIteration = async () => { late.advance(TEAM_SESSION.deadlineMs); return iteration(); };
  const deadline = await runTeamSession(late.deps); assert.equal(deadline.failure, 'deadline_exceeded'); assert.equal(deadline.status, 'failed');
  const stopped = clock(), controller = new AbortController();
  stopped.deps.checkpoint = async value => { stopped.checkpoints.push(value); controller.abort(); };
  const interrupted = await runTeamSession({ ...stopped.deps, signal: controller.signal });
  assert.equal(interrupted.failure, 'aborted'); assert.equal(interrupted.iterations, 1);
  const broken = clock(); broken.deps.checkpoint = async () => { throw new Error('Synthetic disk failure.'); };
  const failed = await runTeamSession(broken.deps); assert.equal(failed.failure, 'workload_failed'); assert.equal(failed.iterations, 1);
});

test('report validator rejects a claimed hour assembled from burst or incomplete checkpoints', async () => {
  const fake = clock(), valid = await runTeamSession(fake.deps);
  const changes: ((value: any) => void)[] = [
    v => { v.elapsedMs = 59 * 60_000; }, v => { v.iterations = 12; }, v => { v.checkpoints.pop(); },
    v => { v.operationsPerIteration = 1; }, v => { v.repositoryLifetime = 'new-process'; },
    v => { v.storedArtifactsReleased = false; }, v => { v.deadlineMs *= 2; },
    v => { v.checkpoints[30].elapsedMs = v.checkpoints[29].elapsedMs; },
    v => { v.checkpoints[10].peakBytes = 400_000_001; }, v => { v.checkpoints[20].iteration = 1; },
    v => { v.finishedAt = 'invalid'; }, v => { v.finishedAt = v.startedAt; },
    v => { v.checkpoints[10].capturedAt = v.startedAt; }, v => { v.checkpoints[10].storedArtifactsReleased = false; },
  ];
  for (const change of changes) { const bad = structuredClone(valid); change(bad); assert.equal(validTeamSession(bad), false, change.toString()); }
});

test('CLI leaves four-scenario defaults intact and makes the fixed one-hour mode an explicit private-report opt-in', () => {
  assert.deepEqual(parseTeamLocalOptions(['run']), { mode: 'boundary', output: undefined });
  const output = resolve('local-artifacts/fictional-team-soak.json');
  assert.equal(parseTeamLocalOptions(['run', '--mode', 'soak', '--output', output]).mode, 'soak');
  const linux = ['--socket', '/tmp/fictional.sock', '--architecture', 'amd64', '--output', output];
  assert.equal(parseTeamLinuxOptions(linux).mode, 'boundary');
  assert.equal(parseTeamLinuxOptions([...linux, '--mode', 'soak']).mode, 'soak');
  for (const args of [['run', '--mode', 'soak'], ['run', '--mode', 'long', '--output', output],
    ['run', '--mode', 'soak', '--output', '/tmp/public.json'], ['run', '--mode', 'soak', '--output', output, '--iterations', '3']]) {
    assert.throws(() => parseTeamLocalOptions(args));
  }
  for (const args of [[...linux, '--mode', 'long'], [...linux, '--mode', 'soak', '--iterations', '999'],
    [...linux, '--duration', '999'], [...linux, '--mode', 'soak', '--mode', 'boundary']]) assert.throws(() => parseTeamLinuxOptions(args));
});

test('progress checkpoint is exclusive, atomically replaced and private without leftover temporary files', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'sah-team-progress-')), output = join(directory, 'fictional.json');
  try {
    const write = await createTeamProgressWriter(output);
    await write({ iteration: 1 }); await write({ iteration: 2 });
    assert.deepEqual(JSON.parse(await readFile(`${output}.progress.json`, 'utf8')), { iteration: 2 });
    assert.equal((await stat(`${output}.progress.json`)).mode & 0o777, 0o600);
    assert.deepEqual(await readdir(directory), ['fictional.json.progress.json']);
    await assert.rejects(createTeamProgressWriter(output));
  } finally { await rm(directory, { recursive: true, force: true }); }
});
