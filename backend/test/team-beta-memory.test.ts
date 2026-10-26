import assert from 'node:assert/strict';
import test from 'node:test';
import { resolve } from 'node:path';
import { parseTeamLinuxOptions, validateTeamLinuxResult } from '../tool/profile-team-beta-linux.ts';
import { TEAM_MEMORY_OBSERVATION, TEAM_MEMORY_INTAKE, teamMemoryLabel } from '../tool/profile-team-beta.ts';
import { runTeamSession } from '../tool/memory/team-session.ts';

function snapshot() {
  return { schemaVersion: '1', kind: 'memory', rssBytes: 204_800_000, maxRssKiB: 250_000, maxRssBytes: 256_000_000,
    cgroup: { version: 2, currentBytes: 220_000_000, peakBytes: 300_000_000, limitBytes: 499_998_720,
      swapMaxBytes: 0, cpuMax: '100000 100000', events: { low: 0, high: 0, max: 0, oom: 0, oom_kill: 0 } } };
}
function inspection() {
  return { Config: { User: '1000:1000' },
    HostConfig: { Memory: 500_000_000, MemorySwap: 500_000_000, NanoCpus: 1_000_000_000, ReadonlyRootfs: true,
      Privileged: false, PublishAllPorts: false, CapDrop: ['ALL'], CapAdd: [], Binds: [], VolumesFrom: [], Devices: [],
      DeviceRequests: [], Sysctls: {}, PortBindings: {}, NetworkMode: 'none', PidMode: '',
      IpcMode: 'private', UTSMode: '', SecurityOpt: ['no-new-privileges'], RestartPolicy: { Name: 'no', MaximumRetryCount: 0 } },
    Mounts: [{ Type: 'volume', RW: false }], NetworkSettings: { Ports: { '8788/tcp': null } },
    State: { Status: 'exited', Running: false, OOMKilled: false, Dead: false, Error: '', ExitCode: 0 } };
}
function worker() {
  return { scenario: 'hpsm-near24-repeat', status: 'passed', iterations: 12, selectedPhotos: 1,
    boxesPerPhoto: 20, labelCharactersPerPhoto: 800, retryIdentityPreserved: true,
    selectedBytes: 25_128_933, selectedPixels: 16_000_000, pageCounts: Array(12).fill(8),
    iterationRssBytes: Array(12).fill(200_000_000), peakBytes: 256_000_000,
    runtime: { node: '24.22.0', platform: 'linux', arch: 'arm64', uid: 1000,
      execArgv: ['--max-old-space-size=64', '--max-semi-space-size=1'], allocatorArenaMax: 2, sharpConcurrency: 1 },
    baseline: snapshot(), memory: snapshot() };
}

test('team Linux CLI requires explicit local engine architecture and private new-report location', () => {
  const output = resolve('local-artifacts/fictional-team-memory.json');
  const args = ['--socket', '/tmp/fictional-docker.sock', '--architecture', 'arm64', '--output', output];
  const options = parseTeamLinuxOptions(args);
  assert.equal(options.socket, '/tmp/fictional-docker.sock');
  assert.equal(options.emulation, 'none'); assert.equal(options.imageSource, 'cache');
  for (const invalid of [[], [...args, '--expose-gc', 'yes'], [...args.slice(0, 4), '--output', '/tmp/report.json'],
    ['--socket', 'tcp://remote:2375', ...args.slice(2)], ['--socket', '/tmp/local.sock', '--architecture', 'qemu', ...args.slice(4)]]) {
    assert.throws(() => parseTeamLinuxOptions(invalid));
  }
});

test('complete repeated team workload accepts exact native measurements and immutable container limits', () => {
  assert.equal(validateTeamLinuxResult(worker(), inspection(), 'hpsm-near24-repeat', 'arm64'), true);
  assert.equal(validateTeamLinuxResult(worker(), inspection(), 'hpsm-near24-repeat', 'amd64'), false);
  assert.equal(validateTeamLinuxResult(worker(), inspection(), 'scfhp-six', 'arm64'), false);
});

