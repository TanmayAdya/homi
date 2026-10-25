import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

enum ScanSource { roomplan, arcore, arkit }

enum ScanElementKind {
  wall,
  door,
  opening,
  window,
  floor,
  bathtub,
  toilet,
  sink,
  storage,
  furniture,
  unknown;

  String get label => switch (this) {
    wall => 'Wall',
    door => 'Doorway',
    opening => 'Opening',
    window => 'Window',
    floor => 'Floor',
    bathtub => 'Bathtub',
    toilet => 'Toilet',
    sink => 'Sink',
    storage => 'Storage',
    furniture => 'Furniture',
    unknown => 'Unidentified surface',
  };
}

enum ScanClassificationConfidence { low, medium, high, unknown }

final class ScanVector3 {
  const ScanVector3(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;

  List<double> toJson() => [x, y, z];
}

final class ScanPoint {
  const ScanPoint._(this.position, this.confidence);
  final ScanVector3 position;

  final double confidence;

  List<double> toJson() => [...position.toJson(), confidence];
}

final class ScanElement {
  const ScanElement._({
    required this.id,
    required this.kind,
    required this.nativeCategory,
    required this.dimensions,
    required this.transform,
    required this.classificationConfidence,
  });

  final String id;
  final ScanElementKind kind;
  final String nativeCategory;

  final ScanVector3 dimensions;

  final List<double> transform;
  final ScanClassificationConfidence classificationConfidence;

  ScanVector3 transformPoint(ScanVector3 local) => ScanVector3(
    transform[0] * local.x +
        transform[4] * local.y +
        transform[8] * local.z +
        transform[12],
    transform[1] * local.x +
        transform[5] * local.y +
        transform[9] * local.z +
        transform[13],
    transform[2] * local.x +
        transform[6] * local.y +
        transform[10] * local.z +
        transform[14],
  );

  List<ScanVector3> get worldCorners => List.unmodifiable([
    for (final x in [-dimensions.x / 2, dimensions.x / 2])
      for (final y in [-dimensions.y / 2, dimensions.y / 2])
        for (final z in [-dimensions.z / 2, dimensions.z / 2])
          transformPoint(ScanVector3(x, y, z)),
  ]);

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'nativeCategory': nativeCategory,
    'dimensions': dimensions.toJson(),
    'transform': List<double>.of(transform),
    'classificationConfidence': classificationConfidence.name,
  };
}

final class ScanDistanceEstimate {
  const ScanDistanceEstimate._(this.id, this.start, this.end);
  final String id;
  final ScanVector3 start, end;
  double get metres => math.sqrt(
    math.pow(end.x - start.x, 2) +
        math.pow(end.y - start.y, 2) +
        math.pow(end.z - start.z, 2),
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'start': start.toJson(),
    'end': end.toJson(),
  };
}

final class BathroomScanScene {
  const BathroomScanScene._({
    required this.schemaVersion,
    required this.measurements,
    required this.scanId,
    required this.source,
    required this.sourceVersion,
    required this.capturedAt,
    required this.truncated,
    required this.warnings,
    required this.elements,
    required this.points,
    required this.fingerprint,
  });

