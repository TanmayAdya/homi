import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { CaseSnapshot, MatchResponse } from './types.ts';

export interface SharedScenario {
  id: string;
  case: CaseSnapshot;
  match: MatchResponse;
}

export function readSharedScenarios(pathOverride?: string): SharedScenario[] {
  const path = pathOverride ?? fileURLToPath(new URL('../../contracts/v1/fixtures/scenarios.json', import.meta.url));
  let scenarios: unknown;
  try {
    scenarios = JSON.parse(readFileSync(path, 'utf8'));
  } catch (cause) {
    throw new Error(`Cannot load shared fixtures at ${path}. After the baseline is merged, use the default; until then, pass the baseline fixture path after --.`, { cause });
  }
  if (!Array.isArray(scenarios) || scenarios.length === 0 || !scenarios.every(scenario => scenario && typeof scenario.id === 'string' && scenario.case && scenario.match)) {
    throw new Error('Shared fixtures must be a nonempty scenario array with id, case, and match.');
  }
  return scenarios as SharedScenario[];
}
