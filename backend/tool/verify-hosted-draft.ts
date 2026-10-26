import { randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { liveSessionEnvironment } from './verify-live-sessions.ts';
import { hostedDraftConfiguration, HostedDraftVerificationError, verifyHostedDraft,
  type DraftJournalEvent, type HostedDraftReport } from '../src/auth/hosted-draft-verifier.ts';

export async function createHostedDraftJournal(
  directory: string, initial: { apiOrigin: string; projectOrigin: string; caseId: string; generationKey: string },
) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new HostedDraftVerificationError('configuration');
  const pdfPath = join(directory, 'hosted-draft-preview.pdf');
  try { await lstat(pdfPath); throw new HostedDraftVerificationError('configuration'); }
  catch (error) {
    if (!(error instanceof Error) || !('code' in error) || error.code !== 'ENOENT') throw new HostedDraftVerificationError('configuration');
  }
  const handle = await open(join(directory, 'hosted-draft-check.jsonl'), 'ax', 0o600);
  try {
    await handle.writeFile(`${JSON.stringify({ schemaVersion: '1', kind: 'retained-identifiers', ...initial })}\n`);
    await handle.sync();
    const parent = await open(directory, constants.O_RDONLY | constants.O_NOFOLLOW);
    try { await parent.sync(); } finally { await parent.close(); }
  } catch (error) { await handle.close(); throw error; }
  return {
    async journal(event: Readonly<DraftJournalEvent>): Promise<void> {
      await handle.writeFile(`${JSON.stringify(event)}\n`); await handle.sync();
    },
    async onPdf(bytes: Uint8Array): Promise<void> {
      const file = await open(pdfPath, 'wx', 0o600);
      try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
      const parent = await open(directory, constants.O_RDONLY | constants.O_NOFOLLOW);
      try { await parent.sync(); } finally { await parent.close(); }
    },
    async report(value: HostedDraftReport): Promise<void> {
      await handle.writeFile(`${JSON.stringify({ kind: 'report', ...value })}\n`); await handle.sync();
    },
    close: () => handle.close(),
  };
}

async function main() {
  if (process.argv.length !== 3 || process.argv[2] !== '--create-fictional-case'
    || process.env.NODE_TLS_REJECT_UNAUTHORIZED === '0') throw new HostedDraftVerificationError('configuration');
  const { auth, accounts } = liveSessionEnvironment(process.env);
  const config = hostedDraftConfiguration({ apiOrigin: process.env.SAFEATHOME_API_ORIGIN ?? '', auth, accounts,
    caseId: randomUUID(), generationKey: randomUUID() });
  const local = await createHostedDraftJournal(fileURLToPath(new URL('../local-artifacts/', import.meta.url)),
    { apiOrigin: config.apiOrigin, projectOrigin: new URL(auth.projectUrl).origin, caseId: config.caseId, generationKey: config.generationKey });
  try {
    const report = await verifyHostedDraft(config, local);
    await local.report(report);
    console.log(JSON.stringify(report));
  } finally { await local.close(); }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(error => {
    console.error(error instanceof HostedDraftVerificationError ? error.message
      : 'Hosted draft verification could not finish. Inspect the retained journal before recovery; do not replay uncertain writes.');
    process.exitCode = 1;
  });
}