  static const maxElements = 256;
  static const maxPoints = 4096;
  static const maxEncodedBytes = 512 * 1024;
  static const warningTokens = {
    'curved_surfaces_approximated',
    'geometry_omitted',
    'depth_unavailable',
    'depth_partial',
    'tracking_limited',
    'count_limit',
  };
  static final _uuidV4 = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  factory BathroomScanScene.fromJson(Object? value) {
    final schemaVersion = value is Map ? value['schemaVersion'] : null;
    if (schemaVersion is! int || (schemaVersion != 1 && schemaVersion != 2)) {
      _invalid();
    }
    final json = _object(value, {
      'schemaVersion',
      'scanId',
      'source',
      'sourceVersion',
      'capturedAt',
      'units',
      'coordinateSystem',
      'coverage',
      'truncated',
      'warnings',
      'elements',
      'points',
      if (schemaVersion == 2) 'measurements',
    });
    if (json['units'] != 'm' ||
        json['coordinateSystem'] != 'right_handed_y_up' ||
        json['coverage'] != 'partial' ||
        json['truncated'] is! bool) {
      _invalid();
    }
    final id = _text(json['scanId'], 36);
    if (!_uuidV4.hasMatch(id)) _invalid();
    final source = _choice(json['source'], ScanSource.values);
    if ((schemaVersion == 2) != (source == ScanSource.arkit)) _invalid();
    final version = _text(json['sourceVersion'], 80);
    final capturedAt = _instant(json['capturedAt']);
    final warningValues = _list(json['warnings'], 16);
    final warnings = <String>[];
    for (final raw in warningValues) {
      if (raw is! String || !warningTokens.contains(raw)) _invalid();
      warnings.add(raw);
    }
    final elements = <ScanElement>[];
    final ids = <String>{};
    for (final raw in _list(json['elements'], maxElements)) {
      final element = _object(raw, {
        'id',
        'kind',
        'nativeCategory',
        'dimensions',
        'transform',
        'classificationConfidence',
      });
      final elementId = _text(element['id'], 80);
      if (!ids.add(elementId)) _invalid();
      final kind = _choice(element['kind'], ScanElementKind.values);
      final nativeCategory = _text(element['nativeCategory'], 64);
      final dimensionValues = _fixedList(element['dimensions'], 3);
      final dimensions = dimensionValues.map((v) => _number(v, 0, 30)).toList();
      if (dimensions.where((v) => v > 0).length < 2) _invalid();
      final transform = _fixedList(
        element['transform'],
        16,
      ).map((v) => _number(v, -50, 50)).toList();
      _rigidTransform(transform);
      final confidence = _choice(
        element['classificationConfidence'],
        ScanClassificationConfidence.values,
      );
      if (source != ScanSource.roomplan &&
          (kind != ScanElementKind.unknown ||
              !(source == ScanSource.arkit
                      ? {'horizontal', 'vertical'}
                      : {
                          'horizontal_upward',
                          'horizontal_downward',
                          'vertical',
                        })
                  .contains(nativeCategory) ||
              dimensions[1] != 0 ||
              confidence != ScanClassificationConfidence.unknown)) {
        _invalid();
      }
      final result = ScanElement._(
        id: elementId,
        kind: kind,
        nativeCategory: nativeCategory,
        dimensions: ScanVector3(dimensions[0], dimensions[1], dimensions[2]),
        transform: List.unmodifiable(transform),
        classificationConfidence: confidence,
      );
      if (result.worldCorners.any(
        (p) => p.x.abs() > 50 || p.y.abs() > 50 || p.z.abs() > 50,
      )) {
        _invalid();
      }
      elements.add(result);
    }
    final points = <ScanPoint>[];
    for (final raw in _list(json['points'], maxPoints)) {
      final point = _fixedList(raw, 4);
      points.add(
        ScanPoint._(
          ScanVector3(
            _number(point[0], -50, 50),
            _number(point[1], -50, 50),
            _number(point[2], -50, 50),
          ),
          _number(point[3], 0, 1),
        ),
      );
    }
    final measurements = <ScanDistanceEstimate>[];
    if (schemaVersion == 2) {
      if (points.isNotEmpty || !warnings.contains('depth_unavailable')) {
        _invalid();
      }
      final measurementIds = <String>{};
      for (final raw in _list(json['measurements'], 20)) {
        final measurement = _object(raw, {'id', 'start', 'end'});
        final id = _text(measurement['id'], 36);
        if (!_uuidV4.hasMatch(id) || !measurementIds.add(id)) _invalid();
        ScanVector3 vector(Object? raw) {
          final coordinates = _fixedList(
            raw,
            3,
          ).map((v) => _number(v, -50, 50)).toList();
          return ScanVector3(coordinates[0], coordinates[1], coordinates[2]);
        }

        final distance = ScanDistanceEstimate._(
          id,
          vector(measurement['start']),
          vector(measurement['end']),
        );
        if (distance.metres < 0.02 || distance.metres > 10) _invalid();
        measurements.add(distance);
      }
    }
    if (elements.isEmpty && points.isEmpty) _invalid();
    final result = BathroomScanScene._(
      schemaVersion: schemaVersion,
      measurements: List.unmodifiable(measurements),
      scanId: id,
      source: source,
      sourceVersion: version,
      capturedAt: capturedAt,
      truncated: json['truncated'] as bool,
      warnings: List.unmodifiable(warnings),
      elements: List.unmodifiable(elements),
      points: List.unmodifiable(points),
      fingerprint: '',
    );
    final encoded = utf8.encode(jsonEncode(result.toJson()));
    if (encoded.length > maxEncodedBytes) _invalid();
    return BathroomScanScene._(
      schemaVersion: result.schemaVersion,
      measurements: result.measurements,
      scanId: result.scanId,
      source: result.source,
      sourceVersion: result.sourceVersion,
      capturedAt: result.capturedAt,
      truncated: result.truncated,
      warnings: result.warnings,
      elements: result.elements,
      points: result.points,
      fingerprint: sha256.convert(encoded).toString(),
    );
  }

