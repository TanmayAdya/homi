import 'dart:convert';
import 'export_contract_values.dart';

Map<String, Object?> _copy(Map<String, Object?> v) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(v)) as Map);

class AnnotationState {
  AnnotationState._(this._json);
  factory AnnotationState.fromJson(Object? value) {
    final v = ExportContractValues.object(value, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'catalogRevision',
      'annotation',
    });
    if (v['schemaVersion'] != '2') ExportContractValues.invalid();
    ExportContractValues.id(v['caseId']);
    ExportContractValues.integer(v['caseRevision']);
    ExportContractValues.integer(v['catalogRevision'], min: 0);
    final a = ExportContractValues.object(v['annotation'], {
      'schemaVersion',
      'caseId',
      'evidenceId',
      'annotationRevision',
      'evidenceRevision',
      'imageSha256',
      'imageWidth',
      'imageHeight',
      'coordinateSpace',
      'marks',
      'reviewState',
      'reviewedCaseRevision',
      'reviewedAt',
      'reviewedBy',
    });
    if (a['schemaVersion'] != '2' ||
        a['caseId'] != v['caseId'] ||
        a['coordinateSpace'] != 'normalized-top-left-1e6' ||
        !{'needs_review', 'reviewed'}.contains(a['reviewState'])) {
      ExportContractValues.invalid();
    }
    ExportContractValues.id(a['evidenceId']);
    ExportContractValues.integer(a['annotationRevision'], min: 0);
    ExportContractValues.integer(a['evidenceRevision']);
    ExportContractValues.digest(a['imageSha256']);
    ExportContractValues.integer(a['imageWidth'], max: 8192);
    ExportContractValues.integer(a['imageHeight'], max: 8192);
    validateAnnotationMarks(a['marks']);
    if (a['reviewState'] == 'reviewed') {
      ExportContractValues.integer(a['reviewedCaseRevision']);
      ExportContractValues.instant(a['reviewedAt']);
      ExportContractValues.id(a['reviewedBy']);
    } else if (a['reviewedCaseRevision'] != null ||
        a['reviewedAt'] != null ||
        a['reviewedBy'] != null) {
      ExportContractValues.invalid();
    }
    return AnnotationState._(_copy(v));
  }
  final Map<String, Object?> _json;
  String get caseId => _json['caseId'] as String;
  int get caseRevision => ExportContractValues.integer(_json['caseRevision']);
  int get catalogRevision =>
      ExportContractValues.integer(_json['catalogRevision'], min: 0);
  Map<String, Object?> get annotation =>
      Map<String, Object?>.from(_copy(_json)['annotation'] as Map);
  int get annotationRevision =>
      ExportContractValues.integer(annotation['annotationRevision'], min: 0);
  List<Map<String, Object?>> get marks => (annotation['marks'] as List)
      .map((e) => Map<String, Object?>.from(e as Map))
      .toList();
  Map<String, Object?> toJson() => _copy(_json);
  Map<String, Object?> saveRequest({
    required List<Map<String, Object?>> marks,
    required bool reviewedForExport,
  }) {
    final a = annotation;
    return {
      'schemaVersion': '2',
      'caseId': caseId,
      'expectedCaseRevision': caseRevision,
      'expectedCatalogRevision': catalogRevision,
      'evidenceId': a['evidenceId'],
      'expectedEvidenceRevision': a['evidenceRevision'],
      'expectedAnnotationRevision': annotationRevision,
      'expectedImageSha256': a['imageSha256'],
      'expectedImageWidth': a['imageWidth'],
      'expectedImageHeight': a['imageHeight'],
      'marks': validateAnnotationMarks(marks),
      'reviewedForExport': reviewedForExport,
    };
  }
}

List<Map<String, Object?>> validateAnnotationMarks(Object? value) {
  final ids = <String>{};
  var total = 0;
  final marks = ExportContractValues.list(value, (raw) {
    final m = ExportContractValues.object(raw, {'id', 'rect', 'label'});
    if (!ids.add(ExportContractValues.id(m['id']))) {
      ExportContractValues.invalid();
    }
    final rect = ExportContractValues.list(
      m['rect'],
      (v) => ExportContractValues.integer(v, min: 0, max: 1000000),
      4,
    );
    if (rect.length != 4 ||
        rect[2] <= 0 ||
        rect[3] <= 0 ||
        rect[0] + rect[2] > 1000000 ||
        rect[1] + rect[3] > 1000000) {
      ExportContractValues.invalid();
    }
    final label = m['label'];
    if (label is! String ||
        label.runes.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(label)) {
      ExportContractValues.invalid();
    }
    total += label.runes.length;
    return _copy(m);
  }, 20);
  if (total > 800 || utf8.encode(jsonEncode(marks)).length > 12 * 1024) {
    ExportContractValues.invalid();
  }
  return marks;
}
