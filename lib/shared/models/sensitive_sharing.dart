import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'evidence.dart';
import 'export_contract_values.dart';

const sensitiveSharingRoutes = {
  'list-sensitive-options',
  'preview-sensitive-sharing',
  'publish-sensitive-sharing',
  'read-sensitive-sharing',
  'preview-sensitive-photo',
  'read-sensitive-photo',
  'preview-sensitive-report',
  'read-sensitive-report',
};
typedef SensitiveJson = Map<String, Object?>;
SensitiveJson _object(Object? v, Set<String> keys) =>
    ExportContractValues.object(v, keys);
String _id(Object? v) => ExportContractValues.id(v);
String _text(Object? v, int limit) {
  if (v is! String || v.isEmpty || v.length > limit) {
    throw const FormatException();
  }
  return v;
}

int _revision(Object? v, {bool zero = false}) {
  if (v is! int || v < (zero ? 0 : 1)) throw const FormatException();
  return v;
}

String _hash(Object? v) {
  final s = _text(v, 64);
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(s)) throw const FormatException();
  return s;
}

String _selectedId(String kind, String parent, String key) =>
    '$kind-${sha256.convert(utf8.encode(jsonEncode([parent, key])))}';

List<T> _list<T>(Object? value, int max, T Function(Object?) parse) {
  if (value is! List || value.length > max) throw const FormatException();
  return List.unmodifiable(value.map(parse));
}

class SensitiveSelection {
  const SensitiveSelection({
    this.photoIds = const [],
    this.measurementIds = const [],
    this.answerIds = const [],
  });
  final List<String> photoIds, measurementIds, answerIds;
  SensitiveJson toJson() => {
    'photoIds': photoIds,
    'measurementIds': measurementIds,
    'answerIds': answerIds,
  };
  factory SensitiveSelection.fromJson(Object? value) {
    final j = _object(value, {'photoIds', 'measurementIds', 'answerIds'});
    final p = _list(j['photoIds'], 6, _id),
        m = _list(j['measurementIds'], 32, _id),
        a = _list(j['answerIds'], 32, _id);
    for (final ids in [p, m, a]) {
      if (ids.toSet().length != ids.length) throw const FormatException();
    }
    return SensitiveSelection(photoIds: p, measurementIds: m, answerIds: a);
  }
}

class SharedMeasurement {
  SharedMeasurement._(
    this.id,
    this.findingId,
    this.type,
    this.value,
    this.unit,
    this.method,
    this.confirmed,
  );
  final String id, findingId, type, unit, method;
  final num value;
  final bool confirmed;
  factory SharedMeasurement.fromJson(Object? value) {
    final j = _object(value, {
      'id',
      'findingId',
      'type',
      'value',
      'unit',
      'method',
      'confirmed',
    });
    if (j['value'] is! num ||
        !(j['value'] as num).isFinite ||
        j['unit'] != 'mm' ||
        !{'manual', 'estimated'}.contains(j['method']) ||
        j['confirmed'] is! bool ||
        j['id'] !=
            _selectedId('measurement', _id(j['findingId']), _id(j['type']))) {
      throw const FormatException();
    }
    return SharedMeasurement._(
      _id(j['id']),
      _id(j['findingId']),
      _id(j['type']),
      j['value'] as num,
      'mm',
      j['method'] as String,
      j['confirmed'] as bool,
    );
  }
}

class SharedIntakeAnswer {
  SharedIntakeAnswer._(
    this.id,
    this.programId,
    this.key,
    this.label,
    this.category,
    this.questionnaireVersion,
    this.intakeRevision,
    this.value,
    this.reviewState,
  );
  final String id,
      programId,
      key,
      label,
      category,
      questionnaireVersion,
      reviewState;
  final int intakeRevision;
  final Object? value;
  factory SharedIntakeAnswer.fromJson(Object? value) {
    final j = _object(value, {
          'id',
          'programId',
          'key',
          'label',
          'category',
          'questionnaireVersion',
          'intakeRevision',
          'value',
          'reviewState',
        }),
        v = j['value'];
    if (!{'financial', 'health', 'private'}.contains(j['category']) ||
        j['id'] != _selectedId('answer', _id(j['programId']), _id(j['key'])) ||
        !{'reported', 'unknown'}.contains(j['reviewState']) ||
        (v == null) != (j['reviewState'] == 'unknown') ||
        !(v == null ||
            v is bool ||
            v is num && v.isFinite ||
            v is String && v.length <= 600)) {
      throw const FormatException();
    }
    return SharedIntakeAnswer._(
      _id(j['id']),
      _id(j['programId']),
      _id(j['key']),
      _text(j['label'], 300),
      j['category'] as String,
      _hash(j['questionnaireVersion']),
      _revision(j['intakeRevision']),
      v,
      j['reviewState'] as String,
    );
  }
}