  final int schemaVersion;
  final List<ScanDistanceEstimate> measurements;
  final String scanId;
  final ScanSource source;
  final String sourceVersion;
  final String capturedAt;
  final bool truncated;
  final List<String> warnings;
  final List<ScanElement> elements;
  final List<ScanPoint> points;

  final String fingerprint;

  String get sourceLabel => switch (source) {
    ScanSource.roomplan => 'iPhone RoomPlan',
    ScanSource.arcore => 'Android ARCore',
    ScanSource.arkit => 'iPhone ARKit camera',
  };

  ScanElement? elementById(String id) {
    for (final element in elements) {
      if (element.id == id) return element;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'scanId': scanId,
    'source': source.name,
    'sourceVersion': sourceVersion,
    'capturedAt': capturedAt,
    'units': 'm',
    'coordinateSystem': 'right_handed_y_up',
    'coverage': 'partial',
    'truncated': truncated,
    'warnings': List<String>.of(warnings),
    'elements': elements.map((e) => e.toJson()).toList(),
    'points': points.map((p) => p.toJson()).toList(),
    if (schemaVersion == 2)
      'measurements': measurements.map((m) => m.toJson()).toList(),
  };
}

Never _invalid() => throw const FormatException('Invalid bathroom scan scene');

Map<String, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      value.keys.any((key) => key is! String || !keys.contains(key))) {
    _invalid();
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, int maximum) {
  if (value is! List || value.length > maximum) _invalid();
  return value;
}

List<Object?> _fixedList(Object? value, int length) {
  final list = _list(value, length);
  if (list.length != length) _invalid();
  return list;
}

String _text(Object? value, int maximum) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      value.trim() != value ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    _invalid();
  }
  return value;
}

double _number(Object? value, double minimum, double maximum) {
  if (value is! num || !value.isFinite || value < minimum || value > maximum) {
    _invalid();
  }
  return value.toDouble();
}

T _choice<T extends Enum>(Object? value, List<T> values) {
  for (final candidate in values) {
    if (value == candidate.name) return candidate;
  }
  return _invalid();
}

String _instant(Object? value) {
  final text = _text(value, 32);
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?Z$',
  ).firstMatch(text);
  final date = DateTime.tryParse(text);
  if (match == null ||
      date == null ||
      date.year != int.parse(match[1]!) ||
      date.month != int.parse(match[2]!) ||
      date.day != int.parse(match[3]!) ||
      date.hour != int.parse(match[4]!) ||
      date.minute != int.parse(match[5]!) ||
      date.second != int.parse(match[6]!)) {
    _invalid();
  }
  return text;
}

void _rigidTransform(List<double> m) {
  const tolerance = .01;
  if (m[3].abs() > .0001 ||
      m[7].abs() > .0001 ||
      m[11].abs() > .0001 ||
      (m[15] - 1).abs() > .0001) {
    _invalid();
  }
  double dot(int a, int b) =>
      m[a] * m[b] + m[a + 1] * m[b + 1] + m[a + 2] * m[b + 2];
  for (final offset in [0, 4, 8]) {
    if ((math.sqrt(dot(offset, offset)) - 1).abs() > tolerance) _invalid();
  }
  if (dot(0, 4).abs() > tolerance ||
      dot(0, 8).abs() > tolerance ||
      dot(4, 8).abs() > tolerance) {
    _invalid();
  }
  final determinant =
      m[0] * (m[5] * m[10] - m[6] * m[9]) -
      m[4] * (m[1] * m[10] - m[2] * m[9]) +
      m[8] * (m[1] * m[6] - m[2] * m[5]);
  if ((determinant - 1).abs() > tolerance * 3) _invalid();
}
