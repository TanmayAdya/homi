import 'draft_packet.dart';
import 'export_contract_values.dart';

const maxDraftExportBytes = 32 * 1024 * 1024;

class ExportedEvidence {
  ExportedEvidence._(this._value);
  factory ExportedEvidence.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'evidenceId',
      'evidenceRevision',
      'findingId',
      'sha256',
      'reviewedAt',
      'reviewedBy',
    });
    for (final key in ['evidenceId', 'findingId', 'reviewedBy']) {
      ExportContractValues.id(value[key]);
    }
    value['evidenceRevision'] = ExportContractValues.integer(
      value['evidenceRevision'],
    );
    ExportContractValues.digest(value['sha256']);
    ExportContractValues.instant(value['reviewedAt']);
    return ExportedEvidence._(Map.unmodifiable(value));
  }
  final Map<String, Object?> _value;
  String get evidenceId => _value['evidenceId'] as String;
  int get evidenceRevision => _value['evidenceRevision'] as int;
  String get findingId => _value['findingId'] as String;
  String get sha256 => _value['sha256'] as String;
  String get reviewedAt => _value['reviewedAt'] as String;
  String get reviewedBy => _value['reviewedBy'] as String;
  Map<String, Object?> toJson() => Map.of(_value);
}

class ExportArtifactMetadata {
  ExportArtifactMetadata._(
    this._value,
    this.selectedEvidence,
    this.missingItems,
    this.warnings,
  );
  factory ExportArtifactMetadata.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'artifactId',
      'caseId',
      'caseRevision',
      'programId',
      'ruleVersion',
      'formVersion',
      'mappingVersion',
      'formContextId',
      'answerRevision',
      'evidenceCatalogRevision',
      'exportContextId',
      'generatedAt',
      'expiresAt',
      'recheckAfter',
      'status',
      'isDemo',
      'mediaType',
      'byteLength',
      'sha256',
      'pageCount',
      'renderingVersion',
      'selectedEvidence',
      'missingItems',
      'warnings',
    });
    if (value['schemaVersion'] != '1' ||
        value['status'] != 'draft' ||
        value['isDemo'] is! bool ||
        value['mediaType'] != 'application/pdf' ||
        value['renderingVersion'] != 'draft-export-v1') {
      ExportContractValues.invalid();
    }
    for (final key in [
      'artifactId',
      'caseId',
      'programId',
      'ruleVersion',
      'formVersion',
      'mappingVersion',
    ]) {
      ExportContractValues.id(value[key]);
    }
    for (final key in ['formContextId', 'exportContextId', 'sha256']) {
      ExportContractValues.digest(value[key]);
    }
    value['caseRevision'] = ExportContractValues.integer(value['caseRevision']);
    for (final key in ['answerRevision', 'evidenceCatalogRevision']) {
      value[key] = ExportContractValues.integer(value[key], min: 0);
    }
    value['byteLength'] = ExportContractValues.integer(
      value['byteLength'],
      min: 8,
      max: maxDraftExportBytes,
    );
    value['pageCount'] = ExportContractValues.integer(
      value['pageCount'],
      max: 100,
    );
    final generated = ExportContractValues.instant(value['generatedAt']);
    final start = DateTime.parse(generated);
    final end = DateTime.parse(
      ExportContractValues.instant(value['expiresAt']),
    );
    final deadline = value['recheckAfter'] == null
        ? null
        : DateTime.parse(ExportContractValues.instant(value['recheckAfter']));
    if (!end.isAfter(start) ||
        end.difference(start) > const Duration(minutes: 15) ||
        (deadline != null && end.isAfter(deadline))) {
      ExportContractValues.invalid();
    }
    final evidence = ExportContractValues.list(
      value.remove('selectedEvidence'),
      ExportedEvidence.fromJson,
      6,
    );
    ExportContractValues.unique(evidence.map((item) => item.evidenceId));
    if (evidence.any((item) => item.reviewedAt != generated)) {
      ExportContractValues.invalid();
    }
    final missing = ExportContractValues.list(value.remove('missingItems'), (
      json,
    ) {
      final item = PacketMissingItem.fromJson(json);
      ExportContractValues.id(item.id);
      if (item.description.runes.length > 4000) ExportContractValues.invalid();
      return item;
    }, 500);
    ExportContractValues.unique(missing.map((item) => item.id));
    final warnings = ExportContractValues.list(value.remove('warnings'), (
      item,
    ) {
      if (item is! String) ExportContractValues.invalid();
      return item;
    }, 3);
    if (warnings.length < 2 ||
        warnings[0] != 'INCOMPLETE_DRAFT' ||
        warnings[1] != 'NOT_SUBMITTED' ||
        (warnings.length == 3 && warnings[2] != 'POLICY_CURRENTNESS_UNKNOWN') ||
        (deadline == null && warnings.length != 3)) {
      ExportContractValues.invalid();
    }
    return ExportArtifactMetadata._(
      Map.unmodifiable(value),
      evidence,
      missing,
      warnings,
    );
  }
  final Map<String, Object?> _value;
  String get schemaVersion => '1';
  String get artifactId => _value['artifactId'] as String;
  String get caseId => _value['caseId'] as String;
  int get caseRevision => _value['caseRevision'] as int;
  String get programId => _value['programId'] as String;
  String get ruleVersion => _value['ruleVersion'] as String;
  String get formVersion => _value['formVersion'] as String;
  String get mappingVersion => _value['mappingVersion'] as String;
  String get formContextId => _value['formContextId'] as String;
  int get answerRevision => _value['answerRevision'] as int;
  int get evidenceCatalogRevision => _value['evidenceCatalogRevision'] as int;
  String get exportContextId => _value['exportContextId'] as String;
  String get generatedAt => _value['generatedAt'] as String;
  String get expiresAt => _value['expiresAt'] as String;
  String? get recheckAfter => _value['recheckAfter'] as String?;
  String get status => 'draft';
  bool get isDemo => _value['isDemo'] as bool;
  String get mediaType => 'application/pdf';
  int get byteLength => _value['byteLength'] as int;
  String get sha256 => _value['sha256'] as String;
  int get pageCount => _value['pageCount'] as int;
  String get renderingVersion => 'draft-export-v1';
  final List<ExportedEvidence> selectedEvidence;
  final List<PacketMissingItem> missingItems;
  final List<String> warnings;
  Map<String, Object?> toJson() => {
    ..._value,
    'selectedEvidence': selectedEvidence.map((item) => item.toJson()).toList(),
    'missingItems': missingItems
        .map(
          (item) => {
            'id': item.id,
            'description': item.description,
            'resolvedBy': item.resolvedBy,
          },
        )
        .toList(),
    'warnings': List.of(warnings),
  };
  bool isAvailableAt(DateTime now) =>
      !now.isBefore(DateTime.parse(generatedAt)) &&
      now.isBefore(DateTime.parse(expiresAt)) &&
      (recheckAfter == null || now.isBefore(DateTime.parse(recheckAfter!)));
}
