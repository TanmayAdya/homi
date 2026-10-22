import 'evidence.dart';
import 'export_contract_values.dart';

class EvidenceUploadResponse {
  EvidenceUploadResponse._(
    this.caseId,
    this.caseRevision,
    this.catalogRevision,
    this.evidence,
  );
  factory EvidenceUploadResponse.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'catalogRevision',
      'evidence',
    });
    if (value['schemaVersion'] != '1') ExportContractValues.invalid();
    final caseId = ExportContractValues.id(value['caseId']);
    final evidence = EvidenceDescriptor.fromJson(value['evidence']);
    if (evidence.caseId != caseId) ExportContractValues.invalid();
    return EvidenceUploadResponse._(
      caseId,
      ExportContractValues.integer(value['caseRevision']),
      ExportContractValues.integer(value['catalogRevision']),
      evidence,
    );
  }
  String get schemaVersion => '1';
  final String caseId;
  final int caseRevision;
  final int catalogRevision;
  final EvidenceDescriptor evidence;
  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'caseId': caseId,
    'caseRevision': caseRevision,
    'catalogRevision': catalogRevision,
    'evidence': evidence.toJson(),
  };
}

class EvidenceDeleteResponse {
  EvidenceDeleteResponse._(
    this.caseId,
    this.caseRevision,
    this.catalogRevision,
    this.evidenceId,
    this.evidenceRevision,
  );
  factory EvidenceDeleteResponse.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'catalogRevision',
      'evidenceId',
      'evidenceRevision',
      'deleted',
    });
    if (value['schemaVersion'] != '1' || value['deleted'] != true) {
      ExportContractValues.invalid();
    }
    return EvidenceDeleteResponse._(
      ExportContractValues.id(value['caseId']),
      ExportContractValues.integer(value['caseRevision']),
      ExportContractValues.integer(value['catalogRevision']),
      ExportContractValues.id(value['evidenceId']),
      ExportContractValues.integer(value['evidenceRevision']),
    );
  }
  String get schemaVersion => '1';
  final String caseId;
  final int caseRevision;
  final int catalogRevision;
  final String evidenceId;
  final int evidenceRevision;
  bool get deleted => true;
  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'caseId': caseId,
    'caseRevision': caseRevision,
    'catalogRevision': catalogRevision,
    'evidenceId': evidenceId,
    'evidenceRevision': evidenceRevision,
    'deleted': true,
  };
}
