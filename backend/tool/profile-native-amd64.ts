import { randomBytes } from 'node:crypto';
import { machine } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseLinuxOptions, profileLinux, type LinuxOptions } from './linux-memory/container-harness.ts';

export type NativeMemoryMode = 'boundary' | 'long' | 'all';
interface NativeHost { platform: string; arch: string; machine: string }
const BACKEND = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function parseNativeMemoryMode(args: string[]): NativeMemoryMode {
  if (args.length === 0) return 'all';
  if (args.length !== 2 || args[0] !== '--mode' || !['boundary', 'long', 'all'].includes(args[1])) {
    throw new Error('Use no arguments or --mode boundary|long|all. Host, socket and emulation overrides are unavailable.');
  }
  return args[1] as NativeMemoryMode;
}

export function requireNativeAmd64(host: NativeHost = { platform: process.platform, arch: process.arch, machine: machine() }): void {
  if (host.platform !== 'linux' || host.arch !== 'x64' || host.machine !== 'x86_64') {
    throw new Error('Native AMD64 profiling requires a Linux x86-64 host and process. This host is unsupported.');
  }
}

export function nativeMemoryOptions(mode: Exclude<NativeMemoryMode, 'all'>): LinuxOptions {
  if (mode !== 'boundary' && mode !== 'long') throw new Error('Invalid native profile mode.');
  const output = join(BACKEND, 'local-artifacts', `native-amd64-${mode}-${randomBytes(8).toString('hex')}.json`);
  return parseLinuxOptions(['--socket', '/var/run/docker.sock', '--architecture', 'amd64', '--emulation', 'none',
    '--mode', mode, '--output', output]);
}

export interface NativeMemoryTestSeams {
  host?: NativeHost;
  profile?: (options: LinuxOptions) => Promise<boolean>;
}

export async function profileNativeAmd64(mode: NativeMemoryMode, seams: NativeMemoryTestSeams = {}): Promise<boolean> {
  if (!['boundary', 'long', 'all'].includes(mode)) throw new Error('Invalid native profile mode.');
  requireNativeAmd64(seams.host);
  const profile = seams.profile ?? profileLinux;
  const modes: Exclude<NativeMemoryMode, 'all'>[] = mode === 'all' ? ['boundary', 'long'] : [mode];
  let passed = true, interrupted = false;
  const cancel = () => { interrupted = true; };
  process.on('SIGINT', cancel); process.on('SIGTERM', cancel);
  try {
    for (const current of modes) {
      if (interrupted) break;
      const options = nativeMemoryOptions(current);
      try {
        const result = await profile(options);
        if (!result) passed = false;
        console.log(JSON.stringify({ kind: 'native-amd64-profile-result', mode: current,
          status: result ? 'passed' : 'failed', report: options.output }));
      } catch {
        passed = false;
        console.error(`Native AMD64 ${current} profiling failed before completion.`);
      }
    }
  } finally {
    process.off('SIGINT', cancel); process.off('SIGTERM', cancel);
  }
  return passed && !interrupted;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    if (!await profileNativeAmd64(parseNativeMemoryMode(process.argv.slice(2)))) process.exitCode = 1;
  } catch (error) {
    console.error(error instanceof Error ? error.message : 'Native AMD64 profiling failed.');
    process.exitCode = 1;
  }
}
