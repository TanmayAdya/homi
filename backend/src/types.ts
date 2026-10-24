export type CheckStatus = 'pass' | 'fail' | 'unknown';
export type MatchStatus = 'meets_known_criteria' | 'does_not_meet_criterion' | 'needs_confirmation';
export type ResolvedBy = 'resident' | 'program' | 'professional';
export type Availability = 'unverified' | 'accepting' | 'not_accepting';

export interface Profile {
  city: string | null;
  county: string | null;
  healthPlan: string | null;
  tenure: 'owner' | 'renter' | null;
  ageYears: number | null;
  householdSize: number | null;
  annualIncomeUsd: number | null;
  ownerConsentReported: boolean | null;
}

export type ProfileField = keyof Profile;
export type NumericField = 'ageYears' | 'householdSize' | 'annualIncomeUsd';

export interface Measurement {
  type: string;
  value: number;
  unit: 'mm';
  method: 'manual' | 'estimated';
  confirmed: boolean;
}

export interface Finding {
  id: string;
  room: 'bathroom' | 'entrance' | 'other';
  observation: string;
  reviewState: 'confirmed' | 'needs_review' | 'dismissed';
  evidenceIds: string[];
  measurements: Measurement[];
}

export interface CaseSnapshot {
  schemaVersion: '1';
  caseId: string;
  revision: number;
  profile: Profile;
  unresolvedFields: string[];
  findings: Finding[];
}

export interface Source {
  id: string;
  url: string;
  title: string;
  reviewedOn: string;
  effectiveFrom: string | null;
  effectiveUntil: string | null;
}

interface LeafMetadata {
  sourceIds: string[];
  resolvedBy: ResolvedBy;
}

export type Rule =
  | (LeafMetadata & { kind: 'eq'; field: ProfileField; value: string | number | boolean })
  | (LeafMetadata & { kind: 'gte' | 'lte'; field: NumericField; value: number })
  | (LeafMetadata & { kind: 'manual_review'; reason: string })
  | { kind: 'and'; rules: Rule[] }
  | { kind: 'or'; rules: Rule[] };

export interface Criterion {
  id: string;
  label: string;
  rule: Rule;
  exception?: Rule;
}

export interface ProgramDefinition {
  programId: string;
  programName: string;
  ruleVersion: string;
  isDemo: boolean;
  availability: Availability;
  rulesVerified: boolean;
  reviewedOn: string | null;
  effectiveFrom: string | null;
  effectiveUntil: string | null;
  recheckAfter: string | null;
  criteria: Criterion[];
  sources: Source[];
  requiredDocuments: string[];
  intake: string | null;
}

export interface EvaluationContext {
  evaluatedAt: string;
  evaluationDate: string;
}

export interface Check {
  id: string;
  status: CheckStatus;
  reasonCode: string;
  explanation: string;
  missingFields: string[];
  resolvedBy: ResolvedBy | null;
  sourceIds: string[];
}

export interface Match {
  programId: string;
  programName: string;
  ruleVersion: string;
  isDemo: boolean;
  status: MatchStatus;
  availability: Availability;
  recheckAfter: string | null;
  checks: Check[];
  sources: Source[];
  requiredDocuments: string[];
  intake: string | null;
}

export interface MatchResponse {
  schemaVersion: '1';
  caseId: string;
  caseRevision: number;
  evaluatedAt: string;
  evaluationDate: string;
  matches: Match[];
}

export interface MissingPacketItem {
  id: string;
  description: string;
  resolvedBy: ResolvedBy;
}

export interface DraftPacket {
  schemaVersion: '1';
  packetId: string;
  caseId: string;
  caseRevision: number;
  programId: string;
  ruleVersion: string;
  formVersion: string | null;
  mappingVersion: string | null;
  status: 'draft';
  isDemo: boolean;
  generatedAt: string;
  recheckAfter: string | null;
  storageReference: string | null;
  attachments: { evidenceId: string; findingId: string; storageReference: string }[];
  missingItems: MissingPacketItem[];
}
