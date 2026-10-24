import { instantMicros } from '../packets.ts';
import type { CaseSnapshot, ResolvedBy } from '../types.ts';
import { createFormAnswerContext, FORM_ANSWER_FIELDS, formAnswersAreCurrent, parseSavedFormAnswers,
  validateAnswersForTemplate, type FormAnswerKey } from './form-answers.ts';

export type PdfFieldType = 'Tx' | 'Btn' | 'Sig' | 'Ch';
export type FieldSemantic = 'routing' | 'identity' | 'contact' | 'clinical'
  | 'consent' | 'signature' | 'request_detail' | 'layout';
export type ManualReason = 'not_collected' | 'clinical_review' | 'consent_review'
  | 'signature_review' | 'program_review' | 'layout_only' | 'out_of_scope';
export type FieldDecisionStatus = 'mapped' | 'missing' | 'requires_review' | 'not_applicable';

export interface FormWidget {
  readonly page: number;
  readonly rect: readonly [number, number, number, number];
  readonly exportValue: string | null;
}

export type FieldBinding =
  | { readonly kind: 'routing'; readonly programId: string; readonly widgetIndex: number; readonly value: string }
  | { readonly kind: 'reviewed_answer'; readonly answerKey: FormAnswerKey }
  | { readonly kind: 'manual'; readonly reason: ManualReason; readonly resolvedBy: ResolvedBy };

export interface FormFieldDefinition {
  readonly fieldName: string;
  readonly label: string;
  readonly pdfType: PdfFieldType;
  readonly widgets: readonly FormWidget[];
  readonly semantic: FieldSemantic;
  readonly required: boolean;
  readonly maxLength: number | null;
  readonly binding: FieldBinding;
}

export interface VerifiedFormTemplate {
  readonly schemaVersion: '1';
  readonly programId: string;
  readonly formVersion: string;
  readonly mappingVersion: string;
  readonly templateSha256: string;
  readonly publisherRevision: string | null;
  readonly sourceUrl: string;
  readonly sourcePageUrl: string;
  readonly reviewedOn: string;
  readonly pageCount: number;
  readonly fields: readonly FormFieldDefinition[];
}

export type FieldOrigin = {
  readonly kind: 'verified_program_routing';
  readonly programId: string;
  readonly sourceUrl: string;
  readonly reviewedOn: string;
  readonly templateSha256: string;
  readonly mappingVersion: string;
} | {
  readonly kind: 'reviewed_form_answer';
  readonly answerKey: FormAnswerKey;
  readonly sourceValue: string;
  readonly answerRevision: number;
  readonly reviewedBy: string;
  readonly reviewedAt: string;
  readonly formContextId: string;
  readonly valueTransform: 'identity' | 'iso_date_to_mm_dd_yyyy';
};

export interface FormFieldDecision {
  readonly fieldName: string;
  readonly label: string;
  readonly pdfType: PdfFieldType;
  readonly widgets: readonly FormWidget[];
  readonly semantic: FieldSemantic;
  readonly required: boolean;
  readonly maxLength: number | null;
  readonly status: FieldDecisionStatus;
  readonly value: string | null;
  readonly widgetValues: readonly (string | null)[];
  readonly origin: FieldOrigin | null;
  readonly reasonCode: 'ROUTING_SELECTED' | 'REVIEWED_ANSWER' | 'ANSWER_NOT_COLLECTED' | 'ANSWER_NEEDS_REVIEW' | Uppercase<ManualReason>;
  readonly resolvedBy: ResolvedBy | null;
}

export interface FormPreparationPlan {
  readonly schemaVersion: '1';
  readonly status: 'draft';
  readonly caseId: string;
  readonly caseRevision: number;
  readonly programId: string;
  readonly formVersion: string;
  readonly mappingVersion: string;
  readonly templateSha256: string;
  readonly publisherRevision: string | null;
  readonly sourceUrl: string;
  readonly sourcePageUrl: string;
  readonly reviewedOn: string;
  readonly plannedAt: string;
  readonly fields: readonly FormFieldDecision[];
  readonly summary: Readonly<{ mapped: number; missing: number; requiresReview: number; notApplicable: number }>;
}

export interface FormPlanningContext {
  readonly programId: string;
  readonly templateSha256: string;
  readonly plannedAt: string;
}

export class FormMappingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FormMappingError';
  }
}

