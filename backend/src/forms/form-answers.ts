import { createHash } from 'node:crypto';
import { instantMicros } from '../packets.ts';
import type { CaseSnapshot } from '../types.ts';
import type { VerifiedFormTemplate } from './field-mapping.ts';

export const FORM_ANSWER_POLICY_VERSION = 'identity-contact-v1';
export const FORM_ANSWER_FIELDS = Object.freeze(([
  { key: 'memberFirstName', fieldName: 'First Name', semantic: 'identity', kind: 'text', maxLength: 160 },
  { key: 'memberLastName', fieldName: 'Last Name', semantic: 'identity', kind: 'text', maxLength: 160 },
  { key: 'memberBirthDate', fieldName: 'Date of Birth', semantic: 'identity', kind: 'date', maxLength: 10 },
  { key: 'memberId', fieldName: 'SCFHP Member ID', semantic: 'identity', kind: 'text', maxLength: 80 },
  { key: 'memberPhone', fieldName: 'Phone', semantic: 'contact', kind: 'text', maxLength: 40 },
  { key: 'memberPreferredSpokenLanguage', fieldName: 'Preferred Spoken Language', semantic: 'contact', kind: 'text', maxLength: 80 },
  { key: 'representativeName', fieldName: 'Authorized Representative Name', semantic: 'identity', kind: 'text', maxLength: 160 },
  { key: 'representativeEmail', fieldName: 'Email of Authorized Representative', semantic: 'contact', kind: 'email', maxLength: 254 },
  { key: 'representativePhone', fieldName: 'Authorized Representative Phone', semantic: 'contact', kind: 'text', maxLength: 40 },
  { key: 'referralDate', fieldName: 'Todays Date', semantic: 'request_detail', kind: 'date', maxLength: 10 },
  { key: 'referralSource', fieldName: 'Referral Source', semantic: 'request_detail', kind: 'text', maxLength: 200 },
  { key: 'referringOrganizationName', fieldName: 'Referring Entity Organization Name if applicable', semantic: 'identity', kind: 'text', maxLength: 200 },
  { key: 'referringOrganizationPhone', fieldName: 'Referring Entity Phone', semantic: 'contact', kind: 'text', maxLength: 40 },
  { key: 'referrerName', fieldName: 'Text1', semantic: 'identity', kind: 'text', maxLength: 160 },
  { key: 'referrerTitle', fieldName: 'Text2', semantic: 'identity', kind: 'text', maxLength: 100 },
  { key: 'referrerOrganizationName', fieldName: 'Referring Individual Entity Name', semantic: 'identity', kind: 'text', maxLength: 200 },
  { key: 'referrerEmail', fieldName: 'Text3', semantic: 'contact', kind: 'email', maxLength: 254 },
  { key: 'referrerPhone', fieldName: 'Text4', semantic: 'contact', kind: 'text', maxLength: 40 },
] as const).map(field => Object.freeze(field)));

export type FormAnswerKey = typeof FORM_ANSWER_FIELDS[number]['key'];
export interface FormAnswerInput { key: FormAnswerKey; value: string | null; reviewState: 'needs_review' | 'reviewed' }
export interface SavedFormAnswer extends FormAnswerInput { reviewedAt: string | null; reviewedBy: string | null }
export interface FormAnswerContext { programId: string; formVersion: string; mappingVersion: string; formContextId: string }
export interface SavedFormAnswerSet {
  schemaVersion: '1'; caseId: string; caseRevision: number; programId: string;
  formVersion: string; mappingVersion: string; formContextId: string; answerRevision: number;
  updatedAt: string; updatedBy: string; answers: SavedFormAnswer[];
}

export class FormAnswerValidationError extends Error {
  constructor() { super('Invalid reviewed form answers or context.'); this.name = 'FormAnswerValidationError'; }
}

function check(condition: unknown): asserts condition { if (!condition) throw new FormAnswerValidationError(); }
function object(value: unknown, keys: string[]): Record<string, unknown> {
  check(value !== null && typeof value === 'object' && !Array.isArray(value));
  const result = value as Record<string, unknown>;
  check(Object.keys(result).length === keys.length && Object.keys(result).every(key => keys.includes(key)));
  return result;
}
function text(value: unknown, maxLength: number): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value === value.trim()
    && [...value].length <= maxLength && !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(value)
    && !/[\uD800-\uDFFF]/u.test(value);
}
function date(value: string): boolean {
  if (value.length !== 10 || !/^\d{4}-\d{2}-\d{2}$/.test(value) || value.startsWith('0000')) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}
function positive(value: unknown): value is number { return Number.isSafeInteger(value) && Number(value) >= 1; }
function digest(value: unknown): value is string {
  return typeof value === 'string' && value.length === 64 && !/[^a-f0-9]/.test(value);
}
function instant(value: unknown): asserts value is string {
  check(typeof value === 'string');
  check(!value.startsWith('0000'));
  try { instantMicros(value); } catch { throw new FormAnswerValidationError(); }
}

