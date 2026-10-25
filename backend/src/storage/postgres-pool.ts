import { open } from 'node:fs/promises';
import { Pool, type PoolConfig } from 'pg';

export interface DatabaseConfiguration {
  connectionString: string;
  caCertificate?: string;
  allowInsecureLoopback?: boolean;
}

export class DatabaseConfigurationError extends Error {
  constructor() { super('Database configuration is invalid or insufficiently restricted.'); this.name = 'DatabaseConfigurationError'; }
}

export function postgresPoolOptions(config: DatabaseConfiguration): PoolConfig {
  try {
    if (typeof config.connectionString !== 'string' || config.connectionString.length > 8192
      || /[\s\u0000-\u001f\u007f]/.test(config.connectionString)) throw new Error();
    const url = new URL(config.connectionString);
    if (!['postgres:', 'postgresql:'].includes(url.protocol) || !url.hostname || !url.username || !url.password
      || !/^\/[^/]+$/.test(url.pathname) || url.search || url.hash
      || (url.port && (!/^\d+$/.test(url.port) || Number(url.port) < 1 || Number(url.port) > 65535))) throw new Error();
    for (const value of [url.username, url.password, url.pathname.slice(1)]) {
      if (/[\u0000-\u001f\u007f]/.test(decodeURIComponent(value))) throw new Error();
    }
    if (config.caCertificate !== undefined && (typeof config.caCertificate !== 'string'
      || Buffer.byteLength(config.caCertificate) > 128 * 1024
      || !config.caCertificate.includes('-----BEGIN CERTIFICATE-----')
      || config.caCertificate.includes('PRIVATE KEY'))) throw new Error();
    const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname.toLowerCase());
    if (config.allowInsecureLoopback === true && !loopback) throw new Error();
    return {
      connectionString: config.connectionString,
      ssl: config.allowInsecureLoopback === true ? false : {
        rejectUnauthorized: true, ...(config.caCertificate === undefined ? {} : { ca: config.caCertificate }),
      },
      max: 4, connectionTimeoutMillis: 5000, idleTimeoutMillis: 30_000,
      statement_timeout: 8000, lock_timeout: 3000, query_timeout: 10_000,
      idle_in_transaction_session_timeout: 10_000, maxLifetimeSeconds: 300, allowExitOnIdle: true,
      application_name: 'safe-at-home-api',
    };
  } catch { throw new DatabaseConfigurationError(); }
}

export function createPostgresPool(config: DatabaseConfiguration): Pool {
  const pool = new Pool(postgresPoolOptions(config));
  pool.on('error', () => {});
  return pool;
}

export async function databaseConfigurationFromEnvironment(
  env: NodeJS.ProcessEnv, purpose: 'runtime' | 'migration' = 'runtime',
): Promise<DatabaseConfiguration> {
  try {
    const connectionString = env[purpose === 'migration' ? 'SAFEATHOME_MIGRATION_DATABASE_URL' : 'SAFEATHOME_DATABASE_URL'];
    if (!connectionString || env.NODE_TLS_REJECT_UNAUTHORIZED === '0') throw new Error();
    const flag = env.SAFEATHOME_ALLOW_INSECURE_LOOPBACK_DATABASE;
    if (flag !== undefined && flag !== 'true' && flag !== 'false') throw new Error();
    if (flag === 'true' && env.NODE_ENV === 'production') throw new Error();
    let caCertificate: string | undefined = env.SAFEATHOME_DATABASE_CA_PEM || undefined;
    if (caCertificate && env.SAFEATHOME_DATABASE_CA_FILE) throw new Error();
    if (env.SAFEATHOME_DATABASE_CA_FILE) {
      const file = await open(env.SAFEATHOME_DATABASE_CA_FILE, 'r');
      try {
        const buffer = Buffer.alloc(128 * 1024 + 1);
        let size = 0;
        while (size < buffer.length) {
          const { bytesRead } = await file.read(buffer, size, buffer.length - size, size);
          if (bytesRead === 0) break;
          size += bytesRead;
        }
        if (size > 128 * 1024) throw new Error();
        caCertificate = new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, size));
      } finally { await file.close(); }
    }
    const config = { connectionString, caCertificate, allowInsecureLoopback: flag === 'true' };
    postgresPoolOptions(config);
    return config;
  } catch { throw new DatabaseConfigurationError(); }
}

export async function assertRestrictedRuntimeRole(pool: Pool): Promise<void> {
  try {
    const result = await pool.query(`SELECT
    pg_has_role(current_user, 'safeathome_app', 'member') AS application_member,
    EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role(current_user, r.oid, 'member')
      AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication
        OR left(r.rolname, 3) = 'pg_')) AS elevated,
    (EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname IN ('safeathome_private', 'safeathome_migrations', 'safeathome_recovery')
      AND pg_has_role(current_user, c.relowner, 'member'))
     OR EXISTS (SELECT 1 FROM pg_namespace n
       WHERE n.nspname IN ('safeathome_private', 'safeathome_migrations', 'safeathome_recovery')
       AND pg_has_role(current_user, n.nspowner, 'member'))
     OR EXISTS (SELECT 1 FROM pg_database d WHERE d.datname = current_database()
       AND pg_has_role(current_user, d.datdba, 'member'))) AS owns_data`);
    const row = result.rows[0];
    if (result.rowCount !== 1 || row.application_member !== true || row.elevated !== false || row.owns_data !== false) {
      throw new DatabaseConfigurationError();
    }
  } catch { throw new DatabaseConfigurationError(); }
}
