export class AccountClosedError extends Error {
  constructor() { super('This application account is closed.'); this.name = 'AccountClosedError'; }
}
export class RecentAuthenticationRequiredError extends Error {
  constructor() { super('Sign in again before deleting your account.'); this.name = 'RecentAuthenticationRequiredError'; }
}

export interface DeletionCounts {
  cases: number;
  evidence: number;
  exports: number;
  storedBytes: number;
}
export interface AccountDeletionState {
  status: 'awaiting_confirmation' | 'auth_pending' | 'complete';
  applicationDataDeleted: boolean;
  providerIdentityDeleted: boolean;
}
export type DeleteCaseResult = { status: 'deleted' } |
  { status: 'not_found' | 'conflict' | 'evidence_conflict' | 'invalid_input' };
export type PrepareAccountDeletionResult = { status: 'ready'; counts: DeletionCounts; expiresAt: string } |
  { status: 'closed' | 'invalid_input' };
export type ConfirmAccountDeletionResult = { status: 'confirmed'; deletion: AccountDeletionState } |
  { status: 'not_found' | 'expired' | 'changed' | 'invalid_input' };

export interface LifecycleRepository {
  isAccountClosed(userId: string): Promise<boolean>;
  deleteCaseIfCurrent(input: { userId: string; caseId: string; revision: number; expectedCatalogRevision: number }): Promise<DeleteCaseResult>;
  prepareAccountDeletion(input: { userId: string; tokenHash: string }): Promise<PrepareAccountDeletionResult>;
  confirmAccountDeletion(input: { userId: string; tokenHash: string }): Promise<ConfirmAccountDeletionResult>;
  readAccountDeletionReceipt(tokenHash: string): Promise<AccountDeletionState | null>;
}

export interface AuthDeletionJob {
  jobId: string;
  userId: string;
  leaseToken: string;
}
export interface RetentionReport {
  expiredExports: number;
  releasedBytes: number;
  expiredPreviews: number;
  expiredReceipts: number;
}
export interface LifecycleMaintenance {
  pendingAuthDeletionCount(): Promise<number>;
  claimAuthDeletionJobs(limit: number): Promise<AuthDeletionJob[]>;
  finishAuthDeletionJob(input: { jobId: string; leaseToken: string; outcome: 'deleted' | 'retry' }): Promise<boolean>;
  sweepRetention(): Promise<RetentionReport>;
}
