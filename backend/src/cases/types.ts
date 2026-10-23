import type { CaseSnapshot } from '../types.ts';

export type CaseDraft = Omit<CaseSnapshot, 'revision'>;

export const MAX_CASE_BYTES = 12 * 1024;
export const MAX_MEMORY_CASES = 64;
