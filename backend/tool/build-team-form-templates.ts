import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { PDFDocument, PDFTextField, PDFCheckBox, PDFRadioGroup, PDFButton, PDFDropdown, PDFOptionList, PDFDict, PDFName, StandardFonts, rgb } from 'pdf-lib';
import { formAnswerFieldsForProgram } from '../src/forms/form-answers.ts';
import { defineVerifiedFormTemplate } from '../src/forms/field-mapping.ts';
const root = new URL('../', import.meta.url);
const hash = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const stamp = new Date('2026-10-22T00:00:00.000Z');
const sourceUrl = 'https://www.hpsm.org/docs/default-source/provider-forms/community-supports-referral-form.pdf?sfvrsn=9b37cc61_20';
const source = await readFile(new URL('assets/forms/hpsm-community-supports.pdf', root));
const sourceSha256 = 'b64496cb1f0bd68f1dabcdb8b900b2e3179b68990399c75dd0fd5d22ec2616c8';
if (hash(source) !== sourceSha256) throw new Error('HPSM source changed; independent review required.');
const original = await PDFDocument.load(source, { updateMetadata: false });
const originalForm = original.getForm();
const originalPages = original.getPages();
if (originalPages.length !== 6) throw new Error('Unexpected HPSM page inventory.');
const approved = formAnswerFieldsForProgram('hpsm-eaa');
const positions = approved.map(item => {
  const field = originalForm.getTextField(item.fieldName);
  const widgets = field.acroField.getWidgets();
  if (widgets.length !== 1) throw new Error('Unreviewed field layout.');
  const widget = widgets[0]!;
  const page = originalPages.findIndex(page => page.ref.toString() === widget.P()?.toString());
  if (page < 0) throw new Error('Unbound source field.');
  return { item, page, rect: widget.getRectangle() };
});
const routeWidget = originalForm.getCheckBox('5').acroField.getWidgets()[0]!;
const routePage = originalPages.findIndex(page => page.ref.toString() === routeWidget.P()?.toString());
const routeRect = routeWidget.getRectangle();
if (routePage !== 3) throw new Error('Unexpected EAA route placement.');
for (const field of [...originalForm.getFields()]) {
  if (field instanceof PDFButton) originalForm.removeField(field);
  else if (field instanceof PDFTextField) field.setText('');
  else if (field instanceof PDFCheckBox) field.uncheck();
  else if (field instanceof PDFRadioGroup) field.clear();
  else if (field instanceof PDFDropdown || field instanceof PDFOptionList) field.clear();
  else throw new Error('Unreviewed source field type.');
}
for (const [, object] of original.context.enumerateIndirectObjects()) {
  if (object instanceof PDFDict) for (const key of ['A', 'AA', 'OpenAction', 'JS', 'JavaScript']) object.delete(PDFName.of(key));
}
originalForm.flatten();
const hpsm = await PDFDocument.create();
for (const page of await hpsm.embedPages(originalPages)) {
  hpsm.addPage([page.width, page.height]).drawPage(page);
}
const hpsmForm = hpsm.getForm();
for (const { item, page, rect } of positions) {
  const field = hpsmForm.createTextField(item.fieldName);
  field.setMaxLength(item.maxLength);
  field.addToPage(hpsm.getPage(page), { ...rect, borderWidth: 0, backgroundColor: undefined });
}
const route = hpsmForm.createCheckBox('5');
route.addToPage(hpsm.getPage(routePage), { ...routeRect, borderWidth: 0.5 });
route.uncheck();
await writeTemplate(hpsm, 'hpsm-eaa', 'hpsm-eaa-inert.pdf', sourceUrl,
  'https://www.hpsm.org/provider/calaim-at-hpsm/community-supports-(cs)',
  'HPSM six-page source; blank, inert preparation derivative; source hash in provenance',
  'hpsm-six-page-administrative-2026-10-22-v1');
await writeFile(new URL('assets/forms/hpsm-eaa-provenance.json', root), JSON.stringify({
  schemaVersion: '1', sourceUrl, sourceSha256, reviewedOn: '2026-10-22', sourcePages: 6,
  derivative: 'hpsm-eaa-inert.pdf', derivativeSha256: hash(await readFile(new URL('assets/forms/hpsm-eaa-inert.pdf', root))),
  transformations: ['Clear every original input', 'Remove Save for Email and Print for Fax utility controls',
    'Flatten blank original fields into six preserved page backgrounds', 'Copy page contents into a fresh document without action/name trees',
    'Add only ten independently mapped administrative text fields and EAA route checkbox 5'],
  limitations: ['Clinical criteria, consent, attestation, signatures and plan decisions remain blank.',
    'Preparation derivative; confirm current accepted submission format with HPSM before use.'],
}, null, 2) + '\n');