test('missing workloads, changed limits, forced GC, memory pressure and failed exits cannot become passing evidence', () => {
  const changes: ((report: any, container: any) => void)[] = [
    r => { r.status = 'failed'; }, r => { r.iterations = 11; }, r => { r.pageCounts.pop(); },
    r => { r.iterationRssBytes.pop(); }, r => { r.retryIdentityPreserved = false; },
    r => { r.selectedPixels = 1_000_000; }, r => { r.selectedBytes = 1; },
    r => { r.boxesPerPhoto = 19; }, r => { r.labelCharactersPerPhoto = 799; },
    r => { r.peakBytes = 400_000_001; }, r => { r.memory.cgroup.peakBytes = 400_000_001; },
    r => { r.memory.cgroup.events.max = 1; }, r => { r.memory.cgroup.events.oom = 1; },
    r => { r.memory.cgroup.events.oom_kill = 1; }, r => { r.memory.maxRssBytes = 1; },
    r => { r.memory.cgroup.limitBytes = 600_000_000; }, r => { r.runtime.execArgv.push('--expose-gc'); },
    r => { r.runtime.sharpConcurrency = 4; }, r => { r.runtime.uid = 0; },
    r => { r.memory = null; }, (_, c) => { c.State.ExitCode = 137; }, (_, c) => { c.State.OOMKilled = true; },
    (_, c) => { c.HostConfig.Memory = 600_000_000; }, (_, c) => { c.HostConfig.MemorySwap = 1_000_000_000; },
    (_, c) => { c.HostConfig.ReadonlyRootfs = false; }, (_, c) => { c.HostConfig.NetworkMode = 'host'; },
  ];
  for (const change of changes) {
    const report = worker(), container = inspection(); change(report, container);
    assert.equal(validateTeamLinuxResult(report, container, 'hpsm-near24-repeat', 'arm64'), false, change.toString());
  }
  assert.equal(validateTeamLinuxResult(null, inspection(), 'hpsm-near24-repeat', 'arm64'), false);
});

test('Linux soak requires the complete same-process duration plus independent lifetime cgroup and RSS evidence', async () => {
  let clock = 0;
  const session = await runTeamSession({ nowMs: () => clock, wallTime: () => new Date(Date.UTC(2026, 9, 23) + clock),
    sleep: async ms => { clock += ms; }, checkpoint: async () => {}, runIteration: async () => {
      clock += 100; return { ...worker(), status: 'passed', iterations: 2, iterationRssBytes: [200_000_000, 200_000_000], pageCounts: [8, 8] };
    } });
  const report = { ...worker(), mode: 'soak', iterations: 61, pageCounts: Array(61).fill(8), iterationRssBytes: Array(61).fill(200_000_000), session };
  assert.equal(validateTeamLinuxResult(report, inspection(), 'hpsm-near24-repeat', 'arm64', 'soak'), true);
  assert.equal(validateTeamLinuxResult(report, inspection(), 'hpsm-near24-repeat', 'arm64'), false);
  for (const change of [(v: any) => { v.session.checkpoints.pop(); }, (v: any) => { v.session.elapsedMs = 59 * 60_000; },
    (v: any) => { v.memory.cgroup.events.max = 1; }, (v: any) => { v.iterationRssBytes[30]++; },
    (v: any) => { v.session.checkpoints[30].peakBytes = 399_000_000; }]) {
    const changed = structuredClone(report); change(changed);
    assert.equal(validateTeamLinuxResult(changed, inspection(), 'hpsm-near24-repeat', 'arm64', 'soak'), false);
  }
});


test('memory fixture exercises both Chinese scripts and 800 distinct annotation glyphs', () => {
  assert.match(TEAM_MEMORY_OBSERVATION, /门槛、門檻/);
  assert.ok([...TEAM_MEMORY_INTAKE].length <= 600);
  const labels = Array.from({ length: 20 }, (_, index) => teamMemoryLabel(index));
  assert.equal(labels.reduce((sum, label) => sum + [...label].length, 0), 800);
  assert.equal(new Set(labels.join('')).size, 800);
});
