import { open, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { matchPrograms } from './matcher.ts';
import { createScfhpEaaResearchProgram } from './programs/scfhp-eaa.ts';
import { createScfhpEaaFormTemplate } from './forms/scfhp-eaa-template.ts';
import { planFormFields } from './forms/field-mapping.ts';
import { planPacketWithForm } from './forms/prepare-form-packet.ts';
import { MAX_TEMPLATE_BYTES, verifyTemplateBytes } from './forms/template-artifact.ts';
import { renderDraftPreview } from './forms/render-draft-preview.ts';
import type { CaseSnapshot, EvaluationContext } from './types.ts';
import { fictionalReviewedAnswers } from '../fixtures/reviewed-form-answers.ts';

function fictionalCase(): CaseSnapshot {
  return {
    schemaVersion: '1', caseId: 'fictional-scfhp-form-review', revision: 1,
    profile: { city: 'San Jose', county: 'Santa Clara', healthPlan: 'SCFHP', tenure: 'renter',
      ageYears: null, householdSize: null, annualIncomeUsd: null, ownerConsentReported: null },
    unresolvedFields: [], findings: [],
  };
}

export function createScfhpResearchReport(bytes: Uint8Array, context: EvaluationContext, reviewedExample = false) {
  const snapshot = fictionalCase();
  if (reviewedExample) snapshot.revision = 2;
  const template = createScfhpEaaFormTemplate();
  const answers = reviewedExample ? fictionalReviewedAnswers(snapshot, template, context.evaluatedAt) : null;
  const templateSha256 = verifyTemplateBytes(bytes, template.templateSha256);
  const match = matchPrograms(snapshot, [createScfhpEaaResearchProgram()], context).matches[0];
  const formPlan = planFormFields(snapshot, template, { programId: match.programId,
    templateSha256, plannedAt: context.evaluatedAt }, answers);
  const packet = planPacketWithForm(snapshot, match, {
    packetId: 'fictional-scfhp-review-draft', generatedAt: context.evaluatedAt,
  }, { template, templateSha256 }, answers);
  return {
    notice: 'Research preview with fictional case data. No eligibility decision, completed application, submission or approval. Any separately requested PDF is an incomplete preview.',
    match, formPlan, packet,
  };
}

async function main(args: string[]): Promise<void> {
  if (args.length === 1 && ['--help', '-h'].includes(args[0])) {
    console.log('Usage: npm run research:scfhp -- --template /absolute/path/41567.pdf [--preview /absolute/path/new-draft.pdf] [--reviewed-example]\nReads a publisher-downloaded PDF locally and prints a fictional research plan. No network. Optional preview writes a new private file; existing files are never overwritten. --reviewed-example uses built-in fictional reviewed identity/contact/referral answers only.');
    return;
  }
  const reviewedExample = args.at(-1) === '--reviewed-example';
  if (reviewedExample) args = args.slice(0, -1);
  if (![2, 4].includes(args.length) || args[0] !== '--template' || !args[1].trim()
    || (args.length === 4 && (args[2] !== '--preview' || !args[3].trim()))) throw new Error('Invalid arguments.');
  const handle = await open(args[1], 'r');
  let bytes: Buffer;
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > MAX_TEMPLATE_BYTES || stat.size < 8) throw new Error('Invalid template file.');
    const buffer = Buffer.alloc(MAX_TEMPLATE_BYTES + 1);
    let total = 0;
    while (total < buffer.length) {
      const read = await handle.read(buffer, total, buffer.length - total, total);
      if (read.bytesRead === 0) break;
      total += read.bytesRead;
    }
    bytes = buffer.subarray(0, total);
  } finally {
    await handle.close();
  }
  const evaluatedAt = new Date().toISOString();
  const report = createScfhpResearchReport(bytes, { evaluatedAt, evaluationDate: evaluatedAt.slice(0, 10) }, reviewedExample);
  let renderIssues: Awaited<ReturnType<typeof renderDraftPreview>>['renderIssues'] = [];
  if (args.length === 4) {
    const snapshot = fictionalCase();
    if (reviewedExample) snapshot.revision = 2;
    const template = createScfhpEaaFormTemplate();
    const answers = reviewedExample ? fictionalReviewedAnswers(snapshot, template, evaluatedAt) : null;
    const preview = await renderDraftPreview(snapshot, template, bytes, {
      programId: 'scfhp-eaa', templateSha256: report.formPlan.templateSha256, plannedAt: evaluatedAt,
    }, answers);
    await writeFile(args[3], preview.bytes, { flag: 'wx', mode: 0o600 });
    renderIssues = preview.renderIssues;
  }
  console.log(JSON.stringify({ ...report, previewRendered: args.length === 4, renderIssues }, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(() => {
    console.error('Research preparation failed. Check the arguments, the exact reviewed 41567 PDF, and an unused preview path in an existing writable folder.');
    process.exitCode = 1;
  });
}
