import type {
  CaseSnapshot, Check, CheckStatus, Criterion, EvaluationContext, MatchResponse,
  ProfileField, ProgramDefinition, ResolvedBy, Rule,
} from './types.ts';

const fieldTypes = {
  city: 'string', county: 'string', healthPlan: 'string', tenure: 'string',
  ageYears: 'number', householdSize: 'number', annualIncomeUsd: 'number',
  ownerConsentReported: 'boolean',
} as const;
const fieldNames = Object.keys(fieldTypes) as ProfileField[];
const resolvers = ['resident', 'program', 'professional'];

export class InputValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InputValidationError';
  }
}

function requireCondition(condition: unknown, message: string): asserts condition {
  if (!condition) throw new InputValidationError(message);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function text(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

function stringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every(text) && new Set(value).size === value.length;
}

function httpsUrl(value: unknown): value is string {
  if (typeof value !== 'string' || !value.startsWith('https://') || /[\s\\]/.test(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname.length > 0;
  } catch {
    return false;
  }
}

function onlyKeys(value: Record<string, unknown>, keys: readonly string[], path: string): void {
  requireCondition(Object.keys(value).every(key => keys.includes(key)), `${path} contains an unsupported property.`);
}

function validDate(value: unknown): value is string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

function validInstant(value: unknown): value is string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/.test(value)) return false;
  const parsed = new Date(value);
  const fraction = value.match(/\.(\d+)Z$/)?.[1] ?? '';
  const normalized = `${value.slice(0, 19)}.${fraction.padEnd(3, '0').slice(0, 3)}Z`;
  return Number.isFinite(parsed.getTime()) && parsed.toISOString() === normalized;
}

function instantMicros(value: string): bigint {
  const fraction = value.match(/\.(\d+)Z$/)?.[1] ?? '';
  return BigInt(Date.parse(value)) * 1_000n + BigInt(fraction.padEnd(6, '0').slice(3, 6));
}

function nullableDate(value: unknown): boolean {
  return value === null || validDate(value);
}

function validWindow(record: Record<string, unknown>): boolean {
  return nullableDate(record.effectiveFrom) && nullableDate(record.effectiveUntil)
    && !(typeof record.effectiveFrom === 'string' && typeof record.effectiveUntil === 'string' && record.effectiveFrom > record.effectiveUntil);
}

