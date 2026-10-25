import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import type { Pool } from 'pg';
import {
  assertRestrictedRuntimeRole,
  createPostgresPool,
  databaseConfigurationFromEnvironment,
  DatabaseConfigurationError,
  postgresPoolOptions,
} from '../src/storage/postgres-pool.ts';

const password = 'fictional-secret-password';
const remote = `postgresql://fictional_runtime:${password}@database.example.test:5432/safeathome`;
const migration = `postgresql://fictional_migrator:${password}@database.example.test:5432/safeathome`;
const certificate = '-----BEGIN CERTIFICATE-----\nZmljdGlvbmFs\n-----END CERTIFICATE-----\n';
const safeError = (error: unknown): boolean => {
  assert.ok(error instanceof DatabaseConfigurationError);
  assert.equal(error.message, 'Database configuration is invalid or insufficiently restricted.');
  assert.equal(error.cause, undefined);
  assert.equal(`${error.stack} ${JSON.stringify(error)}`.includes(password), false);
  assert.equal(`${error.stack} ${JSON.stringify(error)}`.includes(remote), false);
  return true;
};

test('remote pool options verify TLS, preserve a supplied CA, and bound resource/deadline settings', () => {
  const options = postgresPoolOptions({ connectionString: remote, caCertificate: certificate });
  assert.equal(options.connectionString, remote);
  assert.deepEqual(options.ssl, { rejectUnauthorized: true, ca: certificate });
  assert.equal(options.max, 4);
  assert.equal(options.connectionTimeoutMillis, 5000);
  assert.equal(options.idleTimeoutMillis, 30_000);
  assert.equal(options.statement_timeout, 8000);
  assert.equal(options.lock_timeout, 3000);
  assert.equal(options.query_timeout, 10_000);
  assert.equal(options.idle_in_transaction_session_timeout, 10_000);
  assert.equal(options.maxLifetimeSeconds, 300);
  assert.equal(options.application_name, 'safe-at-home-api');
  assert.equal(options.allowExitOnIdle, true);
  assert.deepEqual(postgresPoolOptions({ connectionString: remote }).ssl, { rejectUnauthorized: true });
});

test('URL options cannot disable TLS, replace a CA, choose a socket, or inject session options', () => {
  for (const suffix of ['?sslmode=disable', '?sslmode=no-verify', '?sslmode=require',
    '?sslrootcert=other.pem', '?sslcert=client.pem', '?sslkey=private.pem', '?ssl=false',
    '?options=-c%20role%3Dpostgres', '?host=%2Ftmp', '?application_name=other', '#private-fragment']) {
    assert.throws(() => postgresPoolOptions({ connectionString: `${remote}${suffix}`, caCertificate: certificate }), safeError);
  }
});

test('connection grammar and encoded control characters fail without credential disclosure', () => {
  const invalid = [
    '', 'not-a-connection-string', remote.replace('postgresql:', 'https:'),
    remote.replace(`:${password}@`, '@'), remote.replace('fictional_runtime', ''),
    remote.replace('/safeathome', '/nested/name'), remote.replace('/safeathome', '/'),
    remote.replace(':5432', ':65536'), remote.replace(':5432', ':0'),
    remote.replace('fictional_runtime', 'fictional%0Aruntime'),
    remote.replace(password, 'fictional%00password'), remote.replace('/safeathome', '/safe%7Fathome'),
    remote.replace(password, '%invalid'), `${remote}\n`, `${remote} `,
    `${remote}${'x'.repeat(8192)}`,
  ];
  for (const connectionString of invalid) assert.throws(() => postgresPoolOptions({ connectionString }), safeError);
});

test('plaintext requires an explicit loopback exception and never silently applies to a remote host', () => {
  for (const host of ['localhost', '127.0.0.1', '[::1]']) {
    const connectionString = `postgres://fictional:${password}@${host}:5432/safeathome`;
    assert.equal(postgresPoolOptions({ connectionString, allowInsecureLoopback: true }).ssl, false);
    assert.deepEqual(postgresPoolOptions({ connectionString }).ssl, { rejectUnauthorized: true });
  }
  for (const host of ['database.example.test', 'localhost.example.test', '127.0.0.2', '10.0.2.2']) {
    assert.throws(() => postgresPoolOptions({
      connectionString: `postgres://fictional:${password}@${host}/safeathome`, allowInsecureLoopback: true,
    }), safeError);
  }
});

