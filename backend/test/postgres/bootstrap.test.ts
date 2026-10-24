import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import { inspect } from 'node:util';
import { Pool } from 'pg';
import { bootstrapRuntimeRole, RuntimeBootstrapError } from '../../src/storage/bootstrap-runtime.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { assertRestrictedRuntimeRole } from '../../src/storage/postgres-pool.ts';
import { TestPostgres } from './harness.ts';

const PASSWORD = 'Fictional-Local-Test!Password-32+Chars';

test('bootstrap creates a restricted login with a real SCRAM password and redacted result', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const admin = cluster.pool();
  await applyMigrations(admin);
  const result = await bootstrapRuntimeRole(admin, { password: PASSWORD });
  assert.equal(result.status, 'created');
  if (result.status !== 'created') throw new Error('Expected a newly created role.');
  assert.equal(result.password, PASSWORD);
  assert.equal(JSON.stringify(result).includes(PASSWORD), false);
  assert.equal(inspect(result, { showHidden: true }).includes(PASSWORD), false);
  assert.deepEqual(Object.keys(result), ['status', 'role']);
  assert.equal(Object.isFrozen(result), true);
  const stored = (await admin.query("SELECT rolpassword FROM pg_authid WHERE rolname='safeathome_runtime'")).rows[0].rolpassword;
  assert.match(stored, /^SCRAM-SHA-256\$32768:/);
  assert.equal(stored.includes(PASSWORD), false);
  const hba = join(cluster.dataPath, 'pg_hba.conf');
  await writeFile(hba, `local all safeathome_runtime scram-sha-256\n${await readFile(hba, 'utf8')}`);
  await cluster.restart();
  const runtime = new Pool({ host: cluster.socketPath, port: cluster.port, database: 'postgres',
    user: 'safeathome_runtime', password: result.password, max: 1, connectionTimeoutMillis: 3000 });
  const wrong = new Pool({ host: cluster.socketPath, port: cluster.port, database: 'postgres',
    user: 'safeathome_runtime', password: 'Different-Fictional-Password-32+Chars', max: 1, connectionTimeoutMillis: 3000 });
  try {
    await assertRestrictedRuntimeRole(runtime);
    await assert.rejects(wrong.query('SELECT 1'), { code: '28P01' });
    assert.deepEqual((await runtime.query('SELECT * FROM safeathome_private.cases')).rows, []);
    await assert.rejects(runtime.query('CREATE TABLE safeathome_private.unwanted(id int)'), { code: '42501' });
    await assert.rejects(runtime.query('CREATE ROLE unwanted'), { code: '42501' });
    await assert.rejects(runtime.query('UPDATE safeathome_migrations.versions SET checksum=checksum'), { code: '42501' });
  } finally { await Promise.all([runtime.end(), wrong.end()]); }
  assert.equal((await readFile(join(cluster.directory, 'postgres.log'), 'utf8')).includes(PASSWORD), false);
});

test('simultaneous bootstraps create one role and never rotate a supplied existing password', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const admin = cluster.pool(); await applyMigrations(admin);
  const results = await Promise.all([bootstrapRuntimeRole(admin, { password: PASSWORD }),
    bootstrapRuntimeRole(cluster.pool(), { password: PASSWORD })]);
  assert.deepEqual(results.map(result => result.status).sort(), ['created', 'exists_unchanged']);
  const before = (await admin.query("SELECT rolpassword FROM pg_authid WHERE rolname='safeathome_runtime'")).rows[0].rolpassword;
  const repeated = await bootstrapRuntimeRole(admin, { password: 'Different-Fictional-Password-32+Chars' });
  assert.deepEqual(repeated, { status: 'exists_unchanged', role: 'safeathome_runtime' });
  assert.equal('password' in repeated, false);
  assert.equal((await admin.query("SELECT rolpassword FROM pg_authid WHERE rolname='safeathome_runtime'")).rows[0].rolpassword, before);
});

test('generated credentials use 256 random bits and are omitted from ordinary serialization', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const admin = cluster.pool(); await applyMigrations(admin);
  const result = await bootstrapRuntimeRole(admin);
  assert.equal(result.status, 'created');
  if (result.status !== 'created') throw new Error('Expected a newly created role.');
  assert.match(result.password, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(Buffer.from(result.password, 'base64url').byteLength, 32);
  assert.equal(JSON.stringify(result).includes(result.password), false);
});

test('bootstrap needs current migrations and rejects the ordinary runtime principal', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const admin = cluster.pool();
  await assert.rejects(bootstrapRuntimeRole(admin, { password: PASSWORD }), RuntimeBootstrapError);
  assert.equal((await admin.query("SELECT 1 FROM pg_roles WHERE rolname='safeathome_runtime'")).rowCount, 0);
  await applyMigrations(admin);
  await admin.query("UPDATE safeathome_migrations.versions SET checksum='unexpected'");
  await assert.rejects(bootstrapRuntimeRole(admin), RuntimeBootstrapError);
  assert.equal((await admin.query("SELECT 1 FROM pg_roles WHERE rolname='safeathome_runtime'")).rowCount, 0);
});

