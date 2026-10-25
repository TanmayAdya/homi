import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { access, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import { promisify } from 'node:util';
import { TestPostgres } from './harness.ts';

const execute = promisify(execFile);

test('disposable PostgreSQL uses only private local sockets and removes its owned files', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  assert.equal((await stat(cluster.directory)).mode & 0o777, 0o700);
  assert.equal((await stat(cluster.socketPath)).mode & 0o777, 0o700);
  const row = (await cluster.pool().query(`SELECT
    current_setting('listen_addresses') AS listen_addresses,
    current_setting('unix_socket_permissions') AS socket_permissions,
    inet_server_addr() IS NULL AS local_connection`)).rows[0];
  assert.deepEqual(row, { listen_addresses: '', socket_permissions: '0700', local_connection: true });
  await cluster.close();
  await assert.rejects(access(cluster.directory), { code: 'ENOENT' });
  await cluster.close();
  assert.throws(() => cluster.pool(), /not running/);
});

test('an idle connection shutdown stays handled and an already-stopped cluster is removed', async t => {
  const cluster = await TestPostgres.start(); t.after(() => cluster.close());
  const pool = cluster.pool();
  await pool.query('SELECT 1');
  assert.ok(pool.listenerCount('error') >= 1);
  let idleDisconnects = 0;
  pool.on('error', () => { idleDisconnects++; });
  await execute(join(cluster.bin, 'pg_ctl'), ['-D', cluster.dataPath, '-m', 'fast', '-w', '-t', '20', 'stop'], {
    timeout: 30000, maxBuffer: 512 * 1024, env: { PATH: process.env.PATH ?? '', LC_ALL: 'C' },
  });
  assert.equal(idleDisconnects, 1);
  await cluster.close();
  await assert.rejects(access(cluster.directory), { code: 'ENOENT' });
});