class SelectedSensitiveContent {
  SelectedSensitiveContent._(this.photos, this.measurements, this.answers);
  final List<EvidenceDescriptor> photos;
  final List<SharedMeasurement> measurements;
  final List<SharedIntakeAnswer> answers;
  factory SelectedSensitiveContent.fromJson(Object? value) {
    final j = _object(value, {'photos', 'measurements', 'answers'});
    final p = _list(j['photos'], 192, EvidenceDescriptor.fromJson),
        m = _list(j['measurements'], 1024, SharedMeasurement.fromJson),
        a = _list(j['answers'], 128, SharedIntakeAnswer.fromJson);
    for (final ids in [
      p.map((v) => v.evidenceId),
      m.map((v) => v.id),
      a.map((v) => v.id),
    ]) {
      if (ids.toSet().length != ids.length) throw const FormatException();
    }
    return SelectedSensitiveContent._(p, m, a);
  }
}

class SensitiveResponse {
  SensitiveResponse._(
    this.membershipId,
    this.permissionRevision, {
    this.caseId,
    this.caseRevision,
    this.catalogRevision,
    this.content,
    this.selection,
    this.allowPdf = false,
    this.expiresAt,
    this.sourceHash,
    this.acknowledgement,
    this.bytes,
    this.descriptor,
    this.pageCount,
  });
  final String membershipId;
  final int permissionRevision;
  final String? caseId, expiresAt, sourceHash, acknowledgement;
  final int? caseRevision, catalogRevision, pageCount;
  final SelectedSensitiveContent? content;
  final SensitiveSelection? selection;
  final bool allowPdf;
  final Uint8List? bytes;
  final EvidenceDescriptor? descriptor;
  factory SensitiveResponse.fromJson(String route, Object? value) {
    final j = value is Map<String, Object?>
        ? value
        : throw const FormatException();
    const base = {'schemaVersion', 'membershipId', 'permissionRevision'};
    if (j['schemaVersion'] != '3') throw const FormatException();
    final id = _id(j['membershipId']),
        revision = _revision(j['permissionRevision']);
    if (route.endsWith('-photo')) {
      _object(j, {...base, 'descriptor', 'photoBase64'});
      final descriptor = EvidenceDescriptor.fromJson(j['descriptor']);
      final bytes = _bytes(
        j['photoBase64'],
        descriptor.sha256,
        8 * 1024 * 1024,
      );
      const png = [137, 80, 78, 71, 13, 10, 26, 10];
      if (bytes.length != descriptor.byteLength ||
          bytes.length < png.length ||
          List.generate(png.length, (i) => bytes[i]).join(',') !=
              png.join(',')) {
        throw const FormatException();
      }
      return SensitiveResponse._(
        id,
        revision,
        descriptor: descriptor,
        bytes: bytes,
      );
    }
    if (route.endsWith('-report')) {
      _object(j, {...base, 'sourceHash', 'report'});
      final r = _object(j['report'], {'pdfBase64', 'sha256', 'pageCount'}),
          bytes = _bytes(r['pdfBase64'], _hash(r['sha256']), 2 * 1024 * 1024);
      final count = _revision(r['pageCount']);
      if (count > 128 ||
          bytes.length < 8 ||
          ascii.decode(bytes.sublist(0, 5), allowInvalid: true) != '%PDF-') {
        throw const FormatException();
      }
      return SensitiveResponse._(
        id,
        revision,
        sourceHash: _hash(j['sourceHash']),
        bytes: bytes,
        pageCount: count,
      );
    }
    final options = route == 'list-sensitive-options';
    _object(j, {
      ...base,
      'caseId',
      'caseRevision',
      'catalogRevision',
      'content',
      if (!options) ...[
        'selection',
        'allowPdf',
        'expiresAt',
        'sourceHash',
        'acknowledgedMutationId',
      ],
    });
    final content = SelectedSensitiveContent.fromJson(j['content']);
    final selection = options
        ? null
        : SensitiveSelection.fromJson(j['selection']);
    if (!options) {
      if (j['allowPdf'] is! bool ||
          j['expiresAt'] is! String ||
          DateTime.tryParse(j['expiresAt'] as String) == null ||
          (j['acknowledgedMutationId'] != null &&
              j['acknowledgedMutationId'] is! String)) {
        throw const FormatException();
      }
      if (content.photos.length != selection!.photoIds.length ||
          content.measurements.length != selection.measurementIds.length ||
          content.answers.length != selection.answerIds.length ||
          content.photos.any(
            (v) => !selection.photoIds.contains(v.evidenceId),
          ) ||
          content.measurements.any(
            (v) => !selection.measurementIds.contains(v.id),
          ) ||
          content.answers.any((v) => !selection.answerIds.contains(v.id))) {
        throw const FormatException();
      }
    }
    return SensitiveResponse._(
      id,
      revision,
      caseId: _id(j['caseId']),
      caseRevision: _revision(j['caseRevision']),
      catalogRevision: _revision(j['catalogRevision'], zero: true),
      content: content,
      selection: selection,
      allowPdf: !options && j['allowPdf'] == true,
      expiresAt: options ? null : j['expiresAt'] as String,
      sourceHash: options ? null : _hash(j['sourceHash']),
      acknowledgement: j['acknowledgedMutationId'] as String?,
    );
  }
}

Uint8List _bytes(Object? value, String expectedHash, int max) {
  final encoded = _text(value, ((max + 2) ~/ 3) * 4);
  final bytes = base64Decode(encoded);
  if (bytes.isEmpty ||
      bytes.length > max ||
      base64Encode(bytes) != encoded ||
      sha256.convert(bytes).toString() != expectedHash) {
    throw const FormatException();
  }
  return bytes;
}
