import { pathToFileURL } from 'node:url';
import { HostedApiVerificationError, verifyHostedApi } from '../src/auth/hosted-api-verifier.ts';
import { LiveSessionVerificationError } from '../src/auth/live-session-verifier.ts';
import { hostedApiEnvironment } from './verify-hosted-api.ts';

async function main(): Promise<void> {
  if (process.argv.length !== 2) throw new HostedApiVerificationError('configuration');
  const report = await verifyHostedApi(await hostedApiEnvironment(process.env), { verifyCaseDiscovery: true });
  console.log(JSON.stringify(report));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(error => {
    console.error(error instanceof HostedApiVerificationError || error instanceof LiveSessionVerificationError
      ? error.message : 'Hosted case discovery verification failed. Check the HTTPS endpoint and existing test-session configuration.');
    process.exitCode = 1;
  });
}
