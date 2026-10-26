import { createHash } from 'node:crypto';
import { PDFDocument } from 'pdf-lib';
import { defineVerifiedFormTemplate } from '../src/forms/field-mapping.ts';

export async function createDemoFormArtifact(programId: string) {
  const document = await PDFDocument.create();
  const page = document.addPage([300, 300]);
  page.drawText('Fictional student integration form', { x: 20, y: 270, size: 12 });
  const field = document.getForm().createTextField('First Name');
  field.addToPage(page, { x: 30, y: 200, width: 240, height: 24 });
  const rect = field.acroField.getWidgets()[0].getRectangle();
  const bytes = await document.save();
  const templateSha256 = createHash('sha256').update(bytes).digest('hex');
  const template = defineVerifiedFormTemplate({ schemaVersion: '1', programId,
    formVersion: `sha256:${templateSha256}`, mappingVersion: 'fictional-answer-demo-v1', templateSha256,
    publisherRevision: null, sourceUrl: 'https://example.org/fictional-form.pdf',
    sourcePageUrl: 'https://example.org/fictional-forms', reviewedOn: '2026-10-17', pageCount: 1,
    fields: [{ fieldName: 'First Name', label: 'Fictional member first name', pdfType: 'Tx', semantic: 'identity',
      required: false, maxLength: null,
      widgets: [{ page: 1, rect: [rect.x, rect.y, rect.x + rect.width, rect.y + rect.height], exportValue: null }],
      binding: { kind: 'reviewed_answer', answerKey: 'memberFirstName' } }],
  });
  return { template, bytes };
}
