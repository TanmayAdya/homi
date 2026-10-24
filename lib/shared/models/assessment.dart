import 'dart:convert';
import 'case_draft.dart';
import 'contracts.dart';
import 'export_contract_values.dart';

Map<String, Object?> _copy(Map<String, Object?> value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
const _metadataKeys = {
  'findingId',
  'type',
  'originalText',
  'originalUnit',
  'decimalSeparator',
  'source',
  'recorder',
  'recordedAt',
};
Map<String, Object?> validateAssessmentMetadata(Object? value) {
  final v = ExportContractValues.object(value, {'measurements', 'reviews'});
  final keys = <String>{};
  ExportContractValues.list(v['measurements'], (raw) {
    final m = ExportContractValues.object(raw, _metadataKeys);
    final finding = ExportContractValues.id(m['findingId']),
        type = ExportContractValues.id(m['type']);
    if (!keys.add(jsonEncode([finding, type])) ||
        !{'manual', 'estimated', 'legacy_unknown'}.contains(m['source']) ||
        !{'self', 'helper', 'unknown'}.contains(m['recorder'])) {
      ExportContractValues.invalid();
    }
    if (m['recordedAt'] != null) ExportContractValues.instant(m['recordedAt']);
    if (m['source'] == 'legacy_unknown') {
      if (m['originalText'] != null ||
          m['originalUnit'] != null ||
          m['decimalSeparator'] != null) {
        ExportContractValues.invalid();
      }
    } else {
      final original = m['originalText'];
      if (original is! String ||
          original.length > 40 ||
          !{'mm', 'cm', 'm', 'in', 'ft'}.contains(m['originalUnit']) ||
          !{'point', 'comma'}.contains(m['decimalSeparator'])) {
        ExportContractValues.invalid();
      }
      final pattern = m['decimalSeparator'] == 'point'
          ? RegExp(r'^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$')
          : RegExp(r'^(?:[0-9]+(?:,[0-9]+)?|,[0-9]+)$');
      if (!pattern.hasMatch(original.trim())) {
        ExportContractValues.invalid();
      }
      final normalized = original.trim().replaceAll(',', '.');
      final parts = normalized.split('.');
      final significant = normalized
          .replaceAll('.', '')
          .replaceFirst(RegExp(r'^0+'), '');
      final mm =
          double.parse(normalized) *
          {
            'mm': 1.0,
            'cm': 10.0,
            'm': 1000.0,
            'in': 25.4,
            'ft': 304.8,
          }[m['originalUnit']]!;
      if (parts.length == 2 && parts[1].length > 4 ||
          significant.length > 9 ||
          !mm.isFinite ||
          mm > 1000000) {
        ExportContractValues.invalid();
      }
    }
    return m;
  }, 100);
  final ids = <String>{};
  ExportContractValues.list(v['reviews'], (raw) {
    final r = ExportContractValues.object(raw, {'findingId', 'state', 'note'});
    if (!ids.add(ExportContractValues.id(r['findingId'])) ||
        !{'confirmed', 'needs_review', 'dismissed'}.contains(r['state']) ||
        r['note'] != null &&
            (r['note'] is! String ||
                (r['note'] as String).length > 500 ||
                RegExp(r'[\x00-\x1f]').hasMatch(r['note'] as String))) {
      ExportContractValues.invalid();
    }
    return r;
  }, 100);
  if (utf8.encode(jsonEncode(v)).length > 12 * 1024) {
    ExportContractValues.invalid();
  }
  return _copy(v);
}

class AssessmentState {
  AssessmentState._(this._json, this.caseSnapshot);
  factory AssessmentState.fromJson(Object? value) {
    final v = ExportContractValues.object(value, {
      'schemaVersion',
      'case',
      'caseFingerprint',
      'catalogRevision',
      'assessment',
      'acknowledgedMutationId',
    });
    if (v['schemaVersion'] != '2') ExportContractValues.invalid();
    final snapshot = CaseSnapshot.fromJson(v['case']);
    ExportContractValues.digest(v['caseFingerprint']);
    ExportContractValues.integer(v['catalogRevision'], min: 0);
    final a = ExportContractValues.object(v['assessment'], {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'assessmentRevision',
      'metadata',
      'history',
    });
    if (a['schemaVersion'] != '2' ||
        a['caseId'] != snapshot.caseId ||
        ExportContractValues.integer(a['caseRevision']) > snapshot.revision) {
      ExportContractValues.invalid();
    }
    final revision = ExportContractValues.integer(
      a['assessmentRevision'],
      min: 0,
      max: 500,
    );
    validateAssessmentMetadata(a['metadata']);
    final ids = <String>{};
    var index = 0;
    var lastCaseRevision = 0;
    final history = ExportContractValues.list(a['history'], (raw) {
      final e = ExportContractValues.object(raw, {
        'mutationId',
        'requestHash',
        'caseRevision',
        'assessmentRevision',
        'recordedAt',
        'recordedBy',
        'changes',
      });
      final id = ExportContractValues.id(e['mutationId']);
      if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(id) ||
          !ids.add(id) ||
          e['assessmentRevision'] != ++index ||
          ExportContractValues.integer(e['caseRevision']) >
              ExportContractValues.integer(a['caseRevision'])) {
        ExportContractValues.invalid();
      }
      if ((e['caseRevision'] as int) <= lastCaseRevision) {
        ExportContractValues.invalid();
      }
      lastCaseRevision = e['caseRevision'] as int;
      ExportContractValues.digest(e['requestHash']);
      ExportContractValues.instant(e['recordedAt']);
      ExportContractValues.id(e['recordedBy']);
      ExportContractValues.list(e['changes'], (raw) {
        final c = ExportContractValues.object(raw, {'path', 'before', 'after'});
        if (c['path'] is! String || (c['path'] as String).length > 1024) {
          ExportContractValues.invalid();
        }
        return c;
      }, 602);
      return e;
    }, 500);
    if (history.isNotEmpty && lastCaseRevision != a['caseRevision'] ||
        history.length != revision ||
        utf8.encode(jsonEncode(a)).length > 256 * 1024) {
      ExportContractValues.invalid();
    }
    final ack = v['acknowledgedMutationId'];
    if (ack != null && (ack is! String || !ids.contains(ack))) {
      ExportContractValues.invalid();
    }
    return AssessmentState._(_copy(v), snapshot);
  }
  final Map<String, Object?> _json;
  final CaseSnapshot caseSnapshot;
  String get caseFingerprint => _json['caseFingerprint'] as String;
  int get catalogRevision =>
      ExportContractValues.integer(_json['catalogRevision'], min: 0);
  Map<String, Object?> get assessment =>
      Map<String, Object?>.from(_copy(_json)['assessment'] as Map);
  int get assessmentRevision =>
      ExportContractValues.integer(assessment['assessmentRevision'], min: 0);
  int get boundCaseRevision =>
      ExportContractValues.integer(assessment['caseRevision']);
  Map<String, Object?> get metadata =>
      Map<String, Object?>.from(assessment['metadata'] as Map);
  List<Map<String, Object?>> get history => (assessment['history'] as List)
      .map((e) => Map<String, Object?>.from(e as Map))
      .toList();
  String? get acknowledgedMutationId =>
      _json['acknowledgedMutationId'] as String?;
  Map<String, Object?> toJson() => _copy(_json);
  Map<String, Object?> saveRequest({
    required CaseDraft draft,
    required Map<String, Object?> metadata,
    required String mutationId,
  }) {
    if (draft.caseId != caseSnapshot.caseId ||
        !RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(mutationId)) {
      ExportContractValues.invalid();
    }
    return {
      'schemaVersion': '2',
      'caseId': caseSnapshot.caseId,
      'expectedCaseRevision': caseSnapshot.revision,
      'expectedCaseFingerprint': caseFingerprint,
      'expectedCatalogRevision': catalogRevision,
      'expectedAssessmentRevision': assessmentRevision,
      'mutationId': mutationId,
      'draft': draft.toJson(),
      'metadata': validateAssessmentMetadata(metadata),
    };
  }
}
