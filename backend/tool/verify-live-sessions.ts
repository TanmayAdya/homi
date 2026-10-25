import { randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createDurableServer } from '../src/api/durable-server.ts';
import { isNewCaseId } from '../src/cases/validation.ts';
import { createSupabaseAuthenticator, type SupabaseAuthConfig } from '../src/auth/supabase-auth.ts';
import { LiveSessionVerificationError, validateTestAccounts, verifyLiveSessions, type TestAccount } from '../src/auth/live-session-verifier.ts';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';

const invalid = (): never => { throw new LiveSessionVerificationError('configuration'); };
const caseId = (value: unknown): value is string => isNewCaseId(value) && value.length === 36;
interface FixtureManifest { schemaVersion: '1'; projectOrigin: string; caseAId: string; caseBId: string }

export async function sessionFixtureIds(
  projectOrigin: string, env: NodeJS.ProcessEnv, createFixtures: boolean,
  backendDirectory = fileURLToPath(new URL('../', import.meta.url)),
): Promise<readonly [string, string]> {
  try {
    const a = env.SAFEATHOME_TEST_CASE_A_ID;
    const b = env.SAFEATHOME_TEST_CASE_B_ID;
    const supplied = a !== undefined || b !== undefined;
    if (supplied && (!caseId(a) || !caseId(b) || a === b)) return invalid();
    if (supplied && !createFixtures) return [a!, b!];
    const directory = join(backendDirectory, 'local-artifacts');
    if (createFixtures) await mkdir(directory, { recursive: true, mode: 0o700 });
    const directoryStat = await lstat(directory);
    if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) return invalid();
    const path = join(directory, 'session-check.json');
    const read = async (): Promise<FixtureManifest> => {
      const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
      try {
        const stat = await handle.stat();
        if (!stat.isFile() || stat.size > 2048 || (stat.mode & 0o777) !== 0o600
          || (typeof process.getuid === 'function' && stat.uid !== process.getuid())) return invalid();
        const bytes = Buffer.alloc(2049);
        let size = 0;
        while (size < bytes.length) {
          const result = await handle.read(bytes, size, bytes.length - size, size);
          if (result.bytesRead === 0) break;
          size += result.bytesRead;
        }
        if (size > 2048) return invalid();
        const value: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, size)));
        if (value === null || typeof value !== 'object' || Array.isArray(value)) return invalid();
        const manifest = value as Record<string, unknown>;
        if (Object.keys(manifest).sort().join(',') !== 'caseAId,caseBId,projectOrigin,schemaVersion'
          || manifest.schemaVersion !== '1' || manifest.projectOrigin !== projectOrigin
          || !caseId(manifest.caseAId) || !caseId(manifest.caseBId)
          || manifest.caseAId === manifest.caseBId || (supplied && (manifest.caseAId !== a || manifest.caseBId !== b))) return invalid();
        return manifest as unknown as FixtureManifest;
      } finally { await handle.close(); }
    };
    let manifest: FixtureManifest;
    try { manifest = await read(); }
    catch (error) {
      if (!createFixtures || !(error instanceof Error) || !('code' in error) || error.code !== 'ENOENT') return invalid();
      const proposed: FixtureManifest = { schemaVersion: '1', projectOrigin,
        caseAId: a ?? randomUUID(), caseBId: b ?? randomUUID() };
      let handle;
      try { handle = await open(path, 'wx', 0o600); }
      catch (collision) {
        if (!(collision instanceof Error) || !('code' in collision) || collision.code !== 'EEXIST') return invalid();
      }
      if (handle) {
        try { await handle.writeFile(`${JSON.stringify(proposed, null, 2)}\n`, 'utf8'); await handle.sync(); }
        finally { await handle.close(); }
        const directoryHandle = await open(directory, constants.O_RDONLY | constants.O_NOFOLLOW);
        try { await directoryHandle.sync(); } finally { await directoryHandle.close(); }
      }
      manifest = await read();
    }
    return Object.freeze([manifest.caseAId, manifest.caseBId]);
  } catch { return invalid(); }
}

export function liveSessionEnvironment(env: NodeJS.ProcessEnv): {
  auth: SupabaseAuthConfig; accounts: readonly [TestAccount, TestAccount];
} {
  try {
    const auth = { projectUrl: env.SAFEATHOME_SUPABASE_URL ?? '',
      publishableKey: env.SAFEATHOME_SUPABASE_PUBLISHABLE_KEY ?? '' };
    createSupabaseAuthenticator(auth);
    const accounts = validateTestAccounts([
      { email: env.SAFEATHOME_TEST_USER_A_EMAIL ?? '', password: env.SAFEATHOME_TEST_USER_A_PASSWORD ?? '' },
      { email: env.SAFEATHOME_TEST_USER_B_EMAIL ?? '', password: env.SAFEATHOME_TEST_USER_B_PASSWORD ?? '' },
    ]);
    return { auth, accounts };
  } catch { return invalid(); }
}

async function main(): Promise<void> {
  const arguments_ = process.argv.slice(2);
  if (arguments_.length > 1 || (arguments_.length === 1 && arguments_[0] !== '--create-fixtures')) invalid();
  const createFixtures = arguments_[0] === '--create-fixtures';
  const { auth, accounts } = liveSessionEnvironment(process.env);
  const database = await databaseConfigurationFromEnvironment(process.env);
  const caseIds = await sessionFixtureIds(new URL(auth.projectUrl).origin, process.env, createFixtures);
  const pool = createPostgresPool(database);
  let server: Awaited<ReturnType<typeof createDurableServer>>['server'] | undefined;
  try {
    ({ server } = await createDurableServer({ pool, auth }));
    const running = server;
    await new Promise<void>((resolve, reject) => {
      const error = () => reject(new LiveSessionVerificationError('configuration'));
      running.once('error', error);
      running.listen(0, '127.0.0.1', () => { running.off('error', error); resolve(); });
    });
    const address = running.address();
    if (!address || typeof address === 'string') return invalid();
    const report = await verifyLiveSessions({ auth, accounts, caseIds, createFixtures,
      apiOrigin: `http://127.0.0.1:${address.port}` });
    console.log(JSON.stringify(report));
  } finally {
    if (server?.listening) {
      const closing = server;
      await new Promise<void>(resolve => {
        const timer = setTimeout(() => closing.closeAllConnections(), 1000);
        timer.unref(); closing.close(() => { clearTimeout(timer); resolve(); });
      });
    }
    await pool.end();
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(error => {
    console.error(error instanceof LiveSessionVerificationError ? error.message
      : 'Live session verification could not start or finish. Check the test accounts, retained fixture IDs, runtime database role, TLS and migrations.');
    process.exitCode = 1;
  });
}
