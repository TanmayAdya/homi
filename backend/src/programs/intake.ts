import { createHash } from 'node:crypto';
import { canonicalJson, evidenceIdentifier, evidenceInstant, evidenceRevision } from '../evidence/validation.ts';

export interface IntakeQuestion {
  key: string; label: string; kind: 'boolean' | 'money' | 'text'; maxLength: number | null;
  description: string;
}
export interface IntakeDefinition { programId: string; questionnaireVersion: string; questions: IntakeQuestion[] }
export interface ProgramIntakeAppendix { definition: IntakeDefinition; saved: SavedProgramIntake | null }
export interface IntakeAnswer { key: string; value: string | number | boolean | null; reviewState: 'reported' | 'unknown' }
export interface SavedProgramIntake {
  schemaVersion: '2'; caseId: string; caseRevision: number; programId: string; questionnaireVersion: string;
  intakeRevision: number; updatedAt: string; updatedBy: string; answers: IntakeAnswer[];
}
const boolean = (key: string, label: string, description: string): IntakeQuestion => ({ key, label, kind: 'boolean', maxLength: null, description });
const money = (key: string, label: string): IntakeQuestion => ({ key, label, kind: 'money', maxLength: null,
  description: 'US dollars, up to two decimal places. Unknown is different from zero. A reported amount does not establish funding eligibility.' });
const commonHealth = [
  boolean('activeMembershipReported', 'Do you believe your membership is currently active?', 'The health plan must verify enrollment and applicable coverage.'),
  boolean('willingServicesReported', 'Are you interested in receiving home adaptation services?', 'Interest is not a signed consent or authorization.'),
  boolean('professionalEvaluationReported', 'Do you have a professional home or therapy evaluation?', 'Record whether a document is available. The app does not evaluate medical necessity.'),
  boolean('professionalOrderReported', 'Do you have a professional order for the requested work?', 'The responsible professional and health plan determine whether the order is sufficient.'),
  boolean('otherFundingReported', 'Is another source paying for the same requested work?', 'The plan reviews overlapping services and other coverage.'),
  money('estimatedCostUsd', 'Estimated project cost, if known'),
  money('priorEaaPaidUsd', 'Prior EAA payments, if known'),
];
const questions: Readonly<Record<string, readonly IntakeQuestion[]>> = {
  'scfhp-eaa': commonHealth,
  'hpsm-eaa': [...commonHealth, boolean('careManagerEngagedReported', 'Are you working with a care manager?', 'HPSM must confirm its current care-management and referral requirements.')],
  'rtp-home-repair': [
    boolean('ownerOccupiedReported', 'Do you own and live in the home?', 'RTP must verify ownership, residence and its current service area.'),
    boolean('otherPropertyReported', 'Do you own other real estate?', 'RTP must confirm whether and how this affects the currently accepted application.'),
    boolean('intendRemainTwoYearsReported', 'Do you intend to remain in this home for at least two years?', 'This prepares a discussion with RTP; the app has not verified the current annual eligibility rules.'),
    boolean('incomeDocumentsReady', 'Are household income documents ready?', 'Follow RTP instructions for adults in the household. Do not upload bank statements or tax records to this app.'),
    boolean('ownershipDocumentsReady', 'Is proof of ownership ready?', 'Submit supporting documents through RTP’s official intake process.'),
    boolean('residenceDocumentsReady', 'Is proof of residence ready?', 'Follow official instructions and obscure unnecessary account or Social Security numbers.'),
    { key: 'repairRequest', label: 'What repairs would you like RTP to consider?', kind: 'text', maxLength: 600,
      description: 'Describe observed issues and requested help. Avoid account numbers, diagnoses or unsupported structural claims.' },
  ],
};

export function intakeDefinition(programId: string): IntakeDefinition | null {
  if (!Object.hasOwn(questions, programId)) return null;
  const selected = structuredClone(questions[programId]) as IntakeQuestion[];
  return { programId, questionnaireVersion: createHash('sha256').update(canonicalJson({ programId, version: 'reported-preparation-2026-10-22-v1', questions: selected })).digest('hex'), questions: selected };
}
export class ProgramIntakeValidationError extends Error {
  constructor() { super('Invalid program preparation answers.'); this.name = 'ProgramIntakeValidationError'; }
}
function check(value: unknown): asserts value { if (!value) throw new ProgramIntakeValidationError(); }
function object(value: unknown, keys: string[]): Record<string, unknown> {
  check(value !== null && typeof value === 'object' && !Array.isArray(value));
  check(Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key)));
  return value as Record<string, unknown>;
}
export function parseIntakeAnswers(value: unknown, definition: IntakeDefinition): IntakeAnswer[] {
  check(Array.isArray(value) && value.length <= definition.questions.length);
  const seen = new Set<string>();
  const answers = value.map(raw => {
    const answer = object(raw, ['key', 'value', 'reviewState']);
    const field = definition.questions.find(field => field.key === answer.key);
    check(field !== undefined && !seen.has(field.key)); seen.add(field.key);
    check(answer.reviewState === 'reported' || answer.reviewState === 'unknown');
    if (answer.value === null) check(answer.reviewState === 'unknown');
    else {
      check(answer.reviewState === 'reported');
      if (field.kind === 'boolean') check(typeof answer.value === 'boolean');
      if (field.kind === 'money') check(typeof answer.value === 'number' && Number.isFinite(answer.value)
        && answer.value >= 0 && answer.value <= 100_000_000 && Math.abs(answer.value * 100 - Math.round(answer.value * 100)) < 0.00001);
      if (field.kind === 'text') check(typeof answer.value === 'string' && answer.value === answer.value.trim()
        && answer.value.length > 0 && [...answer.value].length <= field.maxLength!
        && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029\uD800-\uDFFF]/u.test(answer.value));
    }
    return { key: field.key, value: answer.value as IntakeAnswer['value'], reviewState: answer.reviewState as IntakeAnswer['reviewState'] };
  });
  return answers.sort((a, b) => definition.questions.findIndex(q => q.key === a.key) - definition.questions.findIndex(q => q.key === b.key));
}
export function parseSavedProgramIntake(value: unknown): SavedProgramIntake {
  const item = object(value, ['schemaVersion', 'caseId', 'caseRevision', 'programId', 'questionnaireVersion', 'intakeRevision', 'updatedAt', 'updatedBy', 'answers']);
  check(item.schemaVersion === '2' && evidenceIdentifier(item.caseId) && evidenceRevision(item.caseRevision)
    && evidenceIdentifier(item.programId) && evidenceIdentifier(item.updatedBy) && evidenceInstant(item.updatedAt)
    && evidenceRevision(item.intakeRevision) && typeof item.questionnaireVersion === 'string' && /^[a-f0-9]{64}$/.test(item.questionnaireVersion));
  const definition = intakeDefinition(item.programId);
  check(definition !== null);
  check(item.questionnaireVersion === definition.questionnaireVersion);
  return { ...structuredClone(item), answers: parseIntakeAnswers(item.answers, definition) } as unknown as SavedProgramIntake;
}