const semantics: readonly FieldSemantic[] = [
  'routing', 'identity', 'contact', 'clinical', 'consent', 'signature', 'request_detail', 'layout',
];
const reasons: readonly ManualReason[] = [
  'not_collected', 'clinical_review', 'consent_review', 'signature_review', 'program_review', 'layout_only', 'out_of_scope',
];
const resolvers: readonly ResolvedBy[] = ['resident', 'program', 'professional'];

export function defineVerifiedFormTemplate(input: unknown): VerifiedFormTemplate {
  const template = record(input, ['schemaVersion', 'programId', 'formVersion', 'mappingVersion',
    'templateSha256', 'publisherRevision', 'sourceUrl', 'sourcePageUrl', 'reviewedOn', 'pageCount', 'fields']);
  requireCondition(template.schemaVersion === '1', 'Unsupported form-template schema.');
  requireCondition(identifier(template.programId) && text(template.mappingVersion, 200), 'Invalid template identity.');
  requireCondition(digest(template.templateSha256)
    && template.formVersion === `sha256:${template.templateSha256}`, 'Form version must identify the exact PDF content hash.');
  requireCondition(template.publisherRevision === null || text(template.publisherRevision, 200), 'Invalid publisher revision.');
  requireCondition(httpsUrl(template.sourceUrl) && httpsUrl(template.sourcePageUrl), 'Official source references must be HTTPS URLs.');
  requireCondition(date(template.reviewedOn), 'Invalid template review date.');
  requireCondition(Number.isSafeInteger(template.pageCount) && Number(template.pageCount) >= 1
    && Number(template.pageCount) <= 100, 'Invalid template page count.');
  requireCondition(Array.isArray(template.fields) && template.fields.length > 0 && template.fields.length <= 500,
    'Template must contain a bounded, nonempty field inventory.');
  const names = new Set<string>();
  let widgetCount = 0;
  for (const value of template.fields) {
    const field = record(value, ['fieldName', 'label', 'pdfType', 'widgets', 'semantic', 'required', 'maxLength', 'binding']);
    requireCondition(text(field.fieldName, 1024) && !names.has(field.fieldName), 'Field names must be nonblank and unique.');
    names.add(field.fieldName);
    requireCondition(text(field.label, 2000), 'A bounded, reviewed field label is required.');
    requireCondition(typeof field.pdfType === 'string' && ['Tx', 'Btn', 'Sig', 'Ch'].includes(field.pdfType), 'Unsupported PDF field type.');
    requireCondition(semantics.includes(field.semantic as FieldSemantic), 'Unsupported field semantic.');
    requireCondition(typeof field.required === 'boolean', 'Invalid PDF required flag.');
    requireCondition(field.maxLength === null || (Number.isSafeInteger(field.maxLength)
      && Number(field.maxLength) >= 1 && Number(field.maxLength) <= 100_000), 'Invalid PDF text limit.');
    requireCondition(Array.isArray(field.widgets) && field.widgets.length > 0 && field.widgets.length <= 100,
      'A field needs a bounded, nonempty widget inventory.');
    widgetCount += field.widgets.length;
    requireCondition(widgetCount <= 1000, 'Template widget inventory exceeds the supported limit.');
    const widgetLocations = new Set<string>();
    for (const value of field.widgets) {
      const widget = record(value, ['page', 'rect', 'exportValue']);
      requireCondition(Number.isSafeInteger(widget.page) && Number(widget.page) >= 1
        && Number(widget.page) <= Number(template.pageCount), 'Widget page is outside the template.');
      requireCondition(Array.isArray(widget.rect) && widget.rect.length === 4
        && widget.rect.every(value => typeof value === 'number' && Number.isFinite(value) && Math.abs(value) <= 10_000)
        && widget.rect[0] < widget.rect[2] && widget.rect[1] < widget.rect[3], 'Invalid widget rectangle.');
      const location = JSON.stringify([widget.page, widget.rect]);
      requireCondition(!widgetLocations.has(location), 'Duplicate physical widget.');
      widgetLocations.add(location);
      requireCondition(field.pdfType === 'Btn'
        ? text(widget.exportValue, 128) && widget.exportValue !== 'Off' && !/[\s/]/.test(widget.exportValue)
        : widget.exportValue === null, 'Invalid widget active appearance value.');
    }
    const binding = field.binding;
    requireCondition(isRecord(binding), 'Field binding must be an object.');
    if (binding.kind === 'routing') {
      record(binding, ['kind', 'programId', 'widgetIndex', 'value']);
      requireCondition(field.pdfType === 'Btn' && field.semantic === 'routing', 'Only routing buttons may be automatically selected.');
      requireCondition(binding.programId === template.programId, 'Routing binding targets another program.');
      requireCondition(Number.isSafeInteger(binding.widgetIndex) && Number(binding.widgetIndex) >= 0
        && Number(binding.widgetIndex) < field.widgets.length, 'Invalid routing widget index.');
      requireCondition(binding.value === (field.widgets[Number(binding.widgetIndex)] as Record<string, unknown>).exportValue,
        'Routing selection must use the reviewed widget appearance value.');
    } else if (binding.kind === 'reviewed_answer') {
      record(binding, ['kind', 'answerKey']);
      const allowed = FORM_ANSWER_FIELDS.find(item => item.key === binding.answerKey);
      requireCondition(allowed !== undefined && field.pdfType === 'Tx'
        && field.fieldName === allowed.fieldName && field.semantic === allowed.semantic,
      'Reviewed answers require an explicitly allowed text field and semantic.');
    } else {
      record(binding, ['kind', 'reason', 'resolvedBy']);
      requireCondition(binding.kind === 'manual' && reasons.includes(binding.reason as ManualReason)
        && resolvers.includes(binding.resolvedBy as ResolvedBy), 'Unsupported manual binding.');
      validateManualSemantic(field.semantic as FieldSemantic, binding.reason as ManualReason, binding.resolvedBy as ResolvedBy);
    }
    requireCondition(field.pdfType !== 'Sig' || (field.semantic === 'signature'
      && binding.kind === 'manual' && binding.reason === 'signature_review'), 'Digital signature fields always require manual signature review.');
  }
  return freeze(structuredClone(input) as VerifiedFormTemplate);
}

