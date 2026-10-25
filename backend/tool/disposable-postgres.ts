import { execFile } from 'node:child_process';
import { constants } from 'node:fs';
import { access, appendFile, chmod, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { randomInt } from 'node:crypto';
import { delimiter, join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { Pool } from 'pg';

const execute = promisify(execFile);
const TOOLS = ['initdb', 'pg_ctl', 'postgres'] as const;

function confirmsStopped(error: unknown): boolean {
  return error instanceof Error && 'code' in error && error.code === 3;
}

async function findTools(configured?: string): Promise<string> {
  const candidates = configured ? [resolve(configured)] : (process.env.PATH ?? '').split(delimiter).filter(Boolean);
  for (const directory of candidates) {
    try { await Promise.all(TOOLS.map(name => access(join(directory, name), constants.X_OK))); return directory; }
    catch {   }
  }
  throw new Error('Native PostgreSQL requires trusted local initdb, pg_ctl and postgres executables. Configure their directory explicitly. Nothing is downloaded.');
}

export class DisposablePostgres {
  private readonly pools = new Set<Pool>();
  private running = false;
  private closed = false;
  readonly directory: string;
  readonly bin: string;
  readonly port: number;
  private constructor(directory: string, bin: string, port: number) {
    this.directory = directory; this.bin = bin; this.port = port;
  }

  static async start(binDirectory = process.env.SAFEATHOME_TEST_PG_BIN): Promise<DisposablePostgres> {
    if (process.platform === 'win32') throw new Error('This integration harness requires Unix-domain sockets.');
    const bin = await findTools(binDirectory);
    const directory = await mkdtemp('/tmp/sah-pg-');
    await chmod(directory, 0o700);
    const cluster = new DisposablePostgres(directory, bin, randomInt(20000, 60000));
    try {
      await mkdir(cluster.socketPath, { mode: 0o700 });
      await cluster.command('initdb', ['-D', cluster.dataPath, '-U', 'sah_test_admin',
        '--auth-local=trust', '--auth-host=reject', '--encoding=UTF8', '--locale=C']);
      await appendFile(join(cluster.dataPath, 'postgresql.conf'), [
        '', "listen_addresses = ''", `unix_socket_directories = '${cluster.socketPath}'`,
        'unix_socket_permissions = 0700', `port = ${cluster.port}`,
        'fsync = on', 'full_page_writes = on', 'synchronous_commit = on',
        "log_statement = 'none'", "log_min_messages = 'panic'",
        "log_min_error_statement = 'panic'", '',
      ].join('\n'));
      await cluster.start();
      return cluster;
    } catch (error) { await cluster.close(); throw error; }
  }

  get dataPath() { return join(this.directory, 'data'); }
  get socketPath() { return join(this.directory, 'socket'); }

  pool(user = 'sah_test_admin', applicationName = 'safeathome-postgres-test'): Pool {
    if (this.closed || !this.running) throw new Error('Test PostgreSQL is not running.');
    const pool = new Pool({ host: this.socketPath, port: this.port, database: 'postgres', user,
      max: 8, connectionTimeoutMillis: 3000, statement_timeout: 10000, query_timeout: 12000,
      application_name: applicationName });
    pool.on('error', () => {});
    this.pools.add(pool);
    return pool;
  }

  async start(): Promise<void> {
    if (this.closed) throw new Error('Test PostgreSQL is already closed.');
    if (this.running) return;
    try {
      await this.command('pg_ctl', ['-D', this.dataPath, '-l', join(this.directory, 'postgres.log'), '-w', '-t', '20', 'start']);
      this.running = true;
    } catch (error) {
      try { await this.command('pg_ctl', ['-D', this.dataPath, 'status']); this.running = true; }
      catch (statusError) { this.running = !confirmsStopped(statusError); }
      throw error;
    }
  }

  async stop(): Promise<void> {
    await this.closePools();
    if (!this.running) return;
    try { await this.command('pg_ctl', ['-D', this.dataPath, '-m', 'fast', '-w', '-t', '20', 'stop']); }
    catch (error) {
      let stopped = false;
      try { await this.command('pg_ctl', ['-D', this.dataPath, 'status']); }
      catch (statusError) { stopped = confirmsStopped(statusError); }
      if (!stopped) throw error;
    }
    this.running = false;
  }

  async restart(): Promise<void> { await this.stop(); await this.start(); }

  async close(): Promise<void> {
    if (this.closed) return;
    await this.stop();
    await rm(this.directory, { recursive: true, force: true });
    this.closed = true;
  }

  private async closePools() {
    const pools = [...this.pools]; this.pools.clear();
    await Promise.all(pools.map(pool => pool.end()));
  }

  private async command(tool: typeof TOOLS[number], args: string[]) {
    await execute(join(this.bin, tool), args, { timeout: 30000, maxBuffer: 512 * 1024,
      env: { PATH: process.env.PATH ?? '', LC_ALL: 'C' } });
  }
}
