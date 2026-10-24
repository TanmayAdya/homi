import { pathToFileURL } from 'node:url';
import { bootstrapRuntimeRole } from '../src/storage/bootstrap-runtime.ts';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';

export async function bootstrapRuntimeFromEnvironment(env: NodeJS.ProcessEnv): Promise<void> {
  const password = env.SAFEATHOME_RUNTIME_DATABASE_PASSWORD;
  if (!password || password.startsWith('REPLACE_')) throw new Error('Configure a distinct runtime database password privately.');
  const pool = createPostgresPool(await databaseConfigurationFromEnvironment(env, 'migration'));
  try {
    const result = await bootstrapRuntimeRole(pool, { password });
    console.log(result.status === 'created'
      ? 'PASS: restricted safeathome_runtime login created. Configure its runtime connection separately.'
      : 'PASS: existing restricted safeathome_runtime login left unchanged. Its password was not replaced or verified.');
  } finally { await pool.end(); }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  Promise.resolve().then(() => {
    if (process.argv.length !== 2) throw new Error('Unexpected arguments.');
    return bootstrapRuntimeFromEnvironment(process.env);
  }).catch(() => {
    console.error('Runtime login setup failed. Check current migrations, dedicated migration privileges and the private runtime password. No credentials were logged.');
    process.exitCode = 1;
  });
}
