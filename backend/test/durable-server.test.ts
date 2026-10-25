import assert from 'node:assert/strict';
import test from 'node:test';
import type { Pool } from 'pg';
import { durableHttpConfiguration, createDurableServer } from '../src/api/durable-server.ts';
import { applyMigrations, MigrationError } from '../src/storage/migrate.ts';

const env = { SAFEATHOME_SUPABASE_URL: 'https://fictional.example.test',
  SAFEATHOME_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fictional' };

test('durable startup requires explicit auth and a bounded port before database I/O', () => {
  assert.equal(durableHttpConfiguration(env).port, 8788);
  assert.equal(durableHttpConfiguration(env).host, '127.0.0.1');
  assert.equal(durableHttpConfiguration({ ...env, SAFEATHOME_PORT: '65535' }).port, 65535);
  assert.equal(durableHttpConfiguration({ ...env, PORT: '3000', SAFEATHOME_PORT: '8788' }).port, 3000);
  for (const value of ['0', '-1', '65536', ' 8788', '8788\n', '08', '1.2', '']) {
    assert.throws(() => durableHttpConfiguration({ ...env, SAFEATHOME_PORT: value }));
    assert.throws(() => durableHttpConfiguration({ ...env, PORT: value }));
  }
  assert.throws(() => durableHttpConfiguration({}));
  assert.throws(() => durableHttpConfiguration({ ...env, SAFEATHOME_SUPABASE_URL: 'http://fictional.example.test' }));
});

test('remote binding is explicit and limited to the supported proxy interface', () => {
  assert.equal(durableHttpConfiguration({ ...env, SAFEATHOME_HOST: '0.0.0.0' }).host, '0.0.0.0');
  for (const value of ['', 'localhost', '0.0.0.0 ', 'external.example.test', '::', '127.0.0.2']) {
    assert.throws(() => durableHttpConfiguration({ ...env, SAFEATHOME_HOST: value }));
  }
});

test('invalid authentication cannot open a database connection or create a listener', async () => {
  let calls = 0;
  const pool = { async query() { calls++; }, async connect() { calls++; } } as unknown as Pool;
  await assert.rejects(createDurableServer({ pool, auth: { projectUrl: '', publishableKey: '' } }));
  assert.equal(calls, 0);
});

test('migration connection failures do not leak database credentials through public errors', async () => {
  const pool = { async connect() { throw new Error('fictional-password-and-database-host'); } } as unknown as Pool;
  await assert.rejects(applyMigrations(pool), error => {
    assert.ok(error instanceof MigrationError);
    assert.equal(error.cause, undefined);
    assert.equal(String(error.stack).includes('fictional-password'), false);
    return true;
  });
});
