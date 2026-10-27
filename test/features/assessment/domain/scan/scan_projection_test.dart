import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_projection.dart';

import 'scan_test_fixtures.dart';

void main() {
  test(
    'planar RoomPlan surface renders one face without invented thickness',
    () {
      final projection = ScanProjection.project(
        fictionalScanScene(),
        width: 400,
        height: 300,
      );
      expect(projection.faces, hasLength(1));
      expect(projection.faces.single.vertices, hasLength(4));
      expect(projection.faces.single.elementId, 'door-1');
      expect(projection.points, isEmpty);
    },
  );

  test(
    'ARCore local XZ rectangle transforms into a vertical review surface',
    () {
      final scene = fictionalScanScene(
        source: 'arcore',
        elements: [
          scanElementJson(
            kind: 'unknown',
            nativeCategory: 'vertical',
            confidence: 'unknown',
            dimensions: [1, 0, 2],
            transform: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 1, 0, 1],
          ),
        ],
      );
      final projection = ScanProjection.project(
        scene,
        width: 400,
        height: 300,
        yaw: 0,
        pitch: 0,
      );
      final points = projection.faces.single.vertices;
      expect(
        points.map((p) => p.y).reduce(math.max) -
            points.map((p) => p.y).reduce(math.min),
        closeTo(252, .00001),
      );
      expect(
        points.map((p) => p.x).reduce(math.max) -
            points.map((p) => p.x).reduce(math.min),
        closeTo(126, .00001),
      );
    },
  );

  test('cuboid has six bounded faces sorted far to near', () {
    final projection = ScanProjection.project(
      fictionalScanScene(
        elements: [
          scanElementJson(
            kind: 'sink',
            dimensions: [1, .8, .6],
            transform: scanTransform(x: 5, y: 2),
          ),
        ],
      ),
      width: 400,
      height: 300,
    );
    expect(projection.faces, hasLength(6));
    for (var i = 1; i < projection.faces.length; i++) {
      expect(
        projection.faces[i].depth,
        greaterThanOrEqualTo(projection.faces[i - 1].depth),
      );
    }
    for (final point in projection.faces.expand((f) => f.vertices)) {
      expect(point.x, inInclusiveRange(24 - 1e-8, 376 + 1e-8));
      expect(point.y, inInclusiveRange(24 - 1e-8, 276 + 1e-8));
    }
    expect(() => projection.faces.clear(), throwsUnsupportedError);
    expect(
      () => projection.faces.first.vertices.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'rotating review changes projected geometry, never the native scene',
    () {
      final scene = fictionalScanScene();
      final fingerprint = scene.fingerprint;
      final first = ScanProjection.project(
        scene,
        width: 400,
        height: 300,
        yaw: .4,
      );
      final second = ScanProjection.project(
        scene,
        width: 400,
        height: 300,
        yaw: 1.1,
      );
      expect(
        first.faces.single.vertices.first.x,
        isNot(closeTo(second.faces.single.vertices.first.x, .0001)),
      );
      expect(scene.fingerprint, fingerprint);
    },
  );

  test('single and coincident sparse points remain finite and centred', () {
    final projection = ScanProjection.project(
      fictionalScanScene(
        source: 'arcore',
        elements: [],
        points: [
          [2, 3, 4, .8],
          [2, 3, 4, .3],
        ],
      ),
      width: 200,
      height: 100,
    );
    expect(projection.faces, isEmpty);
    for (final p in projection.points) {
      expect(p.x, 100);
      expect(p.y, 50);
      expect(p.depth.isFinite, isTrue);
    }
    expect(projection.points.first.confidence, .8);
    expect(projection.points.last.confidence, .3);
  });

  test('small viewport clamps padding and cannot produce negative scale', () {
    final projection = ScanProjection.project(
      fictionalScanScene(),
      width: 10,
      height: 8,
    );
    for (final p in projection.faces.single.vertices) {
      expect(p.x, inInclusiveRange(0, 10));
      expect(p.y, inInclusiveRange(0, 8));
    }
  });

  test('rejects invalid viewport and camera values', () {
    final scene = fictionalScanScene();
    expect(
      () => ScanProjection.project(scene, width: 0, height: 300),
      throwsArgumentError,
    );
    expect(
      () => ScanProjection.project(scene, width: 400, height: double.nan),
      throwsArgumentError,
    );
    expect(
      () => ScanProjection.project(
        scene,
        width: 400,
        height: 300,
        yaw: double.infinity,
      ),
      throwsArgumentError,
    );
    expect(
      () => ScanProjection.project(scene, width: 400, height: 300, padding: -1),
      throwsArgumentError,
    );
  });
}
