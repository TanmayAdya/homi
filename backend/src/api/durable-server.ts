import { pathToFileURL } from 'node:url';
import type { Pool } from 'pg';
import { createSupabaseAuthenticator, type SupabaseAuthConfig } from '../auth/supabase-auth.ts';
import { PostgresCaseRepository } from '../storage/postgres-case-repository.ts';
import { assertMigrationsCurrent } from '../storage/migrate.ts';
import { assertRestrictedRuntimeRole, createPostgresPool, databaseConfigurationFromEnvironment } from '../storage/postgres-pool.ts';
import type { DraftExportDependencies } from './draft-export.ts';
import { createMatchingServer } from './http-server.ts';
import { benefitsBundleNameFromEnvironment, loadRuntimeBenefitsBundle } from '../programs/runtime-bundle.ts';
import { createRecentSupabaseAuthenticator } from '../auth/recent-authentication.ts';

export interface DurableServerOptions {
  pool: Pool;
  auth: SupabaseAuthConfig;
  fetchImpl?: typeof fetch;
  loadRegistry?: DraftExportDependencies['loadRegistry'];
  loadFormTemplate?: DraftExportDependencies['loadFormTemplate'];
}

export async function createDurableServer(options: DurableServerOptions) {
  const providerAuthenticate = createSupabaseAuthenticator(options.auth, options.fetchImpl);
  await assertRestrictedRuntimeRole(options.pool);
  await assertMigrationsCurrent(options.pool);
  const cases = new PostgresCaseRepository(options.pool);
  const authenticate = async (token: string) => {
    const user = await providerAuthenticate(token);
    return user && !await cases.isAccountClosed(user.userId) ? user : null;
  };
  const lifecycleDependencies = { authenticate, lifecycle: cases,
    authenticateForDeletion: createRecentSupabaseAuthenticator(options.auth, options.fetchImpl) };
  const dependencies = {
    authenticate, cases, now: () => new Date(),
    loadRegistry: options.loadRegistry ?? (async () => []),
    loadFormTemplate: options.loadFormTemplate ?? (async () => null),
  };
  const server = createMatchingServer(dependencies, dependencies, dependencies,
    dependencies, dependencies, dependencies, { hosted: true, lifecycleDependencies, caseListDependencies: dependencies, requestTrackingDependencies: dependencies, assessmentDependencies: dependencies, programIntakeDependencies: dependencies });
  return { server, cases };
}

export function durableHttpConfiguration(env: NodeJS.ProcessEnv): { port: number; host: '127.0.0.1' | '0.0.0.0'; auth: SupabaseAuthConfig } {
  const value = env.PORT ?? env.SAFEATHOME_PORT ?? '8788';
  if (!/^[1-9][0-9]{0,4}$/.test(value) || Number(value) > 65535) throw new Error('Invalid durable server port.');
  const host = env.SAFEATHOME_HOST ?? '127.0.0.1';
  if (host !== '127.0.0.1' && host !== '0.0.0.0') throw new Error('Invalid durable server host.');
  const auth = { projectUrl: env.SAFEATHOME_SUPABASE_URL ?? '', publishableKey: env.SAFEATHOME_SUPABASE_PUBLISHABLE_KEY ?? '' };
  createSupabaseAuthenticator(auth);
  return { port: Number(value), host, auth };
}

async function main() {
  if (process.argv.length !== 2) throw new Error('Configure the durable server through its environment.');
  const { port, host, auth } = durableHttpConfiguration(process.env);
  const bundle = await loadRuntimeBenefitsBundle(benefitsBundleNameFromEnvironment(process.env));
  const pool = createPostgresPool(await databaseConfigurationFromEnvironment(process.env));
  try {
    const { server } = await createDurableServer({ pool, auth,
      loadRegistry: bundle.loadRegistry, loadFormTemplate: bundle.loadFormTemplate });
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => reject(error);
      server.once('error', onError);
      server.listen(port, host, () => { server.off('error', onError); resolve(); });
    });
    console.log(`Durable API listening on http://${host}:${port}. Benefits bundle: ${bundle.name}; draft preparation only.`);
    await new Promise<void>(resolve => {
      let stopping = false;
      const stop = () => {
        if (stopping) return;
        stopping = true;
        const deadline = setTimeout(() => server.closeAllConnections(), 20_000);
        deadline.unref();
        server.close(() => { clearTimeout(deadline); resolve(); });
      };
      process.once('SIGINT', stop);
      process.once('SIGTERM', stop);
      server.once('error', () => { process.exitCode = 1; stop(); });
      server.once('close', () => {
        process.off('SIGINT', stop);
        process.off('SIGTERM', stop);
      });
    });
  } finally { await pool.end(); }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(() => {
    console.error('Durable API could not start or stopped unexpectedly. Check authentication configuration, database role, TLS, migrations, benefits bundle/artifact and port.');
    process.exitCode = 1;
  });
}