export function planFormFields(
  snapshot: CaseSnapshot,
  templateInput: VerifiedFormTemplate,
  context: FormPlanningContext,
  answersInput?: unknown,
): FormPreparationPlan {
  requireCondition(isRecord(snapshot) && snapshot.schemaVersion === '1' && identifier(snapshot.caseId)
    && Number.isSafeInteger(snapshot.revision) && snapshot.revision >= 1, 'A valid case identity and revision are required.');
  const template = defineVerifiedFormTemplate(templateInput);
  record(context, ['programId', 'templateSha256', 'plannedAt']);
  requireCondition(context.programId === template.programId, 'Selected program does not match the form template.');
  requireCondition(digest(context.templateSha256) && context.templateSha256 === template.templateSha256,
    'Loaded PDF bytes do not match the reviewed template.');
  try {
    instantMicros(context.plannedAt);
  } catch {
    throw new FormMappingError('Invalid form-planning timestamp.');
  }
  requireCondition(context.plannedAt.slice(0, 10) >= template.reviewedOn, 'Form planning predates the template review.');
  const answers = answersInput === undefined || answersInput === null ? null : parseSavedFormAnswers(answersInput);
  if (answers !== null) {
    requireCondition(formAnswersAreCurrent(answers, snapshot, createFormAnswerContext(template)),
      'Form answers must be reviewed for the current case and form context.');
    requireCondition(instantMicros(answers.updatedAt) <= instantMicros(context.plannedAt),
      'Form planning predates the saved answers.');
    validateAnswersForTemplate(answers.answers, template);
  }
  const fields: FormFieldDecision[] = template.fields.map(field => {
    const common = { fieldName: field.fieldName, label: field.label, pdfType: field.pdfType,
      widgets: field.widgets, semantic: field.semantic, required: field.required, maxLength: field.maxLength };
    if (field.binding.kind === 'routing') {
      const binding = field.binding;
      return { ...common, status: 'mapped', value: binding.value,
        widgetValues: field.widgets.map((_, index) => index === binding.widgetIndex ? binding.value : 'Off'),
        origin: { kind: 'verified_program_routing', programId: template.programId, sourceUrl: template.sourceUrl,
          reviewedOn: template.reviewedOn, templateSha256: template.templateSha256, mappingVersion: template.mappingVersion },
        reasonCode: 'ROUTING_SELECTED', resolvedBy: null };
    }
    if (field.binding.kind === 'reviewed_answer') {
      const key = field.binding.answerKey;
      const answer = answers?.answers.find(item => item.key === key);
      if (answer?.reviewState === 'reviewed' && answer.value !== null) {
        const isDate = FORM_ANSWER_FIELDS.find(item => item.key === key)!.kind === 'date';
        const value = isDate ? `${answer.value.slice(5, 7)}/${answer.value.slice(8, 10)}/${answer.value.slice(0, 4)}` : answer.value;
        requireCondition(field.maxLength === null || [...value].length <= field.maxLength,
          'A reviewed answer exceeds the declared PDF character limit.');
        return { ...common, status: 'mapped', value, widgetValues: field.widgets.map(() => null),
          origin: { kind: 'reviewed_form_answer', answerKey: key, sourceValue: answer.value,
            answerRevision: answers!.answerRevision, reviewedBy: answer.reviewedBy!, reviewedAt: answer.reviewedAt!,
            formContextId: answers!.formContextId, valueTransform: isDate ? 'iso_date_to_mm_dd_yyyy' : 'identity' },
          reasonCode: 'REVIEWED_ANSWER', resolvedBy: null };
      }
      return { ...common, status: answer?.value ? 'requires_review' : 'missing', value: null,
        widgetValues: field.widgets.map(() => null), origin: null,
        reasonCode: answer?.value ? 'ANSWER_NEEDS_REVIEW' : 'ANSWER_NOT_COLLECTED', resolvedBy: 'resident' };
    }
    const reason = field.binding.reason;
    const status = reason === 'layout_only' || reason === 'out_of_scope' ? 'not_applicable'
      : reason === 'not_collected' ? 'missing' : 'requires_review';
    return { ...common, status, value: null, widgetValues: field.widgets.map(() => null), origin: null,
      reasonCode: reason.toUpperCase() as Uppercase<ManualReason>,
      resolvedBy: status === 'not_applicable' ? null : field.binding.resolvedBy };
  });
  return freeze({ schemaVersion: '1', status: 'draft', caseId: snapshot.caseId, caseRevision: snapshot.revision,
    programId: template.programId, formVersion: template.formVersion, mappingVersion: template.mappingVersion,
    templateSha256: template.templateSha256, publisherRevision: template.publisherRevision,
    sourceUrl: template.sourceUrl, sourcePageUrl: template.sourcePageUrl, reviewedOn: template.reviewedOn,
    plannedAt: context.plannedAt, fields, summary: {
      mapped: fields.filter(field => field.status === 'mapped').length,
      missing: fields.filter(field => field.status === 'missing').length,
      requiresReview: fields.filter(field => field.status === 'requires_review').length,
      notApplicable: fields.filter(field => field.status === 'not_applicable').length,
    } });
}

