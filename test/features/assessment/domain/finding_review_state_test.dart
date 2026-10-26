import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/review/finding_review_state.dart';

import '../support/v1_case_schema.dart';

void main() {
  test('wire values are exactly the states case.schema.json allows', () {
    final Map<String, dynamic> finding =
        (readCaseSchema()[r'$defs'] as Map<String, dynamic>)['finding']
            as Map<String, dynamic>;
    final List<dynamic> allowed =
        ((finding['properties'] as Map<String, dynamic>)['reviewState']
                as Map<String, dynamic>)['enum']
            as List<dynamic>;

    expect(
      FindingReviewState.values.map((s) => s.wireValue).toSet(),
      allowed.toSet(),
    );
    expect(FindingReviewState.values, hasLength(allowed.length));
  });

  test('fromWire round trips every state', () {
    for (final FindingReviewState state in FindingReviewState.values) {
      expect(FindingReviewState.fromWire(state.wireValue), state);
    }
  });

  test('fromWire rejects values outside the contract', () {
    for (final String value in [
      'detected',
      'corrected',
      'needsReview',
      'CONFIRMED',
      '',
    ]) {
      expect(
        () => FindingReviewState.fromWire(value),
        throwsFormatException,
        reason: value,
      );
    }
  });
}