function assertCase(value: unknown): asserts value is CaseSnapshot {
  requireCondition(isRecord(value), 'Case must be an object.');
  onlyKeys(value, ['schemaVersion', 'caseId', 'revision', 'profile', 'unresolvedFields', 'findings'], 'Case');
  requireCondition(value.schemaVersion === '1', 'Unsupported case schemaVersion.');
  requireCondition(text(value.caseId), 'caseId must be nonempty.');
  requireCondition(Number.isSafeInteger(value.revision) && Number(value.revision) >= 1, 'revision must be a positive safe integer.');
  requireCondition(isRecord(value.profile), 'profile must be an object.');
  onlyKeys(value.profile, fieldNames, 'profile');
  for (const field of fieldNames) {
    const answer = value.profile[field];
    requireCondition(answer === null || typeof answer === fieldTypes[field], `profile.${field} has an invalid type; use null for unknown.`);
    if (typeof answer === 'string') requireCondition(text(answer), `profile.${field} must be nonblank or null.`);
    if (typeof answer === 'number') {
      requireCondition(Number.isFinite(answer), `profile.${field} must be finite.`);
      if (field !== 'annualIncomeUsd') requireCondition(Number.isSafeInteger(answer) && answer >= 0, `profile.${field} must be a nonnegative integer.`);
      if (field === 'householdSize') requireCondition(answer >= 1, 'householdSize must be at least one or null.');
    }
    if (field === 'tenure') requireCondition(answer === null || answer === 'owner' || answer === 'renter', 'tenure must be owner, renter, or null.');
  }
  requireCondition(stringArray(value.unresolvedFields), 'unresolvedFields must be an array of nonempty field paths.');
  requireCondition(Array.isArray(value.findings) && value.findings.every(isRecord), 'findings must be an array of objects.');
  const findingIds = new Set<string>();
  for (const finding of value.findings) {
    onlyKeys(finding, ['id', 'room', 'observation', 'reviewState', 'evidenceIds', 'measurements'], 'Finding');
    requireCondition(text(finding.id) && !findingIds.has(finding.id), 'Finding IDs must be nonempty and unique.');
    findingIds.add(finding.id);
    requireCondition(typeof finding.room === 'string' && ['bathroom', 'entrance', 'other'].includes(finding.room), 'Invalid finding room.');
    requireCondition(text(finding.observation), 'Finding observation must be nonempty.');
    requireCondition(typeof finding.reviewState === 'string' && ['confirmed', 'needs_review', 'dismissed'].includes(finding.reviewState), 'Invalid finding reviewState.');
    requireCondition(stringArray(finding.evidenceIds), 'evidenceIds must be an array of nonempty strings.');
    requireCondition(Array.isArray(finding.measurements), 'measurements must be an array.');
    for (const measurement of finding.measurements) {
      requireCondition(isRecord(measurement), 'Measurement must be an object.');
      onlyKeys(measurement, ['type', 'value', 'unit', 'method', 'confirmed'], 'Measurement');
      requireCondition(text(measurement.type), 'Measurement type must be nonempty.');
      requireCondition(typeof measurement.value === 'number' && Number.isFinite(measurement.value) && measurement.value >= 0, 'Measurement value must be finite and nonnegative.');
      requireCondition(measurement.unit === 'mm', 'Measurement unit must be mm.');
      requireCondition(measurement.method === 'manual' || measurement.method === 'estimated', 'Invalid measurement method.');
      requireCondition(typeof measurement.confirmed === 'boolean', 'Measurement confirmed must be a boolean.');
    }
  }
}

function assertContext(value: unknown): asserts value is EvaluationContext {
  requireCondition(isRecord(value), 'Evaluation context must be an object.');
  onlyKeys(value, ['evaluatedAt', 'evaluationDate'], 'Evaluation context');
  requireCondition(validInstant(value.evaluatedAt), 'evaluatedAt must be an ISO UTC timestamp ending in Z.');
  requireCondition(validDate(value.evaluationDate), 'evaluationDate must be a real YYYY-MM-DD date.');
  requireCondition(value.evaluatedAt.slice(0, 10) === value.evaluationDate, 'evaluationDate must match the UTC date of evaluatedAt.');
}

function assertRule(value: unknown, sourceIds: Set<string>, depth = 0): asserts value is Rule {
  requireCondition(depth < 20 && isRecord(value), 'Rule must be an object with nesting below 20 levels.');
  if (value.kind === 'and' || value.kind === 'or') {
    onlyKeys(value, ['kind', 'rules'], 'Rule group');
    requireCondition(Array.isArray(value.rules) && value.rules.length > 0, 'Rule groups must not be empty.');
    value.rules.forEach(rule => assertRule(rule, sourceIds, depth + 1));
    return;
  }
  requireCondition(value.kind === 'eq' || value.kind === 'gte' || value.kind === 'lte' || value.kind === 'manual_review', 'Unsupported rule kind.');
  if (value.kind === 'manual_review') {
    onlyKeys(value, ['kind', 'reason', 'sourceIds', 'resolvedBy'], 'Manual review rule');
    requireCondition(text(value.reason), 'Manual review rules require a nonblank reason.');
  } else {
    onlyKeys(value, ['kind', 'field', 'value', 'sourceIds', 'resolvedBy'], 'Rule');
    requireCondition(typeof value.field === 'string' && fieldNames.includes(value.field as ProfileField), 'Unsupported profile field.');
    const field = value.field as ProfileField;
    requireCondition(typeof value.value === fieldTypes[field], `Rule value type must match ${field}.`);
    requireCondition(value.kind === 'eq' || fieldTypes[field] === 'number', 'Range comparisons require numeric fields.');
    requireCondition(typeof value.value !== 'number' || Number.isFinite(value.value), 'Rule numeric values must be finite.');
    requireCondition(typeof value.value !== 'string' || text(value.value), 'Rule strings must not be empty.');
    requireCondition(field !== 'tenure' || value.value === 'owner' || value.value === 'renter', 'Invalid tenure rule value.');
  }
  requireCondition(stringArray(value.sourceIds), 'Rule sourceIds must be an array.');
  requireCondition(value.sourceIds.every(id => sourceIds.has(id)), 'Rule references an unknown source ID.');
  requireCondition(typeof value.resolvedBy === 'string' && resolvers.includes(value.resolvedBy), 'Rule must name who can resolve missing facts.');
}

