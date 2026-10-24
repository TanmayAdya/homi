import { pathToFileURL } from 'node:url';
import { HostedApiVerificationError, verifyHostedApi, type HostedApiConfiguration } from '../src/auth/hosted-api-verifier.ts';
import { LiveSessionVerificationError, validateRemoteApiOrigin } from '../src/auth/live-session-verifier.ts';
import { liveSessionEnvironment, sessionFixtureIds } from './verify-live-sessions.ts';

export async function hostedApiEnvironment(
  env: NodeJS.ProcessEnv, backendDirectory?: string,
): Promise<HostedApiConfiguration> {
  try {
    if (env.NODE_TLS_REJECT_UNAUTHORIZED === '0') throw new HostedApiVerificationError('configuration');
    const apiOrigin = validateRemoteApiOrigin(env.SAFEATHOME_API_ORIGIN);
    const { auth, accounts } = liveSessionEnvironment(env);
    const caseIds = await sessionFixtureIds(new URL(auth.projectUrl).origin, env, false, backendDirectory);
    return { apiOrigin, auth, accounts, caseIds };
  } catch { throw new HostedApiVerificationError('configuration'); }
}

async function main(): Promise<void> {
  if (process.argv.length !== 2) throw new HostedApiVerificationError('configuration');
  const report = await verifyHostedApi(await hostedApiEnvironment(process.env));
  console.log(JSON.stringify(report));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(error => {
    console.error(error instanceof HostedApiVerificationError || error instanceof LiveSessionVerificationError
      ? error.message : 'Hosted API verification failed. Check the HTTPS endpoint and existing test-session configuration.');
    process.exitCode = 1;
  });
}
