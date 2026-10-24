import { PDFArray, PDFDocument, PDFRawStream, decodePDFRawStream } from 'pdf-lib';
import { loadRuntimeBenefitsBundle } from '../src/programs/runtime-bundle.ts';

async function main() {
  const program = process.argv[2];
  if (process.argv.length !== 3 || process.env.NODE_ENV !== 'test'
    || !['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair'].includes(program)) throw new Error();
  const parts: Buffer[] = []; let size = 0;
  for await (const raw of process.stdin) {
    const part = Buffer.from(raw); size += part.length;
    if (size > 4 * 1024 * 1024) throw new Error();
    parts.push(part);
  }
  const bytes = Buffer.concat(parts);
  if (bytes.subarray(0, 5).toString('ascii') !== '%PDF-') throw new Error();
  const document = await PDFDocument.load(bytes);
  const bundle = await loadRuntimeBenefitsBundle('team-beta-drafts-v2');
  const form = await bundle.loadFormTemplate(program);
  if (!form || document.getPageCount() < form.template.pageCount + 2) throw new Error();
  const content = (index: number) => {
    const page = document.getPage(index), contents = page.node.Contents();
    if ((page.node.Annots()?.size() ?? 0) !== 0) throw new Error();
    return (contents instanceof PDFArray ? contents.asArray() : [contents]).map(ref => {
      const stream = document.context.lookup(ref); if (!(stream instanceof PDFRawStream)) throw new Error();
      return Buffer.from(decodePDFRawStream(stream).decode()).toString('latin1');
    }).join('\n');
  };
  const hasText = (operators: string, text: string) => operators.includes(Buffer.from(text).toString('hex').toUpperCase());
  const imagePage = content(form.template.pageCount);
  if (!hasText(imagePage, '1: Fictional step marker') || !/0\.7 0\.08 0\.08 RG/.test(imagePage) || !/1\.5 w/.test(imagePage)) throw new Error();
  const appendix = Array.from({ length: document.getPageCount() - form.template.pageCount - 1 }, (_, i) => content(form.template.pageCount + 1 + i)).join('\n');
  for (const text of ['PROGRAM PREPARATION - REPORTED FACTS ONLY', 'Reported No', 'Unknown / not provided',
    'The case changed after these answers were saved.']) if (!hasText(appendix, text)) throw new Error();
  if (program === 'rtp-home-repair') {
    if (!hasText(appendix, 'App-generated worksheet; not an official RTP application.')
      || !hasText(appendix, 'Reported: Fictional repair discussion only.')) throw new Error();
  } else if (!hasText(appendix, 'Reported USD 0.00')) throw new Error();
  console.log('PASS');
}
const deadline = setTimeout(() => { process.exitCode = 1; process.stdin.destroy(); }, 15_000); deadline.unref();
main().catch(() => { console.error('Fictional downloaded PDF validation failed. No contents logged.'); process.exitCode = 1; })
  .finally(() => clearTimeout(deadline));
