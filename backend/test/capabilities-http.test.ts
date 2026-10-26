import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import test from 'node:test';
import { createMatchingServer } from '../src/api/http-server.ts';
import { MemoryCaseRepository } from '../src/api/memory-case-repository.ts';

test('capabilities are authenticated, bounded, versioned, and derived from installed routes', async t => {
  const cases = new MemoryCaseRepository([]);
  const deps = { cases, loadRegistry: async () => [], now: () => new Date(),
    authenticate: async (token: string) => token === 'fictional' ? { userId: 'fictional-user' } : null };
  for (const enabled of [false, true]) {
    const server = createMatchingServer(deps, undefined, undefined, undefined, undefined, undefined,
      { hosted: true, ...(enabled ? { progressDependencies: deps, homeSafetyDependencies: deps } : {}) });
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => { server.closeAllConnections(); server.close(); });
    const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/capabilities`;
    const post = (body: unknown, token='fictional') => fetch(url, { method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    assert.equal((await post({schemaVersion:'1'},'expired')).status,401);
    assert.equal((await post({schemaVersion:'2'})).status,400);
    assert.equal((await post({schemaVersion:'1', extra:true})).status,400);
    assert.equal((await post({schemaVersion:'1', extra:'x'.repeat(17000)})).status,413);
    const result = await post({schemaVersion:'1'});
    assert.equal(result.status,200);
    assert.equal(result.headers.get('cache-control'),'no-store');
    assert.deepEqual(await result.json(), {schemaVersion:'1',features:{structuredRooms:enabled,tracking:enabled,
      scanSync:false,permissionSharing:false,sensitiveSharing:false,simpleInvitations:false}});
  }
});