const rtp = await PDFDocument.create();
const font = await rtp.embedFont(StandardFonts.Helvetica);
const bold = await rtp.embedFont(StandardFonts.HelveticaBold);
const page = rtp.addPage([612, 792]);
const line = (text: string, y: number, size = 11, strong = false) => page.drawText(text, { x: 44, y, size, font: strong ? bold : font, color: rgb(0.08, 0.12, 0.18) });
line('SAFE AT HOME - PREPARATION WORKSHEET', 748, 16, true);
line('Rebuilding Together Peninsula', 722, 14, true);
line('APP-GENERATED WORKSHEET - NOT AN OFFICIAL APPLICATION', 700, 10, true);
line('Fictional team beta. Draft only. Nothing is submitted by this app.', 682, 10);
const form = rtp.getForm();
let y = 632;
for (const item of formAnswerFieldsForProgram('rtp-home-repair')) {
  const labels: Record<string, string> = { memberFirstName: 'Homeowner given name', memberLastName: 'Homeowner family name',
    memberPhone: 'Contact phone', memberPreferredSpokenLanguage: 'Preferred spoken language' };
  line(labels[item.key]!, y + 24, 10);
  const field = form.createTextField(item.fieldName); field.setMaxLength(item.maxLength);
  field.addToPage(page, { x: 44, y, width: 520, height: 20, borderWidth: 0.5 });
  y -= 64;
}
line('Prepare for the official homeowner intake', 354, 12, true);
const lines = [
  'Confirm current service area, household income rules and intake availability with RTP.',
  'Gather proof of ownership, household income and residence for the official intake.',
  'Review owner occupancy, other property ownership and plans to remain in the home.',
  'List requested repairs and questions. Reported facts still require RTP verification.',
  'Provide sensitive supporting documents only through the official requested process.',
  'Do not upload tax, bank or identity documents to this fictional beta.',
  'The app does not establish eligibility, approval, consent or a repair commitment.',
];
lines.forEach((text, i) => line(text, 330 - i * 23, 10));
line('Official application (open separately; confirm it remains current):', 144, 10, true);
line('https://rebuildingtogetherpeninsula.my.salesforce-sites.com/', 122, 9);
line('HomeownerApplication', 108, 9);
line('Signatures and official application answers must be completed in the accepted process.', 76, 9);
await writeTemplate(rtp, 'rtp-home-repair', 'rtp-preparation-worksheet.pdf',
  'https://rebuildingtogetherpeninsula.my.salesforce-sites.com/HomeownerApplication',
  'https://rebuildingtogetherpeninsula.org/', 'Safe at Home app-generated preparation worksheet; not an RTP form',
  'rtp-preparation-worksheet-2026-10-22-v1');

async function writeTemplate(doc: PDFDocument, programId: string, filename: string, sourceUrl: string,
  sourcePageUrl: string, publisherRevision: string, mappingVersion: string) {
  doc.setCreationDate(stamp); doc.setModificationDate(stamp); doc.setProducer('Safe at Home public template builder');
  doc.setCreator('Safe at Home');
  const bytes = await doc.save({ useObjectStreams: false });
  const loaded = await PDFDocument.load(bytes, { updateMetadata: false });
  const pages = loaded.getPages();
  const policy = formAnswerFieldsForProgram(programId);
  const fields = loaded.getForm().getFields().map(field => {
    const allowed = policy.find(item => item.fieldName === field.getName());
    const isRoute = field.getName() === '5' && programId === 'hpsm-eaa';
    if (!allowed && !isRoute) throw new Error('Unapproved generated field.');
    const widgets = field.acroField.getWidgets().map(widget => {
      const { x, y, width, height } = widget.getRectangle();
      const page = pages.findIndex(page => page.ref.toString() === widget.P()?.toString()) + 1;
      return { page, rect: [x, y, x + width, y + height], exportValue: isRoute ? 'Yes' : null };
    });
    return { fieldName: field.getName(), label: isRoute ? 'EAA referral route only; not clinical eligibility' : allowed!.key,
      pdfType: isRoute ? 'Btn' : 'Tx', widgets, semantic: isRoute ? 'routing' : allowed!.semantic,
      required: false, maxLength: isRoute ? null : allowed!.maxLength,
      binding: isRoute ? { kind: 'routing', programId, widgetIndex: 0, value: 'Yes' }
        : { kind: 'reviewed_answer', answerKey: allowed!.key } };
  });
  const template = defineVerifiedFormTemplate({ schemaVersion: '1', programId,
    formVersion: `sha256:${hash(bytes)}`, templateSha256: hash(bytes), mappingVersion,
    publisherRevision, sourceUrl, sourcePageUrl, reviewedOn: '2026-10-22', pageCount: pages.length, fields });
  await writeFile(new URL(`assets/forms/${filename}`, root), bytes);
  await writeFile(new URL(`src/forms/${programId}-template.ts`, root),
    `// Public template generated by tool/build-team-form-templates.ts; independently reviewed mappings only.\n` +
    `import { defineVerifiedFormTemplate } from './field-mapping.ts';\n` +
    `export function create${programId === 'hpsm-eaa' ? 'HpsmEaa' : 'RtpHomeRepair'}FormTemplate() {\n` +
    `  return defineVerifiedFormTemplate(${JSON.stringify(template, null, 2)});\n}\n`);
}
