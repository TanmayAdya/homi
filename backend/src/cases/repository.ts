import type { CaseSnapshot } from '../types.ts';
import type { CaseDraft } from './types.ts';

export type CaseWriteFailure = { status: 'not_found' | 'conflict' | 'id_unavailable'
  | 'evidence_conflict' | 'quota_exceeded' | 'invalid_input' };
export type CaseWriteResult = { status: 'saved'; snapshot: CaseSnapshot } | CaseWriteFailure;

export interface CaseWriteRepository {
  createForUser(userId: string, draft: CaseDraft): Promise<CaseWriteResult>;
  replaceIfCurrent(userId: string, caseId: string, revision: number, draft: CaseDraft): Promise<CaseWriteResult>;
}
