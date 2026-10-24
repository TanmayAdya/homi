import type { CaseSnapshot, DraftPacket, Match, MissingPacketItem } from './types.ts';

export const PACKET_PLANNER_VERSION = 'draft-checklist-v3-reviewed-answers';

const answerLabels: Record<string, string> = {
  'profile.city': 'city', 'profile.county': 'county', 'profile.healthPlan': 'health plan',
  'profile.tenure': 'housing status', 'profile.ageYears': 'age', 'profile.householdSize': 'household size',
  'profile.annualIncomeUsd': 'annual household income', 'profile.ownerConsentReported': 'reported owner permission',
};

const measurementLabels: Record<string, string> = {
  width: 'width', height: 'height', length: 'length', clearOpening: 'doorway clear opening',
};

export function instantMicros(value: string): bigint {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/.test(value)) {
    throw new Error('Invalid UTC timestamp.');
  }
  const fraction = value.match(/\.(\d+)Z$/)?.[1] ?? '';
  const normalized = `${value.slice(0, 19)}.${fraction.padEnd(3, '0').slice(0, 3)}Z`;
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString() !== normalized) throw new Error('Invalid UTC timestamp.');
  return BigInt(parsed.getTime()) * 1_000n + BigInt(fraction.padEnd(6, '0').slice(3, 6));
}

export function isPacketCurrent(packet: DraftPacket, checkedAt: string): boolean {
  const now = instantMicros(checkedAt);
  return instantMicros(packet.generatedAt) <= now && packet.recheckAfter !== null
    && now < instantMicros(packet.recheckAfter);
}

export function planDraftPacket(
  snapshot: CaseSnapshot,
  match: Match,
  context: { packetId: string; generatedAt: string },
): DraftPacket {
  if (typeof context.packetId !== 'string' || !context.packetId.trim()) throw new Error('A packet ID is required.');
  instantMicros(context.generatedAt);
  const missingItems: MissingPacketItem[] = [
    { id: 'official-form', description: 'Confirm the current official application form and its version with the program.', resolvedBy: 'program' },
    { id: 'field-mapping', description: 'Confirm which information belongs in each field before preparing the official form.', resolvedBy: 'program' },
    { id: 'intake-route', description: 'Verify the current intake route and submission instructions with the program.', resolvedBy: 'program' },
  ];
  if (match.availability !== 'accepting') {
    missingItems.push({ id: 'program-availability', description: match.availability === 'not_accepting'
      ? 'The program is not accepting requests. Ask the program about future intake or alternatives.'
      : 'Confirm whether the program is currently accepting requests.', resolvedBy: 'program' });
  }
  match.requiredDocuments.forEach((document, index) => {
    missingItems.push({ id: `required-document:${index}`, description: `Confirm whether this document is required and who should supply it: ${document}`, resolvedBy: 'program' });
  });
  for (const check of match.checks) {
    if (check.status === 'pass') continue;
    missingItems.push({ id: `check:${check.id}`, description: check.resolvedBy === null
      ? `Ask the program to identify who can resolve this requirement: ${check.explanation}`
      : check.status === 'fail'
        ? `Review the unmet requirement and any documented exceptions: ${check.explanation}`
        : `Confirm the unresolved requirement: ${check.explanation}`,
    resolvedBy: check.resolvedBy ?? 'program' });
  }
  for (const field of snapshot.unresolvedFields) {
    missingItems.push({ id: `answer:${field}`, description: `Review and resolve the conflicting or unconfirmed ${answerLabels[field] ?? 'resident'} answer.`, resolvedBy: 'resident' });
  }
  for (const finding of snapshot.findings) {
    if (finding.reviewState === 'dismissed') continue;
    const room = finding.room === 'other' ? 'home' : finding.room;
    if (finding.reviewState === 'needs_review') {
      missingItems.push({ id: `finding:${finding.id}`, description: `Review or correct this ${room} observation before considering it for the draft: ${finding.observation}`, resolvedBy: 'resident' });
    }
    finding.measurements.forEach((measurement, index) => {
      if (!measurement.confirmed || measurement.method === 'estimated') {
        missingItems.push({ id: `measurement:${finding.id}:${index}`, description: `Confirm the ${measurementLabels[measurement.type] ?? 'recorded dimension'} in millimetres using a manual measurement for the ${room} finding.`, resolvedBy: 'resident' });
      }
    });
    if (finding.evidenceIds.length > 0) {
      missingItems.push({ id: `evidence:${finding.id}`, description: `Review the evidence for the ${room} finding and confirm which files may be included.`, resolvedBy: 'resident' });
    }
  }
  return {
    schemaVersion: '1', packetId: context.packetId, caseId: snapshot.caseId,
    caseRevision: snapshot.revision, programId: match.programId, ruleVersion: match.ruleVersion,
    formVersion: null, mappingVersion: null, status: 'draft', isDemo: match.isDemo,
    generatedAt: context.generatedAt, recheckAfter: match.recheckAfter,
    storageReference: null, attachments: [], missingItems,
  };
}