test('environment loader requires the dedicated connection, rejects global TLS bypass and production plaintext', async () => {
  assert.equal((await databaseConfigurationFromEnvironment({ SAFEATHOME_DATABASE_URL: remote })).connectionString, remote);
  assert.equal((await databaseConfigurationFromEnvironment({
    SAFEATHOME_DATABASE_URL: remote, SAFEATHOME_MIGRATION_DATABASE_URL: migration,
  }, 'migration')).connectionString, migration);
  for (const env of [
    {}, { SAFEATHOME_DATABASE_URL: remote, NODE_TLS_REJECT_UNAUTHORIZED: '0' },
    { SAFEATHOME_DATABASE_URL: remote, SAFEATHOME_ALLOW_INSECURE_LOOPBACK_DATABASE: '1' },
    { SAFEATHOME_DATABASE_URL: remote, SAFEATHOME_ALLOW_INSECURE_LOOPBACK_DATABASE: 'TRUE' },
    { SAFEATHOME_DATABASE_URL: remote, SAFEATHOME_ALLOW_INSECURE_LOOPBACK_DATABASE: 'true' },
    { SAFEATHOME_DATABASE_URL: `postgres://fictional:${password}@localhost/safeathome`,
      SAFEATHOME_ALLOW_INSECURE_LOOPBACK_DATABASE: 'true', NODE_ENV: 'production' },
  ]) await assert.rejects(databaseConfigurationFromEnvironment(env), safeError);
  await assert.rejects(databaseConfigurationFromEnvironment({ SAFEATHOME_DATABASE_URL: remote }, 'migration'), safeError);
  const local = await databaseConfigurationFromEnvironment({
    SAFEATHOME_DATABASE_URL: `postgres://fictional:${password}@localhost/safeathome`,
    SAFEATHOME_ALLOW_INSECURE_LOOPBACK_DATABASE: 'true', NODE_ENV: 'test',
  });
  assert.equal(postgresPoolOptions(local).ssl, false);
});

test('certificate input is bounded and refuses private-key material with safe configuration errors', () => {
  for (const caCertificate of ['', 'not a certificate', `${certificate}-----BEGIN PRIVATE KEY-----\n${password}`,
    `${certificate}${'x'.repeat(128 * 1024)}`]) {
    assert.throws(() => postgresPoolOptions({ connectionString: remote, caCertificate }), safeError);
  }
});

test('optional public CA environment input retains verified TLS and refuses competing trust sources', async () => {
  const env = { SAFEATHOME_DATABASE_URL: remote, SAFEATHOME_DATABASE_CA_PEM: certificate };
  const config = await databaseConfigurationFromEnvironment(env);
  assert.deepEqual(postgresPoolOptions(config).ssl, { rejectUnauthorized: true, ca: certificate });
  assert.deepEqual(postgresPoolOptions(await databaseConfigurationFromEnvironment({
    SAFEATHOME_DATABASE_URL: remote, SAFEATHOME_DATABASE_CA_PEM: '',
  })).ssl, { rejectUnauthorized: true });
  await assert.rejects(databaseConfigurationFromEnvironment({ ...env, SAFEATHOME_DATABASE_CA_FILE: '/not-read.pem' }), safeError);
  for (const ca of ['not a CA', `${certificate}-----BEGIN PRIVATE KEY-----`, 'x'.repeat(128 * 1024 + 1)]) {
    await assert.rejects(databaseConfigurationFromEnvironment({ ...env, SAFEATHOME_DATABASE_CA_PEM: ca }), safeError);
  }
});

test('CA-file loader reads bounded strict UTF-8 and never exposes file contents or paths in errors', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'safeathome-pool-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const caPath = join(directory, 'fictional-ca.pem');
  const env = { SAFEATHOME_DATABASE_URL: remote, SAFEATHOME_DATABASE_CA_FILE: caPath };
  await writeFile(caPath, certificate, { mode: 0o600 });
  const loaded = await databaseConfigurationFromEnvironment(env);
  assert.equal(loaded.caCertificate, certificate);
  const oversized = Buffer.alloc(128 * 1024 + 1, 0x20);
  oversized.write(certificate);
  for (const content of [oversized, Buffer.from([0xc3, 0x28]),
    Buffer.from(`${certificate}-----BEGIN PRIVATE KEY-----\n${password}`), Buffer.from('not a certificate')]) {
    await writeFile(caPath, content);
    await assert.rejects(databaseConfigurationFromEnvironment(env), error => {
      safeError(error);
      assert.equal(String(error).includes(caPath), false);
      return true;
    });
  }
  await assert.rejects(databaseConfigurationFromEnvironment({ ...env, SAFEATHOME_DATABASE_CA_FILE: join(directory, 'missing.pem') }), safeError);
});

test('pool creation is lazy and handles idle error events without raw diagnostic logging', async () => {
  const pool = createPostgresPool({ connectionString: remote });
  try {
    assert.equal(pool.totalCount, 0);
    assert.equal(pool.listenerCount('error'), 1);
    assert.doesNotThrow(() => pool.emit('error', new Error(`provider diagnostic: ${password}`)));
    assert.equal(pool.totalCount, 0);
  } finally { await pool.end(); }
});

test('runtime role gate requires normal membership and rejects elevated or data-owning roles', async () => {
  const valid = { application_member: true, elevated: false, owns_data: false };
  const poolFor = (row: Record<string, unknown>, rowCount = 1) => ({
    async query(sql: string) {
      assert.match(sql, /pg_has_role/);
      return { rowCount, rows: [row] };
    },
  } as unknown as Pool);
  await assertRestrictedRuntimeRole(poolFor(valid));
  for (const row of [{ ...valid, application_member: false }, { ...valid, elevated: true },
    { ...valid, owns_data: true }, { ...valid, elevated: 'false' }]) {
    await assert.rejects(assertRestrictedRuntimeRole(poolFor(row)), safeError);
  }
  await assert.rejects(assertRestrictedRuntimeRole(poolFor(valid, 0)), safeError);
});

test('runtime role-query failures expose a sanitized startup error', async () => {
  const pool = { async query() { throw new Error(`provider diagnostic: ${remote}`); } } as unknown as Pool;
  await assert.rejects(assertRestrictedRuntimeRole(pool), safeError);
});
