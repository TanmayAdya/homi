export const MAX_SELECTED_EVIDENCE = 6;

export interface SanitizedEvidenceImage {
  bytes: Uint8Array;
  mediaType: 'image/png';
  byteLength: number;
  sha256: string;
  width: number;
  height: number;
  processingVersion: 'evidence-png-v1';
}

export interface EvidenceDescriptor {
  evidenceId: string;
  evidenceRevision: number;
  caseId: string;
  findingId: string;
  mediaType: 'image/png';
  byteLength: number;
  sha256: string;
  width: number;
  height: number;
  capturedAt: string | null;
  preparedAt: string;
  processingVersion: 'evidence-png-v1';
}

export interface EvidenceAsset {
  descriptor: EvidenceDescriptor;
  bytes: Uint8Array;
}

export interface EvidenceCatalog {
  schemaVersion: '1';
  caseId: string;
  caseRevision: number;
  catalogRevision: number;
  evidence: EvidenceDescriptor[];
}

export interface EvidenceSelection {
  evidenceId: string;
  expectedEvidenceRevision: number;
  reviewedForExport: true;
}