export function parseFormAnswerInputs(input: unknown): FormAnswerInput[] {
  check(Array.isArray(input) && input.length <= FORM_ANSWER_FIELDS.length);
  const keys = new Set<string>();
  const answers = input.map(value => {
    const item = object(value, ['key', 'value', 'reviewState']);
    const field = FORM_ANSWER_FIELDS.find(field => field.key === item.key);
    check(field !== undefined && !keys.has(field.key)); keys.add(field.key);
    check(item.reviewState === 'needs_review' || item.reviewState === 'reviewed');
    check(item.value === null || text(item.value, field.maxLength));
    check(item.value !== null || item.reviewState === 'needs_review');
    if (typeof item.value === 'string') {
      if (field.kind === 'date') check(date(item.value));
      if (field.kind === 'email') check(/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(item.value));
    }
    return { key: field.key, value: item.value as string | null, reviewState: item.reviewState };
  });
  const birth = answers.find(answer => answer.key === 'memberBirthDate')?.value;
  const referral = answers.find(answer => answer.key === 'referralDate')?.value;
  if (birth && referral) check(birth <= referral);
  return answers.sort((a, b) => FORM_ANSWER_FIELDS.findIndex(field => field.key === a.key)
    - FORM_ANSWER_FIELDS.findIndex(field => field.key === b.key)) as FormAnswerInput[];
}

export function createFormAnswerContext(template: VerifiedFormTemplate): FormAnswerContext {
  return { programId: template.programId, formVersion: template.formVersion, mappingVersion: template.mappingVersion,
    formContextId: createHash('sha256').update(canonical({ template, policyVersion: FORM_ANSWER_POLICY_VERSION,
      answerFields: FORM_ANSWER_FIELDS })).digest('hex') };
}

export function validateAnswersForTemplate(answers: FormAnswerInput[], template: VerifiedFormTemplate): void {
  const supported = new Set(template.fields.flatMap(field => field.binding.kind === 'reviewed_answer' ? [field.binding.answerKey] : []));
  check(supported.size > 0 && answers.every(answer => supported.has(answer.key)));
}

export function parseSavedFormAnswers(input: unknown): SavedFormAnswerSet {
  const set = object(input, ['schemaVersion', 'caseId', 'caseRevision', 'programId', 'formVersion', 'mappingVersion',
    'formContextId', 'answerRevision', 'updatedAt', 'updatedBy', 'answers']);
  check(set.schemaVersion === '1' && text(set.caseId, 200) && positive(set.caseRevision) && text(set.programId, 200)
    && text(set.formVersion, 200) && text(set.mappingVersion, 200) && digest(set.formContextId)
    && positive(set.answerRevision) && text(set.updatedBy, 200));
  instant(set.updatedAt);
  check(Array.isArray(set.answers) && set.answers.length <= FORM_ANSWER_FIELDS.length);
  const rawAnswers = set.answers.map(value => object(value, ['key', 'value', 'reviewState', 'reviewedAt', 'reviewedBy']));
  const inputs = parseFormAnswerInputs(rawAnswers.map(({ key, value, reviewState }) => ({ key, value, reviewState })));
  const answers = inputs.map(answer => {
    const raw = rawAnswers.find(raw => raw.key === answer.key)!;
    if (answer.reviewState === 'reviewed') {
      instant(raw.reviewedAt); check(text(raw.reviewedBy, 200));
      check(instantMicros(raw.reviewedAt) <= instantMicros(set.updatedAt as string));
    } else check(raw.reviewedAt === null && raw.reviewedBy === null);
    if ((answer.key === 'memberBirthDate' || answer.key === 'referralDate') && answer.value !== null) {
      check(answer.value <= (set.updatedAt as string).slice(0, 10));
    }
    return { ...answer, reviewedAt: raw.reviewedAt as string | null, reviewedBy: raw.reviewedBy as string | null };
  });
  return { ...structuredClone(set), answers } as unknown as SavedFormAnswerSet;
}

export function createSavedFormAnswers(input: {
  snapshot: CaseSnapshot; context: FormAnswerContext; answerRevision: number;
  answers: FormAnswerInput[]; updatedAt: string; updatedBy: string;
}): SavedFormAnswerSet {
  const answers = parseFormAnswerInputs(input.answers).map(answer => ({ ...answer,
    reviewedAt: answer.reviewState === 'reviewed' ? input.updatedAt : null,
    reviewedBy: answer.reviewState === 'reviewed' ? input.updatedBy : null }));
  return parseSavedFormAnswers({ schemaVersion: '1', caseId: input.snapshot.caseId, caseRevision: input.snapshot.revision,
    ...input.context, answerRevision: input.answerRevision, updatedAt: input.updatedAt, updatedBy: input.updatedBy, answers });
}

export function formAnswersAreCurrent(saved: SavedFormAnswerSet, snapshot: Pick<CaseSnapshot, 'caseId' | 'revision'>,
  context: FormAnswerContext): boolean {
  return saved.caseId === snapshot.caseId && saved.caseRevision === snapshot.revision
    && saved.programId === context.programId && saved.formVersion === context.formVersion
    && saved.mappingVersion === context.mappingVersion && saved.formContextId === context.formContextId;
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record).sort().map(key => `${JSON.stringify(key)}:${canonical(record[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
