import { matchPrograms } from '../matcher.ts';
import { evidenceIdentifier, evidenceRevision } from '../evidence/validation.ts';
import type { CaseSnapshot } from '../types.ts';
import { MAX_CASE_BYTES, type CaseDraft } from './types.ts';

export class CaseValidationError extends Error {
  constructor() { super('Invalid case draft.'); this.name = 'CaseValidationError'; }
}

export function isNewCaseId(value: unknown): value is string {
  return typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(value);
}

export function parseCaseDraft(value: unknown, requireNewCaseId = false, assignedRevision = 1): CaseDraft {
  try {
    const detached = boundedJsonClone(value);
    check(record(detached, ['schemaVersion', 'caseId', 'profile', 'unresolvedFields', 'findings']));
    check(evidenceIdentifier(detached.caseId) && (!requireNewCaseId || isNewCaseId(detached.caseId)));
    check(evidenceRevision(assignedRevision));
    const snapshot = { ...detached, revision: assignedRevision };
    matchPrograms(snapshot, [], { evaluatedAt: '2000-01-01T00:00:00.000Z', evaluationDate: '2000-01-01' });
    const draft = detached as unknown as CaseDraft;
    check(draft.unresolvedFields.every(evidenceIdentifier));
    const references = new Set<string>();
    for (const finding of draft.findings) {
      check(evidenceIdentifier(finding.id));
      for (const evidenceId of finding.evidenceIds) {
        check(evidenceIdentifier(evidenceId) && !references.has(evidenceId)); references.add(evidenceId);
      }
      for (const measurement of finding.measurements) check(evidenceIdentifier(measurement.type));
    }
    check(Buffer.byteLength(JSON.stringify(snapshot), 'utf8') <= MAX_CASE_BYTES);
    return draft;
  } catch { throw new CaseValidationError(); }
}

export function parseWrittenCase(value: unknown): CaseSnapshot {
  try {
    const detached = boundedJsonClone(value);
    check(record(detached, ['schemaVersion', 'caseId', 'revision', 'profile', 'unresolvedFields', 'findings']));
    check(evidenceRevision(detached.revision));
    const { revision, ...draft } = detached;
    return { ...parseCaseDraft(draft, false, revision), revision };
  } catch { throw new CaseValidationError(); }
}

export function parseCaseSaveRequest(value: unknown): { draft: CaseDraft; expectedRevision: number } {
  try {
    const detached = boundedJsonClone(value, 16 * 1024);
    check(record(detached, ['schemaVersion', 'caseId', 'expectedCaseRevision', 'profile', 'unresolvedFields', 'findings']));
    check(evidenceRevision(detached.expectedCaseRevision));
    const { expectedCaseRevision, ...draft } = detached;
    return { draft: parseCaseDraft(draft, false, expectedCaseRevision + 1), expectedRevision: expectedCaseRevision };
  } catch { throw new CaseValidationError(); }
}

function boundedJsonClone(value: unknown, maximumBytes = MAX_CASE_BYTES): unknown {
  const chunks: string[] = [];
  let bytes = 0;
  const active = new Set<object>();
  function append(text: string) {
    bytes += Buffer.byteLength(text, 'utf8'); check(bytes <= maximumBytes); chunks.push(text);
  }
  function scalar(text: string) {
    check(text.length <= maximumBytes && !text.includes('\u0000') && !Array.from(text).some(character => {
      const code = character.codePointAt(0)!; return code >= 0xd800 && code <= 0xdfff;
    }));
    append(JSON.stringify(text));
  }
  function walk(input: unknown, depth: number) {
    check(depth <= 8);
    if (input === null) { append('null'); return; }
    if (typeof input === 'string') { scalar(input); return; }
    if (typeof input === 'boolean') { append(String(input)); return; }
    if (typeof input === 'number') { check(Number.isFinite(input)); append(JSON.stringify(input)); return; }
    check(typeof input === 'object' && input !== null && !active.has(input));
    active.add(input);
    check(Object.getOwnPropertySymbols(input).length === 0);
    const propertyNames = Object.getOwnPropertyNames(input);
    if (Array.isArray(input)) {
      check(input.length <= maximumBytes && Object.keys(input).length === input.length && propertyNames.length === input.length + 1);
      append('[');
      for (let index = 0; index < input.length; index++) {
        const property = Object.getOwnPropertyDescriptor(input, String(index)); check(property && 'value' in property);
        if (index) append(','); walk(property.value, depth + 1);
      }
      append(']');
    } else {
      check(Object.getPrototypeOf(input) === Object.prototype || Object.getPrototypeOf(input) === null);
      const keys = Object.keys(input); check(keys.length <= maximumBytes && propertyNames.length === keys.length);
      append('{');
      keys.forEach((key, index) => {
        const property = Object.getOwnPropertyDescriptor(input, key); check(property && 'value' in property);
        if (index) append(','); scalar(key); append(':'); walk(property.value, depth + 1);
      });
      append('}');
    }
    active.delete(input);
  }
  walk(value, 0);
  return JSON.parse(chunks.join(''));
}

function record(value: unknown, keys: string[]): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
function check(condition: unknown): asserts condition { if (!condition) throw new CaseValidationError(); }
