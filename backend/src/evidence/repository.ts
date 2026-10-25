import type { CaseSnapshot } from '../types.ts';
import type { SavedFormAnswerSet } from '../forms/form-answers.ts';
import type { ExportArtifactMetadata } from '../exports/types.ts';
import type { EvidenceAsset, EvidenceCatalog, EvidenceDescriptor, EvidenceSelection, SanitizedEvidenceImage } from './types.ts';

export type EvidenceRepositoryFailure = { status: 'not_found' | 'conflict' | 'evidence_conflict'
  | 'answers_conflict' | 'generation_conflict' | 'expired' | 'quota_exceeded' | 'selection_too_large' };

export interface EvidenceCaseBinding {
  userId: string;
  caseId: string;
  revision: number;
  expectedCatalogRevision: number;
}

export interface EvidenceReadInput extends EvidenceCaseBinding {
  evidenceId: string;
  expectedEvidenceRevision: number;
}

export interface EvidenceSaveInput extends EvidenceReadInput {
  findingId: string;
  image: SanitizedEvidenceImage;
  capturedAt: string | null;
  preparedAt: string;
}

export interface ExportSnapshotInput extends EvidenceCaseBinding {
  programId: string;
  selections: EvidenceSelection[];
}

export interface ExportSnapshot {
  snapshot: CaseSnapshot;
  caseFingerprint: string;
  answers: SavedFormAnswerSet | null;
  answersFingerprint: string | null;
  catalogRevision: number;
  assets: EvidenceAsset[];
}

export interface ExportReviewSnapshot extends Omit<ExportSnapshot, 'assets'> {
  evidence: EvidenceDescriptor[];
}

export interface PrivateExportArtifact {
  metadata: ExportArtifactMetadata;
  bytes: Uint8Array;
}

export interface ExportPublishInput extends EvidenceCaseBinding {
  programId: string;
  expectedCaseFingerprint: string;
  expectedAnswersFingerprint: string | null;
  selections: EvidenceSelection[];
  contextFingerprint: string;
  generationKey: string;
  artifact: PrivateExportArtifact;
  checkedAt: string;
}

export interface ExportReadInput {
  userId: string;
  caseId: string;
  artifactId: string;
}

export interface ExportCurrentReadInput extends ExportReadInput {
  contextFingerprint: string;
  checkedAt: string;
}

export interface EvidenceRepository {
  readEvidenceCatalogForUser(userId: string, caseId: string): Promise<
    { status: 'found'; catalog: EvidenceCatalog } | EvidenceRepositoryFailure>;
  readEvidenceForUser(input: EvidenceReadInput): Promise<
    { status: 'found'; asset: EvidenceAsset } | EvidenceRepositoryFailure>;
  saveEvidenceIfCurrent(input: EvidenceSaveInput): Promise<
    { status: 'saved'; asset: EvidenceAsset; catalogRevision: number } | EvidenceRepositoryFailure>;
  deleteEvidenceIfCurrent(input: EvidenceReadInput): Promise<
    { status: 'deleted'; evidenceRevision: number; catalogRevision: number } | EvidenceRepositoryFailure>;
  loadExportSnapshotForUser(input: ExportSnapshotInput): Promise<
    { status: 'found'; snapshot: ExportSnapshot } | EvidenceRepositoryFailure>;
  loadExportReviewForUser(input: ExportSnapshotInput): Promise<
    { status: 'found'; snapshot: ExportReviewSnapshot } | EvidenceRepositoryFailure>;
  publishExportIfCurrent(input: ExportPublishInput): Promise<
    { status: 'saved' | 'reused'; artifact: ExportArtifactMetadata } | EvidenceRepositoryFailure>;
  readExportForUser(input: ExportReadInput): Promise<
    { status: 'found'; artifact: ExportArtifactMetadata } | EvidenceRepositoryFailure>;
  reviewExportForUserIfCurrent(input: ExportCurrentReadInput): Promise<
    { status: 'found'; artifact: ExportArtifactMetadata } | EvidenceRepositoryFailure>;
  readExportForUserIfCurrent(input: ExportCurrentReadInput): Promise<
    { status: 'found'; artifact: PrivateExportArtifact } | EvidenceRepositoryFailure>;
}
