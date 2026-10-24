import type { MissingPacketItem } from '../types.ts';

export interface ExportArtifactMetadata {
  schemaVersion: '1' | '2';
  artifactId: string;
  caseId: string;
  caseRevision: number;
  programId: string;
  ruleVersion: string;
  formVersion: string;
  mappingVersion: string;
  formContextId: string;
  answerRevision: number;
  evidenceCatalogRevision: number;
  exportContextId: string;
  generatedAt: string;
  expiresAt: string;
  recheckAfter: string | null;
  status: 'draft';
  isDemo: boolean;
  mediaType: 'application/pdf';
  byteLength: number;
  sha256: string;
  pageCount: number;
  renderingVersion: 'draft-export-v1' | 'draft-export-annotations-v2';
  selectedEvidence: {
    evidenceId: string;
    evidenceRevision: number;
    findingId: string;
    sha256: string;
    reviewedAt: string;
    reviewedBy: string;
    annotationRevision?: number;
    annotationSha256?: string;
  }[];
  missingItems: MissingPacketItem[];
  warnings: ('INCOMPLETE_DRAFT' | 'NOT_SUBMITTED' | 'POLICY_CURRENTNESS_UNKNOWN')[];
}
