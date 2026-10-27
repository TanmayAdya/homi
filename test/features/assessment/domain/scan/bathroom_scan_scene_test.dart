import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';

import 'scan_test_fixtures.dart';

void main() {
  test('strict scene round trip keeps geometry, confidence and provenance', () {
    final scene = fictionalScanScene();
    final restored = BathroomScanScene.fromJson(
      jsonDecode(jsonEncode(scene.toJson())),
    );
    expect(restored.toJson(), scene.toJson());
    expect(restored.fingerprint, scene.fingerprint);
    expect(restored.source, ScanSource.roomplan);
    expect(
      restored.elementById('door-1')!.classificationConfidence,
      ScanClassificationConfidence.high,
    );
    expect(restored.elementById('door-1')!.dimensions.z, 0);
    expect(restored.toJson()['coverage'], 'partial');
  });

  test(
    'scene is detached from input and all retained collections are immutable',
    () {
      final input = scanSceneJson();
      final element = (input['elements'] as List).single as Map;
      final scene = BathroomScanScene.fromJson(input);
      (element['transform'] as List)[12] = 7.0;
      (element['dimensions'] as List)[0] = 7;
      (input['elements'] as List).clear();
      expect(scene.elements.single.dimensions.x, 1);
      expect(scene.elements.single.transform[12], 0);
      expect(() => scene.elements.clear(), throwsUnsupportedError);
      expect(() => scene.points.clear(), throwsUnsupportedError);
      expect(() => scene.warnings.add('count_limit'), throwsUnsupportedError);
      expect(
        () => scene.elements.single.transform[12] = 3,
        throwsUnsupportedError,
      );
      final output = scene.toJson();
      (output['elements'] as List).clear();
      expect(scene.elements, hasLength(1));
    },
  );

  test(
    'fingerprint binds every dimension and warning, not just the scan ID',
    () {
      final first = fictionalScanScene();
      final changed = scanSceneJson(
        elements: [
          scanElementJson(dimensions: [1.1, 2, 0]),
        ],
      );
      expect(
        BathroomScanScene.fromJson(changed).fingerprint,
        isNot(first.fingerprint),
      );
      final warning = scanSceneJson()..['warnings'] = ['tracking_limited'];
      expect(
        BathroomScanScene.fromJson(warning).fingerprint,
        isNot(first.fingerprint),
      );
    },
  );

  test('column-major rigid pose transforms local coordinates in metres', () {
    final scene = fictionalScanScene(
      elements: [
        scanElementJson(
          transform: [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 3, 1, 4, 1],
        ),
      ],
    );
    final point = scene.elements.single.transformPoint(
      const ScanVector3(2, 3, 4),
    );
    expect([point.x, point.y, point.z], [7, 4, 2]);
  });

  test('ARCore raw points do not fabricate semantic objects or categories', () {
    final scene = fictionalScanScene(
      source: 'arcore',
      elements: [],
      points: [
        [1, 2, 3, .6],
        [0, 0, 0, 0],
      ],
    );
    expect(scene.elements, isEmpty);
    expect(scene.points.first.confidence, .6);
    expect(scene.points.last.confidence, 0);
    expect(scene.sourceLabel, 'Android ARCore');
  });

  test('ARCore plane has real local XZ extents and no invented thickness', () {
    final scene = fictionalScanScene(
      source: 'arcore',
      elements: [
        scanElementJson(
          kind: 'unknown',
          nativeCategory: 'vertical',
          dimensions: [1, 0, 2],
          confidence: 'unknown',
          transform: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 1, 0, 1],
        ),
      ],
    );
    expect(scene.elements.single.dimensions.y, 0);
    expect(scene.elements.single.kind, ScanElementKind.unknown);
  });

  for (final entry in <String, Object?>{
    'schemaVersion': '1',
    'scanId': 'not-a-uuid',
    'source': 'imaginary',
    'sourceVersion': '',
    'capturedAt': '2026-02-30T12:00:00Z',
    'units': 'cm',
    'coordinateSystem': 'left_handed',
    'coverage': 'complete',
    'truncated': 0,
    'warnings': ['everything_is_safe'],
  }.entries) {
    test('rejects invalid ${entry.key} rather than guessing a default', () {
      final input = scanSceneJson()..[entry.key] = entry.value;
      expect(() => BathroomScanScene.fromJson(input), throwsFormatException);
    });
  }

  test('rejects missing, unexpected and non-string keys', () {
    expect(
      () => BathroomScanScene.fromJson(scanSceneJson()..remove('points')),
      throwsFormatException,
    );
    expect(
      () => BathroomScanScene.fromJson(
        scanSceneJson()..['path'] = '/private/photo.jpg',
      ),
      throwsFormatException,
    );
    expect(() => BathroomScanScene.fromJson({1: 'bad'}), throwsFormatException);
    final element = scanElementJson()..['verified'] = true;
    expect(
      () => fictionalScanScene(elements: [element]),
      throwsFormatException,
    );
  });

  test('rejects malformed IDs, text controls and unsupported categories', () {
    for (final changed in [
      scanElementJson(id: ''),
      scanElementJson(id: ' a '),
      scanElementJson(id: 'a\n'),
      scanElementJson(id: 'x' * 81),
      scanElementJson(kind: 'safe_room'),
      scanElementJson(confidence: 'certain'),
      scanElementJson(nativeCategory: 'x' * 65),
    ]) {
      expect(
        () => fictionalScanScene(elements: [changed]),
        throwsFormatException,
      );
    }
  });

  test('rejects duplicate IDs, empty scenes, and over-limit counts', () {
    expect(
      () =>
          fictionalScanScene(elements: [scanElementJson(), scanElementJson()]),
      throwsFormatException,
    );
    expect(() => fictionalScanScene(elements: []), throwsFormatException);
    expect(
      () => fictionalScanScene(
        elements: [
          for (var i = 0; i < 257; i++) scanElementJson(id: 'element-$i'),
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => fictionalScanScene(
        elements: [],
        points: [
          for (var i = 0; i < 4097; i++) [0, 0, 0, .5],
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => BathroomScanScene.fromJson(
        scanSceneJson()..['warnings'] = List.filled(17, 'depth_partial'),
      ),
      throwsFormatException,
    );
  });

  test('enforces dimension bounds and at least two nonzero model axes', () {
    for (final dimensions in <List<num>>[
      [0, 0, 0],
      [1, 0, 0],
      [-1, 2, 0],
      [30.01, 2, 0],
      [double.nan, 2, 0],
      [1, double.infinity, 0],
      [1, 2],
    ]) {
      expect(
        () => fictionalScanScene(
          elements: [scanElementJson(dimensions: dimensions)],
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'rejects scaling, shear, reflection, perspective and distant coordinates',
    () {
      final matrices = <List<num>>[];
      matrices.add(scanTransform()..[0] = 2);
      matrices.add(scanTransform()..[4] = .2);
      matrices.add(scanTransform()..[0] = -1);
      matrices.add(scanTransform()..[3] = .1);
      matrices.add(scanTransform()..[15] = 0);
      matrices.add(scanTransform()..[12] = 51);
      matrices.add(scanTransform()..[5] = double.nan);
      matrices.add([1, 2, 3]);
      for (final transform in matrices) {
        expect(
          () => fictionalScanScene(
            elements: [scanElementJson(transform: transform)],
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'rejects invented ARCore semantics, thickness and classification confidence',
    () {
      for (final element in [
        scanElementJson(),
        scanElementJson(
          kind: 'unknown',
          nativeCategory: 'vertical',
          dimensions: [1, .01, 2],
          confidence: 'unknown',
        ),
        scanElementJson(
          kind: 'unknown',
          nativeCategory: 'vertical',
          dimensions: [1, 0, 2],
          confidence: 'high',
        ),
      ]) {
        expect(
          () => fictionalScanScene(source: 'arcore', elements: [element]),
          throwsFormatException,
        );
      }
    },
  );

  test('rejects non-finite/out-of-range points and malformed point tuples', () {
    for (final point in <List<num>>[
      [1, 2, 3],
      [1, 2, 3, 4, 5],
      [51, 0, 0, 1],
      [0, 0, 0, -1],
      [0, 0, 0, 1.01],
      [0, double.infinity, 0, .5],
    ]) {
      expect(
        () => fictionalScanScene(elements: [], points: [point]),
        throwsFormatException,
      );
    }
  });

  test(
    'UTC timestamps retain input precision but reject normalized invalid dates',
    () {
      for (final time in [
        '2026-10-23T12:00:00Z',
        '2026-10-23T12:00:00.123456Z',
      ]) {
        expect(
          BathroomScanScene.fromJson(
            scanSceneJson()..['capturedAt'] = time,
          ).capturedAt,
          time,
        );
      }
      for (final time in [
        '2026-10-23T12:00:00+00:00',
        '2026-10-23',
        '2026-10-23T24:00:00Z',
        '2026-10-23T12:60:00Z',
      ]) {
        expect(
          () => BathroomScanScene.fromJson(
            scanSceneJson()..['capturedAt'] = time,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'UTF8 size bound applies to validated geometry and multibyte strings',
    () {
      final input = scanSceneJson(
        elements: [
          for (var i = 0; i < 256; i++)
            scanElementJson(
              id: '${'界' * 76}$i',
              nativeCategory: '界' * 64,
              dimensions: [
                1.123456789012345,
                2.123456789012345,
                3.123456789012345,
              ],
              transform: [
                .5532860465935178,
                .7683789361511569,
                -.3216649827446748,
                0,
                -.3216649827446748,
                .5532860465935178,
                .7683789361511569,
                0,
                .7683789361511569,
                -.3216649827446748,
                .5532860465935178,
                0,
                1.123456789012345,
                2.123456789012345,
                3.123456789012345,
                1,
              ],
            ),
        ],
        points: [
          for (var i = 0; i < 4096; i++)
            [
              -19.123456789012347,
              -29.123456789012347,
              -39.123456789012344,
              .12345678901234567,
            ],
        ],
      );
      expect(
        utf8.encode(jsonEncode(input)).length,
        greaterThan(BathroomScanScene.maxEncodedBytes),
      );
      expect(() => BathroomScanScene.fromJson(input), throwsFormatException);
    },
  );
}
