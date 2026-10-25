import { pathToFileURL } from 'node:url';
import { createMemoryWorkload, SCENARIOS, type Scenario } from './workload.ts';

export async function runMemoryWorker(scenario: Scenario, directory: string) {
  if (!SCENARIOS.includes(scenario)) throw new Error('Unknown memory scenario.');
  const startupRssBytes = process.memoryUsage().rss;
  const workload = await createMemoryWorkload(directory, scenario);
  const baselineRssBytes = process.memoryUsage().rss;
  const iterations = scenario === 'pdf-repeat-16mp' || scenario === 'upload-repeat-16mp' ? 3 : 1;
  const iterationRssBytes: number[] = [];
  const assertions: Record<string, boolean> = { workerCompleted: true };
  for (let index = 0; index < iterations; index++) {
    try {
      const checked = await workload.run();
      for (const [key, value] of Object.entries(checked)) assertions[key] = (assertions[key] ?? true) && value;
    } catch { assertions.workerCompleted = false; }
    iterationRssBytes.push(process.memoryUsage().rss);
  }
  const finalRssBytes = process.memoryUsage().rss;
  const maxRssKiB = process.resourceUsage().maxRSS;
  return { schemaVersion: '1' as const, scenario, status: Object.values(assertions).every(Boolean) ? 'passed' as const : 'failed' as const,
    iterations, memory: { startupRssBytes, baselineRssBytes, finalRssBytes, maxRssKiB, maxRssBytes: maxRssKiB * 1024,
      iterationRssBytes }, workload: workload.metrics, assertions };
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  if (process.argv.length !== 4 || !SCENARIOS.includes(process.argv[2] as Scenario)) {
    console.error('Synthetic memory worker failed.'); process.exitCode = 1;
  } else runMemoryWorker(process.argv[2] as Scenario, process.argv[3]).then(result => {
    console.log(JSON.stringify(result));
    if (result.status !== 'passed') process.exitCode = 1;
  }, () => { console.error('Synthetic memory worker failed.'); process.exitCode = 1; });
}
