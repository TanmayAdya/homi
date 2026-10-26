import { matchPrograms } from './matcher.ts';
import { demoContext, demoProgram } from '../fixtures/demo-program.ts';
import { readSharedScenarios } from './shared-fixtures.ts';

const scenarios = readSharedScenarios(process.argv[2]);
console.log(JSON.stringify(scenarios.map(scenario => ({
  scenario: scenario.id,
  result: matchPrograms(scenario.case, [demoProgram], demoContext),
})), null, 2));
