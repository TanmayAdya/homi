import '../../../shared/models/export_contract_values.dart';
import '../domain/capture/capture_adapter.dart';

final class CaptureAttempt {
  const CaptureAttempt({
    required this.area,
    required this.view,
    required this.source,
    required this.findingId,
    required this.evidenceId,
    required this.newFinding,
    required this.replacingVersion,
  });
  final AssessmentArea area;
  final CaptureView view;
  final CaptureSource source;
  final String findingId, evidenceId;
  final bool newFinding;
  final String? replacingVersion;
  bool get replacing => replacingVersion != null;

  Map<String, Object?> toLocalJson() => {
    'area': area.name,
    'view': view.name,
    'source': source.name,
    'findingId': findingId,
    'evidenceId': evidenceId,
    'newFinding': newFinding,
    'replacingVersion': replacingVersion,
  };

  factory CaptureAttempt.fromLocalJson(Object? value) {
    final v = value as Map;
    if (v.length != 7 || v['newFinding'] is! bool) {
      throw const FormatException('Invalid capture checkpoint');
    }
    final findingId = v['findingId'] as String;
    final evidenceId = v['evidenceId'] as String;
    ExportContractValues.id(findingId);
    ExportContractValues.id(evidenceId);
    final version = v['replacingVersion'] as String?;
    if (version != null && (version.isEmpty || version.length > 200)) {
      throw const FormatException('Invalid capture photo version');
    }
    return CaptureAttempt(
      area: AssessmentArea.values.byName(v['area'] as String),
      view: CaptureView.values.byName(v['view'] as String),
      source: CaptureSource.values.byName(v['source'] as String),
      findingId: findingId,
      evidenceId: evidenceId,
      newFinding: v['newFinding'] as bool,
      replacingVersion: version,
    );
  }
}

final class PrivacyAttempt {
  const PrivacyAttempt(this.findingId, this.evidenceId, this.version);
  final String findingId, evidenceId, version;
  Map<String, Object?> toLocalJson() => {
    'findingId': findingId,
    'evidenceId': evidenceId,
    'version': version,
  };
  factory PrivacyAttempt.fromLocalJson(Object? value) {
    final v = value as Map;
    if (v.length != 3) {
      throw const FormatException('Invalid privacy checkpoint');
    }
    final finding = v['findingId'] as String;
    final evidence = v['evidenceId'] as String;
    final version = v['version'] as String;
    ExportContractValues.id(finding);
    ExportContractValues.id(evidence);
    if (version.isEmpty || version.length > 200) {
      throw const FormatException('Invalid privacy photo version');
    }
    return PrivacyAttempt(finding, evidence, version);
  }
}
