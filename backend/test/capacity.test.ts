import test from 'node:test';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';
import { caseCapacity, packetCapacity, evidenceCapacity, exportCapacity } from './capacity-fixtures.ts';

for (const [name, exercise] of Object.entries({ caseCapacity, packetCapacity, evidenceCapacity, exportCapacity })) {
  test(`memory ${name} preserves retries, ownership and atomic final slots`, async () => {
    const repository = new MemoryCaseRepository([]);
    await exercise(repository, repository);
  });
}