function assertRegistry(value: unknown): asserts value is ProgramDefinition[] {
  requireCondition(Array.isArray(value), 'Registry must be an array.');
  const programIds = new Set<string>();
  for (const program of value) {
    requireCondition(isRecord(program), 'Program must be an object.');
    onlyKeys(program, ['programId', 'programName', 'ruleVersion', 'isDemo', 'availability', 'rulesVerified', 'reviewedOn', 'effectiveFrom', 'effectiveUntil', 'recheckAfter', 'criteria', 'sources', 'requiredDocuments', 'intake'], 'Program');
    requireCondition(text(program.programId) && !programIds.has(program.programId), 'Program IDs must be nonempty and unique.');
    programIds.add(program.programId);
    requireCondition(text(program.programName) && text(program.ruleVersion), 'Program name and ruleVersion are required.');
    requireCondition(typeof program.isDemo === 'boolean' && typeof program.rulesVerified === 'boolean', 'isDemo and rulesVerified must be booleans.');
    requireCondition(typeof program.availability === 'string' && ['unverified', 'accepting', 'not_accepting'].includes(program.availability), 'Invalid availability.');
    requireCondition(nullableDate(program.reviewedOn) && validWindow(program), 'Invalid program review/effective dates.');
    requireCondition(program.recheckAfter === null || validInstant(program.recheckAfter), 'Invalid recheckAfter timestamp.');
    requireCondition(stringArray(program.requiredDocuments), 'requiredDocuments must be an array.');
    requireCondition(program.intake === null || text(program.intake), 'intake must be nonempty text or null.');
    requireCondition(Array.isArray(program.sources), 'sources must be an array.');
    const sourceIds = new Set<string>();
    for (const source of program.sources) {
      requireCondition(isRecord(source) && text(source.id) && !sourceIds.has(source.id), 'Source IDs must be nonempty and unique.');
      onlyKeys(source, ['id', 'url', 'title', 'reviewedOn', 'effectiveFrom', 'effectiveUntil'], 'Source');
      sourceIds.add(source.id);
      requireCondition(text(source.title) && httpsUrl(source.url), 'Sources need titles and valid HTTPS URLs without whitespace.');
      requireCondition(validDate(source.reviewedOn) && validWindow(source), 'Invalid source review/effective dates.');
    }
    requireCondition(Array.isArray(program.criteria) && program.criteria.length > 0, 'Programs must have at least one criterion.');
    const checkIds = new Set<string>();
    for (const criterion of program.criteria) {
      requireCondition(isRecord(criterion) && text(criterion.id) && !checkIds.has(criterion.id) && text(criterion.label), 'Criterion IDs must be unique with a nonempty label.');
      onlyKeys(criterion, ['id', 'label', 'rule', 'exception'], 'Criterion');
      checkIds.add(criterion.id);
      assertRule(criterion.rule, sourceIds);
      if (criterion.exception !== undefined) assertRule(criterion.exception, sourceIds);
    }
  }
}

interface Result {
  status: CheckStatus;
  reasonCode: string;
  missingFields: string[];
  resolvers: ResolvedBy[];
  sourceIds: string[];
  manualReviews: string[];
}

function unique<T>(items: T[]): T[] { return [...new Set(items)]; }

