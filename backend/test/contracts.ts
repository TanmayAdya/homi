import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { matchPrograms } from '../src/matcher.ts';
import { planDraftPacket } from '../src/packets.ts';
import { readSharedScenarios } from '../src/shared-fixtures.ts';
import type { DraftPacket, MatchResponse } from '../src/types.ts';
import { demoProgram } from '../fixtures/demo-program.ts';

function semanticResponse(response: MatchResponse) {
  return {
    ...response,
    matches: response.matches.map(match => ({
      ...match,
      checks: match.checks.map(({ reasonCode, explanation, ...check }) => {
        assert.ok(reasonCode.trim(), 'Every check needs a reason code.');
        assert.ok(explanation.trim(), 'Every check needs an explanation.');
        return check;
      }),
    })),
  };
}

function semanticPacket(packet: DraftPacket) {
  return { ...packet, missingItems: packet.missingItems.map(({ description, ...item }) => {
    assert.ok(description.trim(), 'Every missing item needs an actionable description.');
    return item;
  }) };
}

const scenarioPath = process.argv[2] ?? fileURLToPath(new URL('../../contracts/v1/fixtures/scenarios.json', import.meta.url));
const scenarios = readSharedScenarios(scenarioPath);
const packetFixtures = JSON.parse(readFileSync(join(dirname(scenarioPath), 'packets.json'), 'utf8')) as { scenarioId: string; packet: DraftPacket }[];
assert.ok(Array.isArray(packetFixtures), 'Packet fixtures must be an array.');
assert.deepEqual(packetFixtures.map(fixture => fixture.scenarioId).sort(), scenarios.map(scenario => scenario.id).sort(), 'Each shared scenario needs exactly one packet fixture.');
for (const scenario of scenarios) {
  const response = matchPrograms(scenario.case, [demoProgram], {
    evaluatedAt: scenario.match.evaluatedAt, evaluationDate: scenario.match.evaluationDate,
  });
  assert.deepEqual(semanticResponse(response), semanticResponse(scenario.match), `Shared scenario ${scenario.id} disagrees with the matcher.`);
  const expectedPacket = packetFixtures.find(fixture => fixture.scenarioId === scenario.id)!.packet;
  const draft = planDraftPacket(scenario.case, response.matches[0], {
    packetId: expectedPacket.packetId, generatedAt: response.evaluatedAt,
  });
  assert.deepEqual(semanticPacket(draft), semanticPacket(expectedPacket), `Shared packet ${scenario.id} disagrees with the planner.`);
  console.log(`Verified shared scenario: ${scenario.id}`);
}
console.log(`All ${scenarios.length} shared matching and packet contract scenarios agree.`);
