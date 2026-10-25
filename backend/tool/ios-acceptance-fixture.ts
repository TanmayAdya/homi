import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { chmod, lstat, mkdir, open } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createDurableServer } from '../src/api/durable-server.ts';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import { applyMigrations } from '../src/storage/migrate.ts';
import { DisposablePostgres } from './disposable-postgres.ts';

const AUTH_ORIGIN = 'https://ios-acceptance-auth.invalid';
const KEY = 'sb_publishable_fictional_ios_acceptance';
const MAX_REQUESTS = 1000, LIFETIME_MS = 45 * 60_000;
const json = (response: ServerResponse, status: number, value: unknown) => {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  response.end(JSON.stringify(value));
};
async function readControl(request: IncomingMessage) {
  let bytes = 0; const parts: Buffer[] = [];
  for await (const part of request) { bytes += part.length; if (bytes > 4096) throw new Error('Control bound.'); parts.push(part); }
  return JSON.parse(Buffer.concat(parts, bytes).toString('utf8')) as Record<string, unknown>;
}
function sameKey(value: string | undefined, key: string) {
  return value !== undefined && value.length === key.length && timingSafeEqual(Buffer.from(value), Buffer.from(key));
}

export async function startIosAcceptanceFixture(pgBin?: string) {
  const cluster = await DisposablePostgres.start(pgBin);
  let listening: ReturnType<typeof createServer> | undefined;
  try {
    const admin = cluster.pool(); await applyMigrations(admin);
    await admin.query('CREATE ROLE sah_ios_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
    const runId = randomUUID(), owners = { alice: randomUUID(), bob: randomUUID() }, fixtureKey = randomBytes(32).toString('base64url');
    const tokens = new Map<string, string>();
    let requests = 0, stopping: Promise<void> | undefined;
    const routes: Record<string, number> = {};
    const fetchImpl: typeof fetch = async (url, init) => {
      if (url !== `${AUTH_ORIGIN}/auth/v1/user` || init?.method !== 'GET' || init.redirect !== 'error') throw new Error('Unexpected fictional provider request.');
      const headers = new Headers(init.headers), token = headers.get('authorization')?.replace(/^Bearer /, '');
      if (headers.get('apikey') !== KEY || !token || !tokens.has(token)) return Response.json({ error: 'fictional_invalid_session' }, { status: 401 });
      return Response.json({ id: tokens.get(token), role: 'authenticated' });
    };
    const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
    const api = await createDurableServer({ pool: cluster.pool('sah_ios_runtime'), auth: { projectUrl: AUTH_ORIGIN, publishableKey: KEY },
      fetchImpl, loadRegistry: bundle.loadRegistry, loadFormTemplate: bundle.loadFormTemplate });
    const status = async () => ({ schemaVersion: '1', runId, authentication: 'fictional_provider_only', storage: 'disposable_postgresql',
      requests, routes: { ...routes }, cases: Number((await admin.query('SELECT count(*) AS n FROM safeathome_private.cases')).rows[0].n),
      evidence: Number((await admin.query('SELECT count(*) AS n FROM safeathome_private.evidence')).rows[0].n),
      closedAccounts: Number((await admin.query('SELECT count(*) AS n FROM safeathome_private.closed_accounts')).rows[0].n),
      derivedRows: Number((await admin.query(`SELECT
        (SELECT count(*) FROM safeathome_private.matches) + (SELECT count(*) FROM safeathome_private.packets) +
        (SELECT count(*) FROM safeathome_private.form_answers) + (SELECT count(*) FROM safeathome_private.program_intake) +
        (SELECT count(*) FROM safeathome_private.assessment_metadata) + (SELECT count(*) FROM safeathome_private.evidence_annotations) +
        (SELECT count(*) FROM safeathome_private.exports) + (SELECT count(*) FROM safeathome_private.request_history) AS n`)).rows[0].n) });
    const server = createServer({ maxHeaderSize: 8192 }, (request, response) => {
      requests++;
      if (requests > MAX_REQUESTS) { json(response, 503, { error: 'fixture_request_limit' }); return; }
      if (request.url?.startsWith('/__fixture/')) {
        void (async () => {
          if (request.method !== 'POST' || !sameKey(request.headers['x-fictional-fixture-key'] as string | undefined, fixtureKey)) {
            json(response, 404, { error: 'not_found' }); return;
          }
          const body = await readControl(request);
          if (request.url === '/__fixture/session') {
            if (!['alice', 'bob'].includes(body.account as string) || body.password !== 'fictional-password-only' || tokens.size >= 100) {
              json(response, 401, { error: 'fictional_sign_in_failed' }); return;
            }
            const owner = owners[body.account as keyof typeof owners], now = Math.floor(Date.now() / 1000);
            const token = [Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url'),
              Buffer.from(JSON.stringify({ sub: owner, iss: `${AUTH_ORIGIN}/auth/v1`, aud: 'authenticated', role: 'authenticated',
                iat: now, exp: now + 3600, amr: [{ method: 'password', timestamp: now }], jti: randomUUID() })).toString('base64url'),
              randomBytes(32).toString('base64url')].join('.');
            tokens.set(token, owner);
            json(response, 200, { userId: owner, accessToken: token, authentication: 'fictional_provider_only' }); return;
          }
          if (request.url === '/__fixture/status' && Object.keys(body).length === 0) { json(response, 200, await status()); return; }
          json(response, 404, { error: 'not_found' });
        })().catch(() => { if (!response.headersSent) json(response, 400, { error: 'invalid_fixture_request' }); else response.destroy(); });
        return;
      }
      if (/^\/v[12]\/[a-z-]{1,48}$/.test(request.url ?? '')) routes[request.url!] = (routes[request.url!] ?? 0) + 1;
      api.server.emit('request', request, response);
    });
    server.requestTimeout = 30_000; server.headersTimeout = 10_000; server.keepAliveTimeout = 1000;
    listening = server;
    await new Promise<void>((accept, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', accept); });
    const address = server.address(); if (!address || typeof address === 'string') throw new Error('Local fixture listener failed.');
    const close = () => stopping ??= (async () => {
      clearTimeout(deadline);
      await new Promise<void>(accept => { server.close(() => accept()); server.closeAllConnections(); });
      tokens.clear(); await cluster.close();
    })();
    const deadline = setTimeout(() => { void close().catch(() => { process.exitCode = 1; }); }, LIFETIME_MS); deadline.unref();
    return { baseUri: `http://127.0.0.1:${address.port}`, runId, owners, fixtureKey, status, close, directory: cluster.directory,
      defines: { SAH_IOS_ACCEPTANCE_PORT: String(address.port), SAH_IOS_ACCEPTANCE_KEY: fixtureKey, SAH_IOS_ACCEPTANCE_RUN: runId,
        SAH_IOS_ACCEPTANCE_ALICE: owners.alice, SAH_IOS_ACCEPTANCE_BOB: owners.bob } };
  } catch (error) {
    if (listening) { listening.close(); listening.closeAllConnections(); }
    await cluster.close(); throw error;
  }
}

async function main() {
  const args = process.argv.slice(2), backend = fileURLToPath(new URL('../', import.meta.url));
  if (process.env.NODE_ENV !== 'test' || args.length !== 2 || args[0] !== '--output'
    || args[1] !== resolve(args[1]) || dirname(args[1]) !== join(backend, 'local-artifacts')
    || !/^[A-Za-z0-9_-]+\.json$/.test(args[1].split('/').at(-1)!)) throw new Error('Explicit local fixture configuration required.');
  await mkdir(dirname(args[1]), { recursive: true, mode: 0o700 });
  const parent = await lstat(dirname(args[1]));
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== process.getuid?.()) throw new Error('Private owned directory required.');
  const file = await open(args[1], 'wx', 0o600);
  try {
    const fixture = await startIosAcceptanceFixture();
    try { await file.writeFile(JSON.stringify(fixture.defines)); await file.sync(); await chmod(args[1], 0o600); }
    catch (error) { await fixture.close(); throw error; }
    console.log(JSON.stringify({ status: 'ready', scope: 'local_postgresql_fake_auth', port: new URL(fixture.baseUri).port, maxMinutes: 45 }));
    let stopping = false;
    const stop = () => {
      if (stopping) return; stopping = true;
      void fixture.close().then(() => { console.log(JSON.stringify({ status: 'stopped', cleanup: 'removed' })); }, () => {
        console.error('Local acceptance fixture cleanup failed. Inspect its owned temporary cluster.'); process.exitCode = 1;
      });
    };
    process.once('SIGINT', stop); process.once('SIGTERM', stop);
  } finally { await file.close(); }
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) main().catch(() => {
  console.error('Local iOS fixture could not start. No private cloud configuration was used.'); process.exitCode = 1;
});