function leafSources(rule: Rule): string[] {
  return rule.kind === 'and' || rule.kind === 'or' ? unique(rule.rules.flatMap(leafSources)) : rule.sourceIds;
}

function allLeavesSourced(rule: Rule): boolean {
  return rule.kind === 'and' || rule.kind === 'or' ? rule.rules.every(allLeavesSourced) : rule.sourceIds.length > 0;
}

function manualReviewDescriptions(rule: Rule): string[] {
  if (rule.kind === 'and' || rule.kind === 'or') return unique(rule.rules.flatMap(manualReviewDescriptions));
  return rule.kind === 'manual_review' ? [`Manual review (${rule.resolvedBy}): ${rule.reason}`] : [];
}

function combine(kind: 'and' | 'or', results: Result[]): Result {
  const statuses = results.map(result => result.status);
  const status: CheckStatus = kind === 'and'
    ? statuses.includes('fail') ? 'fail' : statuses.includes('unknown') ? 'unknown' : 'pass'
    : statuses.includes('pass') ? 'pass' : statuses.includes('unknown') ? 'unknown' : 'fail';
  const relevant = kind === 'or' && status === 'pass' ? results.filter(result => result.status === 'pass') : results;
  return {
    status, reasonCode: `${kind}_${status}`,
    missingFields: unique(relevant.flatMap(result => result.missingFields)),
    resolvers: unique(relevant.flatMap(result => result.resolvers)),
    sourceIds: unique(results.flatMap(result => result.sourceIds)),
    manualReviews: unique(relevant.flatMap(result => result.manualReviews)),
  };
}

function evaluateRule(rule: Rule, snapshot: CaseSnapshot): Result {
  if (rule.kind === 'and' || rule.kind === 'or') return combine(rule.kind, rule.rules.map(child => evaluateRule(child, snapshot)));
  if (rule.kind === 'manual_review') return {
    status: 'unknown', reasonCode: 'manual_review_required', missingFields: [],
    resolvers: [rule.resolvedBy], sourceIds: [...rule.sourceIds], manualReviews: manualReviewDescriptions(rule),
  };
  const path = `profile.${rule.field}`;
  const value = snapshot.profile[rule.field];
  const conflicting = snapshot.unresolvedFields.some(field => field === path || field === rule.field || field === 'profile');
  if (conflicting || value === null) {
    return { status: 'unknown', reasonCode: conflicting ? 'unresolved_input' : 'missing_input', missingFields: [path], resolvers: [rule.resolvedBy], sourceIds: [...rule.sourceIds], manualReviews: [] };
  }
  const passed = rule.kind === 'eq' ? value === rule.value : rule.kind === 'gte' ? Number(value) >= rule.value : Number(value) <= rule.value;
  return { status: passed ? 'pass' : 'fail', reasonCode: passed ? 'criterion_satisfied' : 'criterion_not_satisfied', missingFields: [], resolvers: [], sourceIds: [...rule.sourceIds], manualReviews: [] };
}

function freshnessIssue(program: ProgramDefinition, context: EvaluationContext): string | null {
  const day = context.evaluationDate;
  if (program.effectiveFrom !== null && day < program.effectiveFrom) return 'rules_not_yet_effective';
  if (program.effectiveUntil !== null && day > program.effectiveUntil) return 'rules_expired';
  if (program.recheckAfter !== null && instantMicros(context.evaluatedAt) >= instantMicros(program.recheckAfter)) return 'rules_recheck_due';
  if (program.reviewedOn !== null && program.reviewedOn > day) return 'future_review_date';
  if (!program.isDemo && (!program.rulesVerified || program.reviewedOn === null || program.sources.length === 0 || program.recheckAfter === null)) return 'rules_unverified';
  if (!program.isDemo && program.criteria.some(criterion => !allLeavesSourced(criterion.rule) || (criterion.exception && !allLeavesSourced(criterion.exception)))) return 'rule_source_missing';
  if (program.sources.some(source => source.reviewedOn > day || (source.effectiveFrom !== null && day < source.effectiveFrom) || (source.effectiveUntil !== null && day > source.effectiveUntil))) return 'source_not_current';
  return null;
}

