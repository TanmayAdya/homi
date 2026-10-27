import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_projection.dart';
import 'package:safe_at_home/features/assessment/domain/scan/whole_home_model.dart';
import 'scan_test_fixtures.dart';

void main() {
  test(
    'existing Unicode room IDs round-trip and feature namespaces cannot collide',
    () {
      final scene = fictionalScanScene();
      const id = 'kitchen/with unicode 厨房';
      final model = WholeHomeModel(
        referenceRoomId: id,
        method: 'reviewed_alignment',
        rooms: [
          HomeRoomPlacement(
            roomId: id,
            fingerprint: scene.fingerprint,
            pose: RoomPose(),
            reviewed: true,
          ),
        ],
      );
      final restored = WholeHomeModel.fromJson(model.toJson('case'), 'case');
      expect(restored.referenceRoomId, id);
      expect(
        PlacedRoomScene('a/b', scene, RoomPose()).featureId('c'),
        isNot(PlacedRoomScene('a', scene, RoomPose()).featureId('b/c')),
      );
    },
  );
  final a = fictionalScanScene();
  test(
    'ARCore native assembly stays partial, round-trips and cannot masquerade as RoomPlan',
    () {
      final first = fictionalScanScene(
        source: 'arcore',
        elements: [
          scanElementJson(
            kind: 'unknown',
            nativeCategory: 'vertical',
            dimensions: [2, 0, 3],
            confidence: 'unknown',
          ),
        ],
      );
      final second = BathroomScanScene.fromJson({
        ...scanSceneJson(
          source: 'arcore',
          elements: [
            scanElementJson(
              kind: 'unknown',
              nativeCategory: 'vertical',
              dimensions: [2, 0, 3],
              confidence: 'unknown',
            ),
          ],
        ),
        'scanId': 'ccdad592-690d-484f-bbc5-872db7b3fe23',
      });
      final placements = [
        HomeRoomPlacement(
          roomId: 'a',
          fingerprint: first.fingerprint,
          pose: RoomPose(),
          reviewed: true,
        ),
        HomeRoomPlacement(
          roomId: 'b',
          fingerprint: second.fingerprint,
          parentId: 'a',
          parentFingerprint: first.fingerprint,
          pose: RoomPose(),
          reviewed: true,
        ),
      ];
      final model = WholeHomeModel(
        referenceRoomId: 'a',
        method: 'arcore_shared_frame',
        rooms: placements,
        captures: {'a': first, 'b': second},
        mergedScene: first,
      );
      expect(model.resolve({}, {'a', 'b'}), hasLength(2));
      expect(model.resolve({'a': a}, {'a', 'b'}), isEmpty);
      expect(
        WholeHomeModel.fromJson(
          model.toJson('case'),
          'case',
        ).mergedScene!.source,
        ScanSource.arcore,
      );
      expect(
        () => WholeHomeModel(
          referenceRoomId: 'a',
          method: 'roomplan_shared_frame',
          rooms: placements,
          captures: {'a': first, 'b': second},
          mergedScene: first,
        ),
        throwsFormatException,
      );
    },
  );
  final b = BathroomScanScene.fromJson({
    ...scanSceneJson(),
    'scanId': 'ccdad592-690d-484f-bbc5-872db7b3fe23',
  });
  HomeRoomPlacement root({String? fingerprint}) => HomeRoomPlacement(
    roomId: 'a',
    fingerprint: fingerprint ?? a.fingerprint,
    pose: RoomPose(),
    reviewed: true,
  );
  HomeRoomPlacement child(
    String id,
    String parent,
    String fp,
    String parentFp, {
    bool reviewed = true,
  }) => HomeRoomPlacement(
    roomId: id,
    fingerprint: fp,
    parentId: parent,
    parentFingerprint: parentFp,
    pose: RoomPose(x: 3, y: 2, yaw: 90),
    reviewed: reviewed,
  );
  test(
    'rigid placement preserves metre distances and composes in parent axes',
    () {
      final parent = RoomPose(x: 4, y: 1, z: 2, yaw: 90);
      final placed = parent.compose(RoomPose(x: 2, y: 3, z: 1, yaw: -90));
      expect(placed.x, closeTo(5, 1e-9));
      expect(placed.y, 4);
      expect(placed.z, closeTo(0, 1e-9));
      expect(placed.yaw, 0);
      final p = parent.apply(const ScanVector3(1, 0, 0));
      final q = parent.apply(const ScanVector3(2, 0, 0));
      expect(q.z - p.z, closeTo(-1, 1e-9));
      for (final value in [double.nan, double.infinity, 101.0]) {
        expect(() => RoomPose(x: value), throwsFormatException);
      }
      expect(() => RoomPose(yaw: 181), throwsFormatException);
    },
  );
  test(
    'reviewed connected paths only; a changed source invalidates descendants',
    () {
      final model = WholeHomeModel(
        referenceRoomId: 'a',
        method: 'reviewed_alignment',
        rooms: [
          root(),
          child('b', 'a', b.fingerprint, a.fingerprint),
          child('c', 'b', a.fingerprint, b.fingerprint),
        ],
      );
      expect(
        model.resolve({'a': a, 'b': b, 'c': a}, {'a', 'b', 'c'}).length,
        3,
      );
      expect(model.resolve({'a': b, 'b': b, 'c': a}, {'a', 'b', 'c'}), isEmpty);
      expect(
        model
            .resolve({'a': a, 'b': a, 'c': a}, {'a', 'b', 'c'})
            .map((r) => r.roomId),
        ['a'],
      );
      expect(
        model
            .resolve({'a': a, 'b': b, 'c': a}, {'a', 'c'})
            .map((r) => r.roomId),
        ['a'],
      );
      final unreviewed = WholeHomeModel(
        referenceRoomId: 'a',
        method: 'reviewed_alignment',
        rooms: [
          root(),
          child('b', 'a', b.fingerprint, a.fingerprint, reviewed: false),
        ],
      );
      expect(unreviewed.resolve({'a': a, 'b': b}, {'a', 'b'}).length, 1);
    },
  );
  test(
    'cycles, dangling parents, wrong case, unknown keys and non-rigid roots fail closed',
    () {
      expect(
        () => WholeHomeModel(
          referenceRoomId: 'a',
          method: 'reviewed_alignment',
          rooms: [
            root(),
            child('b', 'c', b.fingerprint, a.fingerprint),
            child('c', 'b', a.fingerprint, b.fingerprint),
          ],
        ),
        throwsFormatException,
      );
      expect(
        () => WholeHomeModel(
          referenceRoomId: 'a',
          method: 'reviewed_alignment',
          rooms: [root(), child('b', 'missing', b.fingerprint, a.fingerprint)],
        ),
        throwsFormatException,
      );
      final model = WholeHomeModel(
        referenceRoomId: 'a',
        method: 'reviewed_alignment',
        rooms: [root()],
      );
      final json = model.toJson('fictional-case');
      expect(
        () => WholeHomeModel.fromJson(json, 'other-case'),
        throwsFormatException,
      );
      expect(
        () =>
            WholeHomeModel.fromJson({...json, 'extra': true}, 'fictional-case'),
        throwsFormatException,
      );
      final restored = WholeHomeModel.fromJson(json, 'fictional-case');
      expect(restored.toJson('fictional-case'), json);
    },
  );
  test(
    'one combined projection fits both rooms without ID collision or source mutation',
    () {
      final before = a.toJson();
      final projection = ScanProjection.project(
        a,
        width: 600,
        height: 300,
        yaw: 0,
        pitch: 0,
        placedRooms: [
          PlacedRoomScene('a', a, RoomPose()),
          PlacedRoomScene('b', b, RoomPose(x: 4)),
        ],
      );
      expect(projection.faces.map((f) => f.elementId).toSet(), {
        'a/door-1',
        'b/door-1',
      });
      final first = projection.faces.firstWhere(
        (f) => f.elementId == 'a/door-1',
      );
      final second = projection.faces.firstWhere(
        (f) => f.elementId == 'b/door-1',
      );
      expect(first.vertices.first.x, lessThan(second.vertices.first.x));
      expect(a.toJson(), before);
    },
  );
  test(
    'native shared-frame proposals require review and invalidate when baseline scans change',
    () {
      final model = WholeHomeModel(
        referenceRoomId: 'a',
        method: 'roomplan_shared_frame',
        captures: {'a': a, 'b': b},
        mergedScene: a,
        rooms: [
          root(),
          HomeRoomPlacement(
            roomId: 'b',
            parentId: 'a',
            parentFingerprint: a.fingerprint,
            fingerprint: b.fingerprint,
            pose: RoomPose(),
            reviewed: true,
          ),
        ],
      );
      expect(model.resolve({}, {'a', 'b'}).length, 2);
      expect(model.resolve({'a': a}, {'a', 'b'}), isEmpty);
      final restored = WholeHomeModel.fromJson(model.toJson('case'), 'case');
      expect(restored.captures['b']!.fingerprint, b.fingerprint);
    },
  );
}
