import { pathToFileURL } from 'node:url';
import { PDFDocument } from 'pdf-lib';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';
import { pageOperators, paintedText } from './pdf-verification-text.ts';

export interface TeamPdfExpectedText {
  names?: readonly string[];
  observation?: string;
  photoLabel: string;
  repairRequest: string;
}
export const FICTIONAL_CHINESE_PACKET: Readonly<TeamPdfExpectedText> = Object.freeze({
  names: Object.freeze(['陈美华', '陳美華']),
  observation: '虚构观察：门槛旁需要扶手。 / 虛構觀察：門檻旁需要扶手。',
  photoLabel: '门槛需复查 / 門檻需複查',
  repairRequest: '虚构申请：检查扶手。 / 虛構申請：檢查扶手。 Café 12',
});
const LEGACY_PACKET: TeamPdfExpectedText = { photoLabel: 'Fictional step marker', repairRequest: 'Fictional repair discussion only.' };
function check(value: unknown): asserts value { if (!value) throw new Error('Fictional PDF verification failed.'); }

export async function verifyTeamBetaPdf(bytes: Uint8Array, program: string, basePages: number,
  expected: Readonly<TeamPdfExpectedText> = LEGACY_PACKET): Promise<void> {
  check(bytes.length <= 4 * 1024 * 1024 && Buffer.from(bytes.subarray(0, 5)).toString('ascii') === '%PDF-');
  const document = await PDFDocument.load(bytes);
  check(document.getPageCount() >= basePages + 2 && document.getPageCount() <= basePages + 8 && document.getForm().getFields().length === 0);
  for (const page of document.getPages()) check((page.node.Annots()?.size() ?? 0) === 0);
  const pages = document.getPages().map((_, index) => paintedText(document, index).join('\n'));
  for (const name of expected.names ?? []) check(pages.slice(0, basePages).some(text => text.includes(name)));
  const image = pages[basePages], imageOperators = pageOperators(document, basePages);
  check(image.includes(`1: ${expected.photoLabel}`) && /0\.7 0\.08 0\.08 RG/.test(imageOperators) && /1\.5 w/.test(imageOperators));
  if (expected.observation) check(image.includes(expected.observation));
  const appendix = pages.slice(basePages + 1).join('\n');
  for (const text of ['PROGRAM PREPARATION - REPORTED FACTS ONLY', 'Reported No', 'Unknown / not provided',
    'The case changed after these answers were saved.']) check(appendix.includes(text));
  if (program === 'rtp-home-repair') {
    check(appendix.includes('App-generated worksheet; not an official RTP application.')
      && appendix.includes(`Reported: ${expected.repairRequest}`));
  } else check(appendix.includes('Reported USD 0.00'));
}

async function main() {
  const program = process.argv[2], chinese = process.argv[3] === '--chinese';
  if (process.argv.length !== (chinese ? 4 : 3) || process.env.NODE_ENV !== 'test'
    || !['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair'].includes(program)) throw new Error();
  const parts: Buffer[] = []; let size = 0;
  for await (const raw of process.stdin) {
    const part = Buffer.from(raw); size += part.length;
    if (size > 4 * 1024 * 1024) throw new Error();
    parts.push(part);
  }
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2'), form = await bundle.loadFormTemplate(program);
  if (!form) throw new Error();
  await verifyTeamBetaPdf(Buffer.concat(parts), program, form.template.pageCount, chinese ? FICTIONAL_CHINESE_PACKET : LEGACY_PACKET);
  console.log('PASS');
}
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  const deadline = setTimeout(() => { process.exitCode = 1; process.stdin.destroy(); }, 15_000); deadline.unref();
  main().catch(() => { console.error('Fictional downloaded PDF validation failed. No contents logged.'); process.exitCode = 1; })
    .finally(() => clearTimeout(deadline));
}