function recheckBoundary(program: ProgramDefinition, context: EvaluationContext): string | null {
  if (program.recheckAfter === null) return null;
  const boundaries = [program.recheckAfter];
  for (const window of [program, ...program.sources]) {
    if (window.effectiveFrom !== null && context.evaluationDate < window.effectiveFrom) {
      boundaries.push(`${window.effectiveFrom}T00:00:00Z`);
    }
    if (window.effectiveUntil !== null) {
      boundaries.push(new Date(Date.parse(`${window.effectiveUntil}T00:00:00Z`) + 86_400_000).toISOString());
    }
  }
  return boundaries.reduce((earliest, boundary) => instantMicros(boundary) < instantMicros(earliest) ? boundary : earliest);
}

function evaluateCriterion(criterion: Criterion, snapshot: CaseSnapshot, freshness: string | null): Check {
  const sources = unique([...leafSources(criterion.rule), ...(criterion.exception ? leafSources(criterion.exception) : [])]);
  if (freshness !== null) {
    const reviews = unique([...manualReviewDescriptions(criterion.rule), ...(criterion.exception ? manualReviewDescriptions(criterion.exception) : [])]);
    return {
      id: criterion.id, status: 'unknown', reasonCode: freshness,
      explanation: [`${criterion.label}: current program rules need verification before this check can be used.`, ...reviews].join(' '),
      missingFields: [], resolvedBy: 'program', sourceIds: sources,
    };
  }
  let result = evaluateRule(criterion.rule, snapshot);
  if (criterion.exception && result.status !== 'pass') {
    const exception = evaluateRule(criterion.exception, snapshot);
    result = combine('or', [result, exception]);
    result.reasonCode = exception.status === 'pass' ? 'exception_satisfied' : result.status === 'unknown' ? 'criterion_or_exception_unresolved' : 'criterion_and_exception_failed';
  }
  const explanation = result.status === 'pass'
    ? result.reasonCode === 'exception_satisfied' ? 'A documented exception satisfies this requirement.' : 'The supplied answers satisfy this coded requirement.'
    : result.status === 'fail' ? 'The supplied answers do not satisfy this requirement or any applicable coded alternative.'
      : result.reasonCode === 'manual_review_required' ? 'A manual review is required; this check has not been decided.'
        : 'Information needed to resolve this requirement or its alternatives is missing or conflicting.';
  return {
    id: criterion.id, status: result.status, reasonCode: result.reasonCode,
    explanation: [`${criterion.label}: ${explanation}`, ...result.manualReviews].join(' '),
    missingFields: result.missingFields, resolvedBy: result.resolvers.length === 1 ? result.resolvers[0] : null,
    sourceIds: sources,
  };
}

export function matchPrograms(snapshot: unknown, registry: unknown, context: unknown): MatchResponse {
  assertCase(snapshot);
  assertContext(context);
  assertRegistry(registry);
  return {
    schemaVersion: '1', caseId: snapshot.caseId, caseRevision: snapshot.revision,
    evaluatedAt: context.evaluatedAt, evaluationDate: context.evaluationDate,
    matches: registry.map(program => {
      const checks = program.criteria.map(criterion => evaluateCriterion(criterion, snapshot, freshnessIssue(program, context)));
      return {
        programId: program.programId, programName: program.programName, ruleVersion: program.ruleVersion,
        isDemo: program.isDemo, availability: program.availability, recheckAfter: recheckBoundary(program, context),
        status: checks.some(check => check.status === 'fail') ? 'does_not_meet_criterion' : checks.some(check => check.status === 'unknown') ? 'needs_confirmation' : 'meets_known_criteria',
        checks, sources: program.sources.map(source => ({ ...source })),
        requiredDocuments: [...program.requiredDocuments], intake: program.intake,
      };
    }),
  };
}
