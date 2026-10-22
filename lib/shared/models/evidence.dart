import 'contracts.dart';
import 'export_contract_values.dart';

const maxEvidenceBytes = 24 * 1024 * 1024;
const maxSelectedEvidence = 6;

class EvidenceDescriptor {
  EvidenceDescriptor._(this._value);
  factory EvidenceDescriptor.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'evidenceId',
      'evidenceRevision',
      'caseId',
      'findingId',
      'mediaType',
      'byteLength',
      'sha256',
      'width',
      'height',
      'capturedAt',
      'preparedAt',
      'processingVersion',
    });
    for (final key in ['evidenceId', 'caseId', 'findingId']) {
      ExportContractValues.id(value[key]);
    }
    value['evidenceRevision'] = ExportContractValues.integer(
      value['evidenceRevision'],
    );
    value['byteLength'] = ExportContractValues.integer(
      value['byteLength'],
      max: maxEvidenceBytes,
    );
    value['width'] = ExportContractValues.integer(value['width'], max: 8192);
    value['height'] = ExportContractValues.integer(value['height'], max: 8192);
    ExportContractValues.digest(value['sha256']);
    final prepared = ExportContractValues.instant(value['preparedAt']);
    final captured = value['capturedAt'] == null
        ? null
        : ExportContractValues.instant(value['capturedAt']);
    if (value['mediaType'] != 'image/png' ||
        value['processingVersion'] != 'evidence-png-v1' ||
        (value['width'] as int) * (value['height'] as int) > 16000000 ||
        (captured != null &&
            DateTime.parse(captured).isAfter(DateTime.parse(prepared)))) {
      ExportContractValues.invalid();
    }
    return EvidenceDescriptor._(Map.unmodifiable(value));
  }
  final Map<String, Object?> _value;
  String get evidenceId => _value['evidenceId'] as String;
  int get evidenceRevision => _value['evidenceRevision'] as int;
  String get caseId => _value['caseId'] as String;
  String get findingId => _value['findingId'] as String;
  String get mediaType => 'image/png';
  int get byteLength => _value['byteLength'] as int;
  String get sha256 => _value['sha256'] as String;
  int get width => _value['width'] as int;
  int get height => _value['height'] as int;
  String? get capturedAt => _value['capturedAt'] as String?;
  String get preparedAt => _value['preparedAt'] as String;
  String get processingVersion => 'evidence-png-v1';
  Map<String, Object?> toJson() => Map.of(_value);
}

class EvidenceCatalog {
  EvidenceCatalog._(
    this.caseId,
    this.caseRevision,
    this.catalogRevision,
    this.evidence,
  );
  factory EvidenceCatalog.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'catalogRevision',
      'evidence',
    });
    if (value['schemaVersion'] != '1') ExportContractValues.invalid();
    final caseId = ExportContractValues.id(value['caseId']);
    final evidence = ExportContractValues.list(
      value['evidence'],
      EvidenceDescriptor.fromJson,
      64,
    );
    ExportContractValues.unique(evidence.map((item) => item.evidenceId));
    if (evidence.any((item) => item.caseId != caseId)) {
      ExportContractValues.invalid();
    }
    return EvidenceCatalog._(
      caseId,
      ExportContractValues.integer(value['caseRevision']),
      ExportContractValues.integer(value['catalogRevision'], min: 0),
      evidence,
    );
  }
  String get schemaVersion => '1';
  final String caseId;
  final int caseRevision;
  final int catalogRevision;
  final List<EvidenceDescriptor> evidence;
  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'caseId': caseId,
    'caseRevision': caseRevision,
    'catalogRevision': catalogRevision,
    'evidence': evidence.map((item) => item.toJson()).toList(),
  };
  bool belongsTo(CaseSnapshot snapshot) =>
      caseId == snapshot.caseId &&
      caseRevision == snapshot.revision &&
      evidence.every(
        (item) => snapshot.findings.any(
          (finding) =>
              finding.id == item.findingId &&
              finding.evidenceIds.contains(item.evidenceId),
        ),
      );
}

class EvidenceSelection {
  EvidenceSelection._(this.evidenceId, this.expectedEvidenceRevision);
  factory EvidenceSelection.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'evidenceId',
      'expectedEvidenceRevision',
      'reviewedForExport',
    });
    if (value['reviewedForExport'] != true) ExportContractValues.invalid();
    return EvidenceSelection._(
      ExportContractValues.id(value['evidenceId']),
      ExportContractValues.integer(value['expectedEvidenceRevision']),
    );
  }
  final String evidenceId;
  final int expectedEvidenceRevision;
  bool get reviewedForExport => true;
  Map<String, Object?> toJson() => {
    'evidenceId': evidenceId,
    'expectedEvidenceRevision': expectedEvidenceRevision,
    'reviewedForExport': true,
  };
  static List<EvidenceSelection> parseList(Object? json) {
    final result = ExportContractValues.list(
      json,
      EvidenceSelection.fromJson,
      maxSelectedEvidence,
    );
    ExportContractValues.unique(result.map((item) => item.evidenceId));
    return result;
  }
}
