import 'package:flutter_test/flutter_test.dart';

import 'package:safe_at_home/features/assessment/domain/measurement/measurement_fields.dart';

void main() {
  test('every proposed field has a unique type and a definition', () {
    final List<String> types = proposedMeasurementFields
        .map((f) => f.type)
        .toList();
    expect(types.toSet().length, types.length);
    for (final MeasurementFieldSpec field in proposedMeasurementFields) {
      expect(field.definition.trim(), isNotEmpty, reason: field.type);
      expect(field.howToMeasure.trim(), isNotEmpty, reason: field.type);
    }
  });

  group('zero review prompt', () {
    test('zero clear opening prompts review', () {
      expect(
        needsZeroReviewPrompt(type: 'clearOpening', millimetres: 0),
        isTrue,
      );
    });

    test('zero threshold is plausible (flush)', () {
      expect(
        needsZeroReviewPrompt(type: 'thresholdHeight', millimetres: 0),
        isFalse,
      );
    });

    test('unknown type with zero prompts review', () {
      expect(
        needsZeroReviewPrompt(type: 'somethingNew', millimetres: 0),
        isTrue,
      );
    });

    test('non-zero values never prompt (no thresholds applied)', () {
      expect(
        needsZeroReviewPrompt(type: 'clearOpening', millimetres: 0.5),
        isFalse,
      );
      expect(
        needsZeroReviewPrompt(type: 'clearOpening', millimetres: 100000),
        isFalse,
      );
    });
  });
}