test('runtime and unrelated CREATEROLE accounts cannot bootstrap or repair roles', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const admin = cluster.pool(); await applyMigrations(admin);
  await bootstrapRuntimeRole(admin, { password: PASSWORD });
  await assert.rejects(bootstrapRuntimeRole(cluster.pool('safeathome_runtime')), RuntimeBootstrapError);
  await admin.query('CREATE ROLE unrelated_admin LOGIN CREATEROLE');
  await admin.query('GRANT USAGE ON SCHEMA safeathome_migrations TO unrelated_admin; GRANT SELECT ON safeathome_migrations.versions TO unrelated_admin');
  await assert.rejects(bootstrapRuntimeRole(cluster.pool('unrelated_admin')), RuntimeBootstrapError);
});

test('unsafe existing roles are refused without modifying flags, memberships or password', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const admin = cluster.pool(); await applyMigrations(admin);
  await bootstrapRuntimeRole(admin, { password: PASSWORD });
  const before = (await admin.query("SELECT rolpassword FROM pg_authid WHERE rolname='safeathome_runtime'")).rows[0].rolpassword;
  const grants = [
    ['ALTER ROLE safeathome_runtime BYPASSRLS', 'ALTER ROLE safeathome_runtime NOBYPASSRLS'],
    ['GRANT pg_read_server_files TO safeathome_runtime', 'REVOKE pg_read_server_files FROM safeathome_runtime'],
    ['GRANT safeathome_app TO safeathome_runtime WITH ADMIN OPTION', 'REVOKE ADMIN OPTION FOR safeathome_app FROM safeathome_runtime'],
    ['ALTER SCHEMA safeathome_private OWNER TO safeathome_runtime', 'ALTER SCHEMA safeathome_private OWNER TO sah_test_admin'],
    ['ALTER DATABASE postgres OWNER TO safeathome_runtime', 'ALTER DATABASE postgres OWNER TO sah_test_admin'],
  ];
  for (const [change, restore] of grants) {
    await admin.query(change);
    await assert.rejects(bootstrapRuntimeRole(admin, { password: 'Different-Fictional-Password-32+Chars' }), RuntimeBootstrapError);
    assert.equal((await admin.query("SELECT rolpassword FROM pg_authid WHERE rolname='safeathome_runtime'")).rows[0].rolpassword, before);
    await admin.query(restore);
  }
  await assertRestrictedRuntimeRole(cluster.pool('safeathome_runtime'));
});

test('non-superuser migration owner can bootstrap using ordinary CREATEROLE privileges', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const admin = cluster.pool();
  await admin.query('CREATE ROLE migration_owner LOGIN CREATEROLE NOSUPERUSER NOBYPASSRLS');
  await admin.query('GRANT CREATE, CONNECT ON DATABASE postgres TO migration_owner WITH GRANT OPTION');
  const migration = cluster.pool('migration_owner');
  await applyMigrations(migration);
  const created = await bootstrapRuntimeRole(migration, { password: PASSWORD });
  assert.equal(created.status, 'created');
  await assertRestrictedRuntimeRole(cluster.pool('safeathome_runtime'));
  assert.equal((await bootstrapRuntimeRole(migration)).status, 'exists_unchanged');
});

test('failed role grants roll back creation and errors never retain driver secrets', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const admin = cluster.pool();
  await admin.query('CREATE ROLE migration_owner LOGIN CREATEROLE NOSUPERUSER NOBYPASSRLS');
  await admin.query('GRANT CREATE, CONNECT ON DATABASE postgres TO migration_owner WITH GRANT OPTION');
  const migration = cluster.pool('migration_owner'); await applyMigrations(migration);
  await admin.query('REVOKE ADMIN OPTION FOR safeathome_app FROM migration_owner');
  await assert.rejects(bootstrapRuntimeRole(migration, { password: PASSWORD }), RuntimeBootstrapError);
  assert.equal((await admin.query("SELECT 1 FROM pg_roles WHERE rolname='safeathome_runtime'")).rowCount, 0);
  const fake = { connect: async () => { throw new Error(`Database failure with ${PASSWORD}`); } } as unknown as Pool;
  await assert.rejects(bootstrapRuntimeRole(fake, { password: PASSWORD }), error => {
    assert.ok(error instanceof RuntimeBootstrapError);
    assert.equal(inspect(error).includes(PASSWORD), false);
    assert.equal('cause' in error, false);
    return true;
  });
});

test('invalid supplied secrets fail before database access', async () => {
  let connections = 0;
  const fake = { connect: async () => { connections++; throw new Error('Should not connect'); } } as unknown as Pool;
  for (const password of ['', 'short', 'x'.repeat(129), `${'x'.repeat(32)}\u0000`,
    `${'x'.repeat(32)}\n`, `${'x'.repeat(32)} `, 'é'.repeat(32)]) {
    await assert.rejects(bootstrapRuntimeRole(fake, { password }), RuntimeBootstrapError);
  }
  assert.equal(connections, 0);
});