function validateManualSemantic(semantic: FieldSemantic, reason: ManualReason, resolvedBy: ResolvedBy): void {
  if (semantic === 'layout' || reason === 'layout_only') {
    requireCondition(semantic === 'layout' && reason === 'layout_only', 'Layout widgets must remain blank.');
  }
  if (reason === 'out_of_scope') {
    requireCondition(semantic === 'clinical' || semantic === 'request_detail', 'Only reviewed unrelated questions may be out of scope.');
    return;
  }
  if (semantic === 'signature') requireCondition(reason === 'signature_review', 'Signature answers must remain manual.');
  if (semantic === 'consent') requireCondition(reason === 'consent_review', 'Consent answers must remain manual.');
  if (semantic === 'clinical') requireCondition(reason === 'clinical_review' && resolvedBy === 'professional', 'Clinical answers require professional review.');
}

function requireCondition(condition: unknown, message: string): asserts condition {
  if (!condition) throw new FormMappingError(message);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function record(value: unknown, keys: readonly string[]): Record<string, unknown> {
  requireCondition(isRecord(value) && Object.keys(value).length === keys.length
    && Object.keys(value).every(key => keys.includes(key)), 'Form configuration contains missing or unsupported fields.');
  return value;
}

function text(value: unknown, limit: number): value is string {
  return typeof value === 'string' && value.trim().length > 0 && [...value].length <= limit
    && !/[\u0000-\u001f\u007f]/.test(value);
}

function identifier(value: unknown): value is string {
  if (!text(value, 200)) return false;
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(++index);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false;
  }
  return true;
}

function digest(value: unknown): value is string {
  return typeof value === 'string' && value.length === 64 && !/[^a-f0-9]/.test(value);
}

function date(value: unknown): value is string {
  if (typeof value !== 'string' || value.length !== 10 || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function httpsUrl(value: unknown): value is string {
  if (!text(value, 2048) || /\s|\\/.test(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname.length > 0 && !url.username && !url.password && !url.hash;
  } catch { return false; }
}

function freeze<T>(value: T): T {
  if (value !== null && typeof value === 'object') {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}
