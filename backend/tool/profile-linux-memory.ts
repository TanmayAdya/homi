import { parseLinuxOptions, profileLinux } from './linux-memory/container-harness.ts';

try {
  if (!await profileLinux(parseLinuxOptions(process.argv.slice(2)))) process.exitCode = 1;
} catch (error) {
  console.error(error instanceof Error ? error.message : 'Linux memory profile failed.');
  process.exitCode = 1;
}
