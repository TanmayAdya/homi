import '../../../shared/models/case_draft.dart';
import '../../../shared/models/contracts.dart';
import '../../../shared/models/evidence.dart';
import '../../../shared/models/evidence_mutation.dart';
import '../../../shared/services/case_evidence_api_client.dart';
import '../../../shared/services/draft_export_api_client.dart';

abstract interface class CaseEvidenceGateway {
  Future<CaseSnapshot> saveCase(
    CaseSnapshot saved, {
    required CaseDraft replacement,
    required CaseSnapshot Function() currentCase,
    required CaseDraft Function() currentDraft,
  });

  Future<CaseSnapshot> reloadCase(
    String caseId, {
    required String Function() currentCaseId,
    required CaseSnapshot? Function() currentCase,
  });

  Future<EvidenceCatalog> listEvidence(
    CaseSnapshot snapshot, {
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog? Function() currentCatalog,
  });

  Future<EvidenceUploadResponse> uploadEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required String evidenceId,
    required int expectedEvidenceRevision,
    required String findingId,
    required String? capturedAt,
    required List<int> imageBytes,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  });

  Future<EvidenceDeleteResponse> deleteEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required EvidenceDescriptor evidence,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  });

  Future<List<int>> downloadEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required EvidenceDescriptor evidence,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  });
}

class ApiCaseEvidenceGateway implements CaseEvidenceGateway {
  ApiCaseEvidenceGateway({
    required CaseEvidenceApiClient cases,
    required DraftExportApiClient exports,
    this.writeGuard,
  }) : _cases = cases,
       _exports = exports;

  final void Function()? writeGuard;
  final CaseEvidenceApiClient _cases;
  final DraftExportApiClient _exports;

  @override
  Future<CaseSnapshot> saveCase(
    CaseSnapshot saved, {
    required CaseDraft replacement,
    required CaseSnapshot Function() currentCase,
    required CaseDraft Function() currentDraft,
  }) => _cases.saveCase(
    saved,
    replacement: replacement,
    currentCase: () {
      writeGuard?.call();
      return currentCase();
    },
    currentDraft: currentDraft,
  );

  @override
  Future<CaseSnapshot> reloadCase(
    String caseId, {
    required String Function() currentCaseId,
    required CaseSnapshot? Function() currentCase,
  }) => _cases.reloadCase(
    caseId,
    currentCaseId: currentCaseId,
    currentCase: currentCase,
  );

  @override
  Future<EvidenceCatalog> listEvidence(
    CaseSnapshot snapshot, {
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog? Function() currentCatalog,
  }) => _exports.listEvidence(
    snapshot,
    currentCase: currentCase,
    currentCatalog: currentCatalog,
  );

  @override
  Future<EvidenceUploadResponse> uploadEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required String evidenceId,
    required int expectedEvidenceRevision,
    required String findingId,
    required String? capturedAt,
    required List<int> imageBytes,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) => _cases.uploadEvidence(
    snapshot,
    catalog: catalog,
    evidenceId: evidenceId,
    expectedEvidenceRevision: expectedEvidenceRevision,
    findingId: findingId,
    capturedAt: capturedAt,
    imageBytes: imageBytes,
    currentCase: () {
      writeGuard?.call();
      return currentCase();
    },
    currentCatalog: currentCatalog,
  );

  @override
  Future<EvidenceDeleteResponse> deleteEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required EvidenceDescriptor evidence,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) => _cases.deleteEvidence(
    snapshot,
    catalog: catalog,
    evidence: evidence,
    currentCase: () {
      writeGuard?.call();
      return currentCase();
    },
    currentCatalog: currentCatalog,
  );

  @override
  Future<List<int>> downloadEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required EvidenceDescriptor evidence,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) => _exports.downloadEvidence(
    snapshot,
    catalog: catalog,
    evidence: evidence,
    currentCase: currentCase,
    currentCatalog: currentCatalog,
  );
}
