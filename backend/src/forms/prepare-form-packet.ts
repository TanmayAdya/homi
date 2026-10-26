import { planDraftPacket } from '../packets.ts';
import type { CaseSnapshot, DraftPacket, Match } from '../types.ts';
import { planFormFields, type VerifiedFormTemplate } from './field-mapping.ts';

export interface VerifiedTemplateArtifact {
  template: VerifiedFormTemplate;
  templateSha256: string;
}

export function planPacketWithForm(
  snapshot: CaseSnapshot,
  match: Match,
  context: { packetId: string; generatedAt: string },
  artifact: VerifiedTemplateArtifact | null,
  answersInput?: unknown,
): DraftPacket {
  const packet = planDraftPacket(snapshot, match, context);
  if (artifact === null) return packet;
  const plan = planFormFields(snapshot, artifact.template, {
    programId: match.programId, templateSha256: artifact.templateSha256, plannedAt: context.generatedAt,
  }, answersInput);
  packet.formVersion = plan.formVersion;
  packet.mappingVersion = plan.mappingVersion;
  packet.missingItems = packet.missingItems.filter(item => !['official-form', 'field-mapping'].includes(item.id));
  packet.missingItems.unshift(
    { id: 'form-currentness', description: plan.publisherRevision === null
      ? 'The downloaded form is identified by its file contents. Confirm its publisher revision and current acceptance before export.'
      : 'Confirm that the reviewed form version is still accepted before export.', resolvedBy: 'program' },
    { id: 'form-rendering', description: 'Complete the required reviews, render the official draft and inspect every populated field before export. This checklist contains no PDF.', resolvedBy: 'program' },
  );
  plan.fields.forEach((field, index) => {
    if (field.status === 'mapped' || field.status === 'not_applicable') return;
    packet.missingItems.push({
      id: `form-field:${index}`,
      description: field.status === 'missing'
        ? `Confirm whether this information applies, then supply and review it: ${field.label}.`
        : `Review this part of the form before completion: ${field.label}.`,
      resolvedBy: field.resolvedBy ?? 'program',
    });
  });
  return packet;
}
