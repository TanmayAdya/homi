import 'package:flutter_test/flutter_test.dart';

import 'package:safe_at_home/features/assessment/domain/review/finding_review_tracker.dart';
import 'package:safe_at_home/features/assessment/domain/review/review_snapshot.dart';
import 'package:safe_at_home/features/assessment/domain/review/finding_review_state.dart';

ReviewSnapshot _snap(String observation, {String photoVersion = '1'}) =>
    ReviewSnapshot(
      observation: observation,
      evidence: [
        EvidenceVersion(evidenceId: 'evidence-1', version: photoVersion),
      ],
      measurements: const [],
    );

void main() {
  late FindingReviewTracker tracker;
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2026, 10, 18, 9);
    tracker = FindingReviewTracker(
      clock: () {
        now = now.add(const Duration(minutes: 1));
        return now;
      },
    );
  });

  test('a new finding starts as needs_review', () {
    final FindingReview review = tracker.start('finding-1');
    expect(review.state, FindingReviewState.needsReview);
    expect(review.confirmedSnapshot, isNull);
    expect(review.history.single.kind, ReviewEventKind.suggested);
  });

  test('starting twice keeps the existing review', () {
    tracker.start('finding-1');
    tracker.confirm('finding-1', _snap('Raised threshold'));
    expect(tracker.start('finding-1').state, FindingReviewState.confirmed);
  });

  group('confirm', () {
    test('records exactly what was confirmed', () {
      tracker.start('finding-1');
      final ReviewOutcome outcome = tracker.confirm(
        'finding-1',
        _snap('Raised threshold'),
      );
      expect(outcome.applied, isTrue);
      expect(outcome.review!.state, FindingReviewState.confirmed);
      expect(outcome.review!.confirmedSnapshot, _snap('Raised threshold'));
    });

    test('requires an observation', () {
      tracker.start('finding-1');
      final ReviewOutcome outcome = tracker.confirm('finding-1', _snap('   '));
      expect(outcome.rejection, ReviewRejection.emptyObservation);
      expect(
        tracker.reviewOf('finding-1')!.state,
        FindingReviewState.needsReview,
      );
    });

    test('unknown finding is rejected', () {
      expect(
        tracker.confirm('nope', _snap('x')).rejection,
        ReviewRejection.unknownFinding,
      );
    });

    test('a dismissed finding must be restored first', () {
      tracker.start('finding-1');
      tracker.dismiss('finding-1');
      expect(
        tracker.confirm('finding-1', _snap('x')).rejection,
        ReviewRejection.dismissed,
      );
    });
  });

  group('content changes', () {
    setUp(() {
      tracker.start('finding-1');
      tracker.confirm('finding-1', _snap('Raised threshold'));
    });

    test('unchanged content keeps confirmation', () {
      final ReviewOutcome outcome = tracker.contentChanged(
        'finding-1',
        _snap('Raised threshold'),
      );
      expect(outcome.review!.state, FindingReviewState.confirmed);
    });

    test('edited observation withdraws confirmation but keeps the ID', () {
      final ReviewOutcome outcome = tracker.contentChanged(
        'finding-1',
        _snap('Raised threshold, left side'),
      );
      expect(outcome.review!.findingId, 'finding-1');
      expect(outcome.review!.state, FindingReviewState.needsReview);
      expect(outcome.review!.confirmedSnapshot, isNull);
      expect(
        outcome.review!.history.last.kind,
        ReviewEventKind.confirmationCleared,
      );
    });

    test('replaced image withdraws confirmation', () {
      final ReviewOutcome outcome = tracker.contentChanged(
        'finding-1',
        _snap('Raised threshold', photoVersion: '2'),
      );
      expect(outcome.review!.state, FindingReviewState.needsReview);
    });

    test('confirming the new content works', () {
      tracker.contentChanged('finding-1', _snap('Edited'));
      final ReviewOutcome outcome = tracker.confirm(
        'finding-1',
        _snap('Edited'),
      );
      expect(outcome.review!.state, FindingReviewState.confirmed);
    });
  });

  group('another view', () {
    test('withdraws confirmation and flags the finding', () {
      tracker.start('finding-1');
      tracker.confirm('finding-1', _snap('Partly obscured'));
      final ReviewOutcome outcome = tracker.requestAnotherView('finding-1');
      expect(outcome.review!.state, FindingReviewState.needsReview);
      expect(outcome.review!.anotherViewRequested, isTrue);
      expect(outcome.review!.confirmedSnapshot, isNull);
    });

    test('adding the view clears the flag only', () {
      tracker.start('finding-1');
      tracker.requestAnotherView('finding-1');
      final ReviewOutcome outcome = tracker.viewAdded('finding-1');
      expect(outcome.review!.anotherViewRequested, isFalse);
      expect(outcome.review!.state, FindingReviewState.needsReview);
      expect(outcome.review!.history.last.kind, ReviewEventKind.newViewAdded);
    });

    test('confirming anyway clears the request', () {
      tracker.start('finding-1');
      tracker.requestAnotherView('finding-1');
      final ReviewOutcome outcome = tracker.confirm(
        'finding-1',
        _snap('Confirmed without new view'),
      );
      expect(outcome.review!.anotherViewRequested, isFalse);
    });

    test('not allowed on a dismissed finding', () {
      tracker.start('finding-1');
      tracker.dismiss('finding-1');
      expect(
        tracker.requestAnotherView('finding-1').rejection,
        ReviewRejection.dismissed,
      );
    });
  });

  group('dismiss and restore', () {
    test('dismiss clears confirmation', () {
      tracker.start('finding-1');
      tracker.confirm('finding-1', _snap('x'));
      final ReviewOutcome outcome = tracker.dismiss('finding-1');
      expect(outcome.review!.state, FindingReviewState.dismissed);
      expect(outcome.review!.confirmedSnapshot, isNull);
    });

    test('restore returns to needs_review', () {
      tracker.start('finding-1');
      tracker.dismiss('finding-1');
      expect(
        tracker.restore('finding-1').review!.state,
        FindingReviewState.needsReview,
      );
    });

    test('restore only applies to dismissed findings', () {
      tracker.start('finding-1');
      expect(
        tracker.restore('finding-1').rejection,
        ReviewRejection.notDismissed,
      );
    });
  });

  test('history is ordered and uses the injected clock', () {
    tracker.start('finding-1');
    tracker.confirm('finding-1', _snap('x'));
    tracker.contentChanged('finding-1', _snap('y'));
    final List<ReviewEvent> history = tracker.reviewOf('finding-1')!.history;
    expect(history.map((e) => e.kind), [
      ReviewEventKind.suggested,
      ReviewEventKind.confirmed,
      ReviewEventKind.confirmationCleared,
    ]);
    expect(history.first.at, DateTime.utc(2026, 10, 18, 9, 1));
    expect(history.last.at.isAfter(history.first.at), isTrue);
  });

  test('history cannot be modified from outside', () {
    final FindingReview review = tracker.start('finding-1');
    expect(
      () => review.history.add(ReviewEvent(ReviewEventKind.confirmed, now)),
      throwsUnsupportedError,
    );
  });

  test('wire values match the v1 contract states', () {
    expect(FindingReviewState.values.map((s) => s.wireValue), [
      'needs_review',
      'confirmed',
      'dismissed',
    ]);
  });

  test('forget and clear stop tracking', () {
    tracker.start('finding-1');
    tracker.start('finding-2');
    expect(tracker.forget('finding-1'), isTrue);
    expect(tracker.reviewOf('finding-1'), isNull);
    tracker.clear();
    expect(tracker.all, isEmpty);
  });
}
