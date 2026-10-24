import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { nativeMemoryOptions, parseNativeMemoryMode, profileNativeAmd64, requireNativeAmd64 } from '../tool/profile-native-amd64.ts';
import type { LinuxOptions } from '../tool/linux-memory/container-harness.ts';

const nativeHost = { platform: 'linux', arch: 'x64', machine: 'x86_64' };

test('native command defaults to both modes and rejects architecture, endpoint, emulation and extra argument overrides', () => {
  assert.equal(parseNativeMemoryMode([]), 'all');
  for (const mode of ['boundary', 'long', 'all'] as const) assert.equal(parseNativeMemoryMode(['--mode', mode]), mode);
  for (const args of [['--mode'], ['--mode', 'unknown'], ['--mode', 'soak'], ['--mode', 'all', '--mode', 'long'],
    ['--emulation', 'qemu-system'], ['--architecture', 'arm64'], ['--socket', '/tmp/remote.sock'],
    ['--origin', 'https://production.example'], ['--output', '/tmp/public.json'], ['--mode', 'long; echo unsafe']]) {
    assert.throws(() => parseNativeMemoryMode(args));
  }
});

test('native command refuses non-Linux, non-x64 process or mismatched kernel architecture before profiling', async () => {
  let called = false;
  for (const host of [
    { platform: 'darwin', arch: 'arm64', machine: 'arm64' },
    { platform: 'linux', arch: 'arm64', machine: 'aarch64' },
    { platform: 'linux', arch: 'x64', machine: 'aarch64' },
    { platform: 'darwin', arch: 'x64', machine: 'x86_64' },
    { platform: 'win32', arch: 'x64', machine: 'x86_64' },
  ]) {
    assert.throws(() => requireNativeAmd64(host));
    await assert.rejects(profileNativeAmd64('all', { host, profile: async () => { called = true; return true; } }));
  }
  assert.equal(called, false);
  assert.doesNotThrow(() => requireNativeAmd64(nativeHost));
});

test('native reports have new private-directory filenames and fixed local daemon and architecture settings', () => {
  const boundary = nativeMemoryOptions('boundary'), long = nativeMemoryOptions('long');
  for (const options of [boundary, long]) {
    assert.equal(options.socket, '/var/run/docker.sock');
    assert.equal(options.architecture, 'amd64'); assert.equal(options.emulation, 'none');
    assert.equal(options.docker, 'docker'); assert.equal(options.openssl, 'openssl');
    const expected = fileURLToPath(new URL('../local-artifacts/', import.meta.url));
    assert.equal(options.output.startsWith(expected), true);
    assert.match(options.output.slice(expected.length), new RegExp(`^native-amd64-${options.mode}-[a-f0-9]{16}\\.json$`));
  }
  assert.equal(boundary.scenarios.length, 9);
  assert.deepEqual(long.scenarios, ['upload-repeat-16mp', 'pdf-repeat-16mp']);
  assert.notEqual(boundary.output, nativeMemoryOptions('boundary').output);
});

test('both native modes run sequentially and long still runs after a failed or thrown boundary profile', async t => {
  t.mock.method(console, 'log', () => {}); t.mock.method(console, 'error', () => {});
  for (const first of ['passed', 'failed', 'throws'] as const) {
    const calls: LinuxOptions[] = []; let active = false;
    const passed = await profileNativeAmd64('all', { host: nativeHost, profile: async options => {
      assert.equal(active, false); active = true; calls.push(options);
      await new Promise<void>(resolve => setImmediate(resolve)); active = false;
      if (options.mode === 'boundary' && first === 'throws') throw new Error('private diagnostic');
      return options.mode !== 'boundary' || first === 'passed';
    } });
    assert.deepEqual(calls.map(options => options.mode), ['boundary', 'long']);
    assert.equal(passed, first === 'passed');
  }
});

test('selected mode runs alone and any long-session failure determines the aggregate result', async t => {
  t.mock.method(console, 'log', () => {});
  const calls: string[] = [];
  assert.equal(await profileNativeAmd64('long', { host: nativeHost, profile: async options => { calls.push(options.mode); return true; } }), true);
  assert.deepEqual(calls, ['long']);
  assert.equal(await profileNativeAmd64('all', { host: nativeHost, profile: async options => options.mode !== 'long' }), false);
  await assert.rejects(profileNativeAmd64('invalid' as 'all', { host: nativeHost, profile: async () => true }));
});

test('explicit cancellation stops new modes after the current profiler returns and removes its listeners', async t => {
  t.mock.method(console, 'log', () => {});
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    const previousListeners = process.listenerCount(signal), calls: string[] = [];
    const passed = await profileNativeAmd64('all', { host: nativeHost, profile: async options => {
      calls.push(options.mode); process.emit(signal); return true;
    } });
    assert.equal(passed, false); assert.deepEqual(calls, ['boundary']);
    assert.equal(process.listenerCount(signal), previousListeners);
  }
});

test('native wrapper never reads cloud, Docker context, report path or architecture overrides from environment', async t => {
  t.mock.method(console, 'log', () => {});
  const names = ['DOCKER_HOST', 'DOCKER_CONTEXT', 'SUPABASE_URL', 'DATABASE_URL', 'SAH_MEMORY_MODE', 'SAH_MEMORY_OUTPUT', 'SAH_MEMORY_ARCHITECTURE'];
  const previous = new Map(names.map(name => [name, process.env[name]]));
  for (const name of names) process.env[name] = 'https://not-a-local-endpoint.invalid';
  try {
    assert.equal(await profileNativeAmd64('boundary', { host: nativeHost, profile: async options => {
      assert.equal(options.socket, '/var/run/docker.sock'); assert.equal(options.architecture, 'amd64');
      assert.equal(options.mode, 'boundary'); assert.equal(JSON.stringify(options).includes('not-a-local-endpoint'), false);
      return true;
    } }), true);
  } finally {
    for (const [name, value] of previous) { if (value === undefined) delete process.env[name]; else process.env[name] = value; }
  }
});

test('manual workflow bounds resource usage and publishes only aggregate JSON without credentials', async () => {
  const workflow = await readFile(new URL('../../.github/workflows/native-memory.yml', import.meta.url), 'utf8');
  assert.match(workflow, /^on:\n  workflow_dispatch:/m);
  assert.doesNotMatch(workflow, /^\s+(?:push|pull_request|pull_request_target|schedule|workflow_run|workflow_call):/m);
  assert.match(workflow, /runs-on: ubuntu-24\.04/); assert.match(workflow, /timeout-minutes: 25/);
  assert.match(workflow, /permissions:\n  contents: read/); assert.match(workflow, /cancel-in-progress: false/);
  assert.match(workflow, /persist-credentials: false/); assert.doesNotMatch(workflow, /secrets\.|write-all|contents: write/);
  assert.deepEqual([...workflow.matchAll(/uses: ([^\s]+)/g)].map(match => match[1]), [
    'actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803',
    'actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38',
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
  ]);
  assert.match(workflow, /SAH_MEMORY_MODE: \$\{\{ inputs\.mode \}\}/);
  assert.match(workflow, /run: node tool\/profile-native-amd64\.ts --mode "\$SAH_MEMORY_MODE"/);
  assert.doesNotMatch(workflow, /run:.*\$\{\{/);
  assert.match(workflow, /if: always\(\)/); assert.match(workflow, /retention-days: 1/);
  assert.deepEqual([...workflow.matchAll(/^\s+path: (.+)$/gm)].map(match => match[1]), ['backend/local-artifacts/native-amd64-*.json']);
});
