import 'dart:convert';
import 'draft_export.dart';
import 'export_contract_values.dart';

class AnnotatedExportArtifact {
  AnnotatedExportArtifact._(this._value, this.base);
  factory AnnotatedExportArtifact.fromJson(Object? json) {
    if (json is! Map) ExportContractValues.invalid();
    final value = Map<String, Object?>.from(
      jsonDecode(jsonEncode(json)) as Map,
    );
    if (value['schemaVersion'] != '2' ||
        value['renderingVersion'] != 'draft-export-annotations-v2') {
      ExportContractValues.invalid();
    }
    final evidence = ExportContractValues.list(value['selectedEvidence'], (
      item,
    ) {
      final record = ExportContractValues.object(item, {
        'evidenceId',
        'evidenceRevision',
        'findingId',
        'sha256',
        'reviewedAt',
        'reviewedBy',
        'annotationRevision',
        'annotationSha256',
      });
      ExportContractValues.integer(record.remove('annotationRevision'), min: 0);
      ExportContractValues.digest(record.remove('annotationSha256'));
      return ExportedEvidence.fromJson(record).toJson();
    }, 6);
    final base = ExportArtifactMetadata.fromJson({
      ...value,
      'schemaVersion': '1',
      'renderingVersion': 'draft-export-v1',
      'selectedEvidence': evidence,
    });
    return AnnotatedExportArtifact._(value, base);
  }
  final Map<String, Object?> _value;

  final ExportArtifactMetadata base;
  Map<String, Object?> toJson() =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(_value)) as Map);
}
