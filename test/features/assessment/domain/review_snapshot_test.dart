import 'package:flutter_test/flutter_test.dart';

import 'package:safe_at_home/features/assessment/domain/review/review_snapshot.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

Map<String, Object?> _opening({
  num value = 800,
  String method = 'manual',
  bool confirmed = true,
}) => {
  'type': 'clearOpening',
  'value': value,
  'unit': 'mm',
  'method': method,
  'confirmed': confirmed,
};

const _photoA = EvidenceVersion(evidenceId: 'evidence-1', version: '1');
const _photoB = EvidenceVersion(evidenceId: 'evidence-2', version: '1');

ReviewSnapshot _snap({
  String observation = 'I notice a raised threshold',
  List<EvidenceVersion> evidence = const [_photoA, _photoB],
  List<Map<String, Object?>>? measurements,
}) => ReviewSnapshot(
  observation: observation,
  evidence: evidence,
  measurements: measurements ?? [_opening()],
);

void main() {
  test('identical content is equal', () {
    expect(_snap(), _snap());
    expect(_snap().hashCode, _snap().hashCode);
  });

  test('evidence order does not matter', () {
    expect(_snap(evidence: [_photoB, _photoA]), _snap());
  });

  test('measurement order and map key order do not matter', () {
    final Map<String, Object> threshold = {
      'type': 'thresholdHeight',
      'value': 20,
      'unit': 'mm',
      'method': 'manual',
      'confirmed': false,
    };
    final Map<String, Object> reordered = {
      'confirmed': true,
      'method': 'manual',
      'unit': 'mm',
      'value': 800,
      'type': 'clearOpening',
    };
    expect(
      _snap(measurements: [threshold, reordered]),
      _snap(measurements: [_opening(), threshold]),
    );
  });

  test('integral double equals int', () {
    expect(
      _snap(measurements: [_opening(value: 800.0)]),
      _snap(measurements: [_opening()]),
    );
  });

  test('surrounding whitespace in the observation is ignored', () {
    expect(_snap(observation: '  I notice a raised threshold \n'), _snap());
  });

  group('changes that invalidate confirmation', () {
    test('observation text', () {
      expect(
        _snap(observation: 'I notice a raised threshold on the left'),
        isNot(_snap()),
      );
    });

    test('replaced image (same ID, new version)', () {
      const replaced = EvidenceVersion(evidenceId: 'evidence-1', version: '2');
      expect(_snap(evidence: [replaced, _photoB]), isNot(_snap()));
    });

    test('added image', () {
      const extra = EvidenceVersion(evidenceId: 'evidence-3', version: '1');
      expect(_snap(evidence: [_photoA, _photoB, extra]), isNot(_snap()));
    });

    test('measurement value', () {
      expect(_snap(measurements: [_opening(value: 790)]), isNot(_snap()));
    });

    test('measurement method', () {
      expect(
        _snap(measurements: [_opening(method: 'estimated')]),
        isNot(_snap()),
      );
    });

    test('measurement removed', () {
      expect(_snap(measurements: []), isNot(_snap()));
    });
  });

  test("a measurement's own confirmed flag is ignored by default", () {
    expect(_snap(measurements: [_opening(confirmed: false)]), _snap());
  });

  test('ignored keys can be changed explicitly', () {
    ReviewSnapshot strict(bool confirmed) => ReviewSnapshot(
      observation: 'x',
      evidence: const [],
      measurements: [_opening(confirmed: confirmed)],
      ignoredMeasurementKeys: const {},
    );
    expect(strict(true), isNot(strict(false)));
  });

  test('canonical form round trips', () {
    final ReviewSnapshot original = _snap();
    final restored = ReviewSnapshot.fromCanonical(original.canonical);
    expect(restored, original);
    expect(restored.observation, 'I notice a raised threshold');
  });

  test('empty observation is detected', () {
    expect(_snap(observation: '   ').hasObservation, isFalse);
  });

  group('fromFinding', () {
    Finding finding({
      String observation = 'I notice a raised threshold',
      List<String> evidenceIds = const ['evidence-1', 'evidence-2'],
      List<Map<String, Object?>>? measurements,
    }) => Finding.fromJson({
      'id': 'finding-1',
      'room': 'entrance',
      'observation': observation,
      'reviewState': 'needs_review',
      'evidenceIds': evidenceIds,
      'measurements': measurements ?? [_opening()],
    });

    const versions = {'evidence-1': '1', 'evidence-2': '1'};

    test('matches a snapshot built from the same content', () {
      expect(
        ReviewSnapshot.fromFinding(finding(), evidenceVersions: versions),
        _snap(measurements: [_opening()]),
      );
    });

    test('ignores the finding review state', () {
      final Map<String, Object?> json = finding().toJson()
        ..['reviewState'] = 'confirmed';
      expect(
        ReviewSnapshot.fromFinding(
          Finding.fromJson(json),
          evidenceVersions: versions,
        ),
        ReviewSnapshot.fromFinding(finding(), evidenceVersions: versions),
      );
    });

    test('a different evidence version gives a different snapshot', () {
      expect(
        ReviewSnapshot.fromFinding(
          finding(),
          evidenceVersions: {...versions, 'evidence-2': '2'},
        ),
        isNot(
          ReviewSnapshot.fromFinding(finding(), evidenceVersions: versions),
        ),
      );
    });

    test('a missing evidence version throws', () {
      expect(
        () => ReviewSnapshot.fromFinding(
          finding(),
          evidenceVersions: const {'evidence-1': '1'},
        ),
        throwsArgumentError,
      );
    });

    test('extra versions are ignored', () {
      expect(
        ReviewSnapshot.fromFinding(
          finding(evidenceIds: const ['evidence-1']),
          evidenceVersions: versions,
        ),
        _snap(evidence: const [_photoA], measurements: [_opening()]),
      );
    });
  });
}
