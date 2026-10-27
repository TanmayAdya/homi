import 'dart:math' as math;
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_suggestions.dart';

import 'scan_test_fixtures.dart';

void main() {
  test(
    'room suggestions are scoped, rename-stable and do not apply bathroom rules elsewhere',
    () {
      final scene = fictionalScanScene(
        elements: [
          scanElementJson(),
          scanElementJson(id: 'tub', kind: 'bathtub'),
          scanElementJson(id: 'toilet', kind: 'toilet'),
        ],
      );
      List<ScanSuggestion> suggestions(
        String id,
        String name,
        AssessmentLocation type,
      ) => suggestBathroomImprovements(
        scene: scene,
        room: RoomInstance(id: id, type: type, name: name),
        reviewedElementIds: scene.elements.map((e) => e.id).toSet(),
        difficulties: ScanDifficulty.values.toSet(),
      );
      final first = suggestions(
        'bed-one',
        'Bedroom',
        AssessmentLocation.bedroom,
      );
      expect(
        first.any(
          (s) => s.ruleId.contains('bathing') || s.ruleId.contains('toilet'),
        ),
        false,
      );
      expect(
        first.any(
          (s) => s.title.contains('bathroom') || s.detail.contains('bathroom'),
        ),
        false,
      );
      expect(
        first.map((s) => s.id),
        suggestions(
          'bed-one',
          'Renamed',
          AssessmentLocation.bedroom,
        ).map((s) => s.id),
      );
      expect(
        first
            .map((s) => s.id)
            .toSet()
            .intersection(
              suggestions(
                'bed-two',
                'Bedroom',
                AssessmentLocation.bedroom,
              ).map((s) => s.id).toSet(),
            ),
        isEmpty,
      );
      expect(first.every((s) => s.room!.id == 'bed-one'), true);
      expect(
        suggestions(
          'bath-one',
          'Bathroom',
          AssessmentLocation.bathroom,
        ).any((s) => s.ruleId == 'bathroom.bathing_report'),
        true,
      );
    },
  );

  test(
    'unreviewed geometry cannot produce suggestions even with reported difficulty',
    () {
      expect(
        suggestBathroomImprovements(
          scene: fictionalScanScene(),
          reviewedElementIds: {},
          difficulties: ScanDifficulty.values.toSet(),
        ),
        isEmpty,
      );
    },
  );

  test(
    'an unanswered difficulty does not fabricate a concern from doorway width',
    () {
      for (final width in [.1, .8, 2.0]) {
        final scene = fictionalScanScene(
          elements: [
            scanElementJson(dimensions: [width, 2, 0]),
          ],
        );
        expect(
          suggestBathroomImprovements(
            scene: scene,
            reviewedElementIds: {'door-1'},
            difficulties: {},
          ),
          isEmpty,
        );
      }
    },
  );

  test(
    'each reviewed semantic object and affirmative report produces the appropriate action',
    () {
      final scene = fictionalScanScene(
        elements: [
          scanElementJson(),
          scanElementJson(
            id: 'tub',
            kind: 'bathtub',
            dimensions: [1, 1, 2],
            transform: scanTransform(x: 3, y: .5),
          ),
          scanElementJson(
            id: 'toilet',
            kind: 'toilet',
            dimensions: [.5, 1, .5],
            transform: scanTransform(x: 4, y: .5),
          ),
          scanElementJson(
            id: 'sink',
            kind: 'sink',
            dimensions: [.6, .8, .5],
            transform: scanTransform(x: 5, y: .4),
          ),
        ],
      );
      final suggestions = suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: scene.elements.map((e) => e.id).toSet(),
        difficulties: ScanDifficulty.values.toSet(),
      );
      expect(
        suggestions.map((s) => s.ruleId),
        unorderedEquals([
          'bathroom.doorway_report',
          'bathroom.bathing_report',
          'bathroom.toilet_report',
          'bathroom.sink_report',
          'bathroom.movement_report',
        ]),
      );
      for (final suggestion in suggestions) {
        expect(
          suggestion.observation,
          contains('resident-reviewed identification'),
        );
        expect(suggestion.observation, contains('iPhone RoomPlan'));
        expect(suggestion.observation, contains(scene.scanId));
        expect(
          suggestion.observation,
          contains('Scene SHA-256: ${scene.fingerprint}'),
        );
        expect(suggestion.observation, contains('Model elements:'));
        expect(suggestion.observation.length, lessThanOrEqualTo(1200));
        expect(suggestion.observation, contains('not a verified measurement'));
        expect(suggestion.sceneFingerprint, scene.fingerprint);
        expect(suggestion.ruleVersion, '1');
      }
    },
  );

  test(
    'no report of bathing difficulty is inferred from a toilet or an unknown object',
    () {
      final scene = fictionalScanScene(
        elements: [
          scanElementJson(id: 'toilet', kind: 'toilet'),
          scanElementJson(id: 'surface', kind: 'unknown'),
        ],
      );
      expect(
        suggestBathroomImprovements(
          scene: scene,
          reviewedElementIds: {'toilet', 'surface'},
          difficulties: {ScanDifficulty.bathing, ScanDifficulty.sinkUse},
        ),
        isEmpty,
      );
    },
  );

  test(
    'ARCore user labeling enables an action without rewriting native geometry',
    () {
      final scene = fictionalScanScene(
        source: 'arcore',
        elements: [
          scanElementJson(
            id: 'plane',
            kind: 'unknown',
            nativeCategory: 'vertical',
            dimensions: [1, 0, 2],
            confidence: 'unknown',
            transform: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 1, 0, 1],
          ),
        ],
      );
      expect(
        suggestBathroomImprovements(
          scene: scene,
          reviewedElementIds: {'plane'},
          difficulties: {ScanDifficulty.sinkUse},
        ),
        isEmpty,
      );
      final suggestions = suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: {'plane'},
        difficulties: {ScanDifficulty.sinkUse},
        identifiedKinds: {'plane': ScanElementKind.sink},
      );
      expect(suggestions.single.ruleId, 'bathroom.sink_report');
      expect(suggestions.single.basis, startsWith('Your identification: sink'));
      expect(suggestions.single.observation, contains('Android ARCore'));
      expect(scene.elements.single.kind, ScanElementKind.unknown);
      expect(scene.elements.single.dimensions.y, 0);
    },
  );

  test('point-only captures cannot invent a floor or a verified layout', () {
    final scene = fictionalScanScene(
      source: 'arcore',
      elements: [],
      points: [
        [0, 0, 0, .9],
      ],
    );
    expect(
      suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: {},
        difficulties: ScanDifficulty.values.toSet(),
      ),
      isEmpty,
    );
  });

  test(
    'movement report can use a reviewed unknown plane but never claims route clearance',
    () {
      final scene = fictionalScanScene(
        elements: [scanElementJson(kind: 'unknown')],
      );
      final suggestion = suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: {'door-1'},
        difficulties: {ScanDifficulty.movingAround},
      ).single;
      expect(suggestion.ruleId, 'bathroom.movement_report');
      expect(
        suggestion.nextAction,
        contains('does not prove the route is clear'),
      );
    },
  );

  test('stale review IDs or unreviewed label overrides are rejected', () {
    final scene = fictionalScanScene();
    expect(
      () => suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: {'previous-scene-element'},
        difficulties: {},
      ),
      throwsArgumentError,
    );
    expect(
      () => suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: {},
        difficulties: {},
        identifiedKinds: {'door-1': ScanElementKind.sink},
      ),
      throwsArgumentError,
    );
  });

  test(
    'identities remain stable on exact retries and change with geometry or meaning',
    () {
      List<ScanSuggestion> make(BathroomScanScene scene) =>
          suggestBathroomImprovements(
            scene: scene,
            reviewedElementIds: {'door-1'},
            difficulties: {ScanDifficulty.enteringBathroom},
          );
      final first = make(fictionalScanScene()).single;
      expect(make(fictionalScanScene()).single.id, first.id);
      final changed = fictionalScanScene(
        elements: [
          scanElementJson(dimensions: [1.1, 2, 0]),
        ],
      );
      expect(make(changed).single.id, isNot(first.id));
      final relabeled = suggestBathroomImprovements(
        scene: fictionalScanScene(),
        reviewedElementIds: {'door-1'},
        difficulties: {ScanDifficulty.sinkUse},
        identifiedKinds: {'door-1': ScanElementKind.sink},
      ).single;
      expect(relabeled.id, isNot(first.id));
      expect(
        () => relabeled.relatedElementIds.add('other'),
        throwsUnsupportedError,
      );
      expect(() => make(fictionalScanScene()).clear(), throwsUnsupportedError);
    },
  );

  test(
    'full provenance fits the packet limit even for longest escaped element IDs',
    () {
      final doorId = '\\' * 80, itemId = '"' * 80;
      final scene = fictionalScanScene(
        elements: [
          scanElementJson(id: doorId),
          scanElementJson(
            id: itemId,
            kind: 'furniture',
            dimensions: [.6, .8, .6],
            transform: scanTransform(y: .4),
          ),
        ],
      );
      final suggestion = suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: {doorId, itemId},
        difficulties: {},
      ).single;
      expect(suggestion.observation.length, lessThanOrEqualTo(1200));
      expect(suggestion.observation, contains(scene.fingerprint));
      expect(suggestion.relatedElementIds, [doorId, itemId]);
    },
  );

  group('modeled doorway overlap candidate', () {
    test(
      '256 reviewed elements without intersections remain a negative result',
      () {
        final scene = fictionalScanScene(
          elements: [
            for (var i = 0; i < 128; i++) scanElementJson(id: 'door-$i'),
            for (var i = 0; i < 128; i++)
              scanElementJson(
                id: 'item-$i',
                kind: 'furniture',
                dimensions: [.6, .8, .6],
                transform: scanTransform(x: 3, y: .4, z: 3),
              ),
          ],
        );
        expect(
          suggestBathroomImprovements(
            scene: scene,
            reviewedElementIds: scene.elements.map((e) => e.id).toSet(),
            difficulties: {},
          ),
          isEmpty,
        );
      },
    );

    test(
      'local XZ doorway plane uses its transformed vertical and horizontal axes',
      () {
        final scene = fictionalScanScene(
          elements: [
            scanElementJson(
              id: 'plane-door',
              kind: 'unknown',
              dimensions: [1, 0, 2],
              transform: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 1, 0, 1],
            ),
            scanElementJson(
              id: 'item',
              kind: 'furniture',
              dimensions: [.6, .8, .6],
              transform: scanTransform(y: .4),
            ),
          ],
        );
        expect(
          suggestBathroomImprovements(
            scene: scene,
            reviewedElementIds: {'plane-door', 'item'},
            difficulties: {},
            identifiedKinds: {'plane-door': ScanElementKind.door},
          ).single.ruleId,
          'bathroom.modeled_doorway_overlap',
        );
      },
    );

    test(
      'ARCore plane labels never fabricate a volumetric object footprint',
      () {
        final pose = [
          1.0,
          0.0,
          0.0,
          0.0,
          0.0,
          .000001,
          -1.0,
          0.0,
          0.0,
          1.0,
          .000001,
          0.0,
          0.0,
          1.0,
          0.0,
          1.0,
        ];
        final scene = fictionalScanScene(
          source: 'arcore',
          elements: [
            scanElementJson(
              id: 'door-plane',
              kind: 'unknown',
              nativeCategory: 'vertical',
              dimensions: [1, 0, 2],
              confidence: 'unknown',
              transform: pose,
            ),
            scanElementJson(
              id: 'item-plane',
              kind: 'unknown',
              nativeCategory: 'vertical',
              dimensions: [.6, 0, .8],
              confidence: 'unknown',
              transform: pose,
            ),
          ],
        );
        expect(
          suggestBathroomImprovements(
            scene: scene,
            reviewedElementIds: {'door-plane', 'item-plane'},
            difficulties: {},
            identifiedKinds: {
              'door-plane': ScanElementKind.door,
              'item-plane': ScanElementKind.furniture,
            },
          ),
          isEmpty,
        );
      },
    );

    test(
      '256 overlapping elements produce at most 20 deterministic review prompts',
      () {
        final scene = fictionalScanScene(
          elements: [
            for (var i = 0; i < 128; i++) scanElementJson(id: 'door-$i'),
            for (var i = 0; i < 128; i++)
              scanElementJson(
                id: 'item-$i',
                kind: 'furniture',
                dimensions: [.6, .8, .6],
                transform: scanTransform(y: .4),
              ),
          ],
        );
        final ids = scene.elements.map((e) => e.id).toSet();
        final first = suggestBathroomImprovements(
          scene: scene,
          reviewedElementIds: ids,
          difficulties: {},
        );
        final repeated = suggestBathroomImprovements(
          scene: scene,
          reviewedElementIds: ids.toList().reversed.toSet(),
          difficulties: {},
        );
        expect(first, hasLength(maxScanSuggestions));
        expect(first.map((s) => s.id), repeated.map((s) => s.id));
      },
    );

    test('reported difficulties also respect the shared prompt limit', () {
      final scene = fictionalScanScene(
        elements: [
          for (var i = 0; i < 256; i++) scanElementJson(id: 'door-$i'),
        ],
      );
      expect(
        suggestBathroomImprovements(
          scene: scene,
          reviewedElementIds: scene.elements.map((e) => e.id).toSet(),
          difficulties: ScanDifficulty.values.toSet(),
        ),
        hasLength(maxScanSuggestions),
      );
    });

    List<ScanSuggestion> overlaps({
      List<num>? doorTransform,
      List<num>? objectTransform,
      List<num> objectDimensions = const [.6, .8, .6],
      Set<String> reviewed = const {'door-1', 'item'},
    }) {
      final scene = fictionalScanScene(
        elements: [
          scanElementJson(transform: doorTransform),
          scanElementJson(
            id: 'item',
            kind: 'furniture',
            dimensions: objectDimensions,
            transform: objectTransform ?? scanTransform(x: .2, y: .4),
          ),
        ],
      );
      return suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: reviewed,
        difficulties: {},
      );
    }

    test(
      'a reviewed object crossing the doorway span produces a review candidate',
      () {
        final suggestion = overlaps().single;
        expect(suggestion.ruleId, 'bathroom.modeled_doorway_overlap');
        expect(suggestion.relatedElementIds, ['door-1', 'item']);
        expect(suggestion.title, contains('possible'));
        expect(
          suggestion.observation,
          contains('may reflect scan approximation'),
        );
        expect(
          suggestion.basis,
          contains('not a clearance or legal threshold'),
        );
      },
    );

    test('a nearby object away from the span does not qualify', () {
      expect(
        overlaps(objectTransform: scanTransform(x: .2, y: .4, z: 1)),
        isEmpty,
      );
    });

    test('touching the span or its endpoint does not qualify', () {
      expect(overlaps(objectTransform: scanTransform(y: .4, z: .3)), isEmpty);
      expect(overlaps(objectTransform: scanTransform(x: .8, y: .4)), isEmpty);
    });

    test('an overhead object with no overlapping height does not qualify', () {
      expect(overlaps(objectTransform: scanTransform(y: 4)), isEmpty);
    });

    test('unreviewed geometry is never used to assert a modeled conflict', () {
      expect(overlaps(reviewed: {'door-1'}), isEmpty);
      expect(overlaps(reviewed: {'item'}), isEmpty);
    });

    test('rotated doorway and fixture use transformed geometry', () {
      expect(
        overlaps(
          doorTransform: scanTransform(y: 1, yaw: math.pi / 2),
          objectTransform: scanTransform(y: .4, z: .2, yaw: math.pi / 4),
        ),
        hasLength(1),
      );
    });

    test(
      'a sloping or horizontal doorway label is too ambiguous for the check',
      () {
        expect(
          overlaps(
            doorTransform: [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1, 0, 1],
          ),
          isEmpty,
        );
      },
    );

    test(
      'zero-area object footprint does not become an invented obstruction',
      () {
        expect(overlaps(objectDimensions: [.6, .8, 0]), isEmpty);
      },
    );
  });
}
