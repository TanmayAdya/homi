import { createHash, createHmac, pbkdf2, randomBytes } from 'node:crypto';
import { inspect, promisify } from 'node:util';
import type { Pool, PoolClient } from 'pg';
import { assertMigrationsCurrent } from './migrate.ts';

export const RUNTIME_DATABASE_ROLE = 'safeathome_runtime' as const;
export type RuntimeBootstrapResult =
  | { readonly status: 'created'; readonly role: typeof RUNTIME_DATABASE_ROLE; readonly password: string }
  | { readonly status: 'exists_unchanged'; readonly role: typeof RUNTIME_DATABASE_ROLE };

export class RuntimeBootstrapError extends Error {
  constructor() {
    super('Runtime database role bootstrap failed. Check migrations, administrative privileges and the existing role.');
    this.name = 'RuntimeBootstrapError';
  }
}

const deriveKey = promisify(pbkdf2);

function passwordInput(options: { password?: string }): string | undefined {
  if (!options || typeof options !== 'object' || Array.isArray(options)
    || Object.keys(options).some(key => key !== 'password')) throw new RuntimeBootstrapError();
  const password = options.password;
  if (password !== undefined && (typeof password !== 'string' || password.length < 32
    || password.length > 128 || /[^\x21-\x7e]/.test(password))) {
    throw new RuntimeBootstrapError();
  }
  return password;
}

async function scramSecret(password: string): Promise<string> {
  const salt = randomBytes(16);
  const iterations = 32768;
  const salted = await deriveKey(password, salt, iterations, 32, 'sha256');
  const clientKey = createHmac('sha256', salted).update('Client Key').digest();
  const storedKey = createHash('sha256').update(clientKey).digest('base64');
  const serverKey = createHmac('sha256', salted).update('Server Key').digest('base64');
  salted.fill(0); clientKey.fill(0);
  return `SCRAM-SHA-256$${iterations}:${salt.toString('base64')}$${storedKey}:${serverKey}`;
}

function createdResult(password: string): RuntimeBootstrapResult {
  const result = { status: 'created' as const, role: RUNTIME_DATABASE_ROLE };
  Object.defineProperty(result, 'password', { value: password, enumerable: false });
  Object.defineProperty(result, inspect.custom, { value: () => ({ ...result, password: '[REDACTED]' }) });
  return Object.freeze(result) as RuntimeBootstrapResult;
}

async function assertSafeExistingRole(client: PoolClient): Promise<void> {
  const result = await client.query(`SELECT r.rolcanlogin AND r.rolinherit AS login_inherits,
    pg_has_role(r.oid, 'safeathome_app', 'usage') AS application_member,
    EXISTS (SELECT 1 FROM pg_roles inherited WHERE pg_has_role(r.oid, inherited.oid, 'member')
      AND (inherited.rolsuper OR inherited.rolbypassrls OR inherited.rolcreaterole
        OR inherited.rolcreatedb OR inherited.rolreplication OR left(inherited.rolname,3)='pg_'
        OR inherited.rolname NOT IN ('safeathome_runtime','safeathome_app'))) AS elevated,
    EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member=r.oid AND m.admin_option) AS can_grant,
    (EXISTS (SELECT 1 FROM pg_class c WHERE pg_has_role(r.oid,c.relowner,'member'))
      OR EXISTS (SELECT 1 FROM pg_namespace n WHERE pg_has_role(r.oid,n.nspowner,'member'))
      OR EXISTS (SELECT 1 FROM pg_database d WHERE pg_has_role(r.oid,d.datdba,'member'))) AS owns_data,
    has_database_privilege(r.oid,current_database(),'CONNECT') AS can_connect
    FROM pg_roles r WHERE r.rolname=$1`, [RUNTIME_DATABASE_ROLE]);
  const row = result.rows[0];
  if (result.rowCount !== 1 || row.login_inherits !== true || row.application_member !== true
    || row.elevated !== false || row.can_grant !== false || row.owns_data !== false || row.can_connect !== true) {
    throw new RuntimeBootstrapError();
  }
}

export async function bootstrapRuntimeRole(
  migrationPool: Pool, options: { password?: string } = {},
): Promise<RuntimeBootstrapResult> {
  let client: PoolClient | undefined;
  let discard = false;
  try {
    const suppliedPassword = passwordInput(options);
    client = await migrationPool.connect();
    await client.query('BEGIN');
    await client.query("SET LOCAL lock_timeout='3s'; SET LOCAL statement_timeout='8s'");
    await client.query('SELECT pg_advisory_xact_lock(1935763045,1)');
    await assertMigrationsCurrent(client);
    const owner = await client.query(`SELECT (r.rolsuper OR r.rolcreaterole) AS can_create_roles,
      (SELECT count(*)=2 FROM pg_namespace n
        WHERE n.nspname IN ('safeathome_private','safeathome_migrations') AND n.nspowner=r.oid) AS owns_schemas
      FROM pg_roles r WHERE r.rolname=current_user AND r.rolname<>$1`, [RUNTIME_DATABASE_ROLE]);
    if (owner.rowCount !== 1 || owner.rows[0].can_create_roles !== true || owner.rows[0].owns_schemas !== true) {
      throw new RuntimeBootstrapError();
    }
    const existing = await client.query('SELECT 1 FROM pg_roles WHERE rolname=$1', [RUNTIME_DATABASE_ROLE]);
    if (existing.rowCount !== 0) {
      await assertSafeExistingRole(client);
      await client.query('COMMIT');
      return Object.freeze({ status: 'exists_unchanged', role: RUNTIME_DATABASE_ROLE });
    }
    const password = suppliedPassword ?? randomBytes(32).toString('base64url');
    const secret = await scramSecret(password);
    if (!/^SCRAM-SHA-256\$32768:[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+$/.test(secret)) {
      throw new RuntimeBootstrapError();
    }
    await client.query(`CREATE ROLE safeathome_runtime LOGIN INHERIT NOSUPERUSER NOCREATEDB
      NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '${secret}' IN ROLE safeathome_app`);
    const grant = await client.query<{ sql: string }>(
      "SELECT format('GRANT CONNECT ON DATABASE %I TO safeathome_runtime',current_database()) AS sql");
    await client.query(grant.rows[0].sql);
    await assertSafeExistingRole(client);
    await client.query('COMMIT');
    return createdResult(password);
  } catch {
    if (client) { try { await client.query('ROLLBACK'); } catch { discard = true; } }
    throw new RuntimeBootstrapError();
  } finally { client?.release(discard); }
}
