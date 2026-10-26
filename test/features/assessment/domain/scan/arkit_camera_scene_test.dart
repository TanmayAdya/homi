import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_projection.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_suggestions.dart';

import 'scan_test_fixtures.dart';

Map<String, Object?> measuredScene() =>
    scanSceneJson(source: 'arkit')
      ..['measurements'] = <Map<String, Object?>>[
        {
          'id': '2f3c7e0b-4f39-4a21-8ee1-5a8ca45fc861',
          'start': [0, 0, 0],
          'end': [1.25, 0, 0],
        },
      ];

void main() {
  test(
    'camera estimates round-trip with immutable provenance and no depth',
    () {
      final raw = measuredScene();
      final scene = BathroomScanScene.fromJson(raw);
      final restored = BathroomScanScene.fromJson(
        jsonDecode(jsonEncode(scene.toJson())),
      );
      expect(scene.sourceLabel, 'iPhone ARKit camera');
      expect(restored.fingerprint, scene.fingerprint);
      expect(scene.measurements.single.metres, 1.25);
      expect(scene.points, isEmpty);
      expect(scene.elements.single.kind, ScanElementKind.unknown);
      expect(scene.elements.single.dimensions.y, 0);
      expect(() => scene.measurements.clear(), throwsUnsupportedError);
      (raw['measurements'] as List).clear();
      expect(scene.measurements, hasLength(1));
    },
  );

  test('v1 scenes retain their original representation and fingerprints', () {
    final scene = fictionalScanScene();
    expect(scene.toJson()['schemaVersion'], 1);
    expect(scene.toJson().containsKey('measurements'), false);
    expect(
      BathroomScanScene.fromJson(scene.toJson()).fingerprint,
      scene.fingerprint,
    );
  });

  test(
    'camera geometry cannot claim LiDAR, object recognition or depth confidence',
    () {
      for (final change in <void Function(Map<String, Object?>)>[
        (json) => json['schemaVersion'] = 1,
        (json) => json['schemaVersion'] = 2.0,
        (json) => json['source'] = 'roomplan',
        (json) => json['warnings'] = <String>[],
        (json) => json['points'] = [
          [0, 0, 0, 1],
        ],
        (json) => ((json['elements'] as List).first as Map)['kind'] = 'toilet',
        (json) => ((json['elements'] as List).first as Map)['nativeCategory'] =
            'door',
        (json) =>
            ((json['elements'] as List).first
                    as Map)['classificationConfidence'] =
                'high',
      ]) {
        final json = measuredScene();
        change(json);
        expect(() => BathroomScanScene.fromJson(json), throwsFormatException);
      }
    },
  );

  test('invalid, duplicate, excessive or unbounded estimates are rejected', () {
    for (final change in <void Function(Map<String, Object?>)>[
      (m) => m['start'] = [0, 0],
      (m) => m['start'] = [double.nan, 0, 0],
      (m) => m['end'] = [50.1, 0, 0],
      (m) => m['end'] = [0.01, 0, 0],
      (m) => m['end'] = [10.1, 0, 0],
      (m) => m['id'] = 'invalid',
      (m) => m['verified'] = true,
    ]) {
      final raw = measuredScene();
      change((raw['measurements'] as List).single as Map<String, Object?>);
      expect(() => BathroomScanScene.fromJson(raw), throwsFormatException);
    }
    final duplicate = measuredScene();
    final list = duplicate['measurements'] as List;
    list.add(Map<String, Object?>.from(list.single as Map));
    expect(() => BathroomScanScene.fromJson(duplicate), throwsFormatException);
    final excessive = measuredScene();
    excessive['measurements'] = List.filled(
      21,
      (excessive['measurements'] as List).single,
    );
    expect(() => BathroomScanScene.fromJson(excessive), throwsFormatException);
  });

  test(
    'changed endpoints change identity and project as numbered review lines',
    () {
      final first = BathroomScanScene.fromJson(measuredScene());
      final raw = measuredScene();
      ((raw['measurements'] as List).single as Map)['end'] = [0, 0, 1.25];
      final second = BathroomScanScene.fromJson(raw);
      expect(first.fingerprint, isNot(second.fingerprint));
      final projection = ScanProjection.project(first, width: 320, height: 300);
      expect(projection.distances, hasLength(1));
      final (a, b) = projection.distances.single;
      expect((a.x - b.x).abs() + (a.y - b.y).abs(), greaterThan(0));
      expect([a.x, b.x].every((v) => v >= 0 && v <= 320), true);
      expect([a.y, b.y].every((v) => v >= 0 && v <= 300), true);
    },
  );

  test(
    'surface estimates alone create no findings; reviewed labels retain camera provenance',
    () {
      final scene = BathroomScanScene.fromJson(measuredScene());
      expect(
        suggestBathroomImprovements(
          scene: scene,
          reviewedElementIds: {'plane-1'},
          difficulties: {ScanDifficulty.enteringBathroom},
        ),
        isEmpty,
      );
      final ideas = suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: {'plane-1'},
        difficulties: {ScanDifficulty.enteringBathroom},
        identifiedKinds: {'plane-1': ScanElementKind.door},
      );
      expect(ideas.single.observation, contains('iPhone ARKit camera'));
      expect(ideas.single.observation, contains('not a verified measurement'));
      expect(scene.elements.single.kind, ScanElementKind.unknown);
    },
  );
}
