import 'review_snapshot.dart';
import 'finding_review_state.dart';

enum ReviewEventKind {
  suggested,

  confirmed,

  confirmationCleared,

  dismissed,

  restored,

  anotherViewRequested,

  newViewAdded,
}

final class ReviewEvent {
  const ReviewEvent(this.kind, this.at);
  final ReviewEventKind kind;

  final DateTime at;
}

final class FindingReview {
  const FindingReview({
    required this.findingId,
    required this.state,
    required this.confirmedSnapshot,
    required this.anotherViewRequested,
    required this.history,
  });

  final String findingId;
  final FindingReviewState state;

  final ReviewSnapshot? confirmedSnapshot;

  final bool anotherViewRequested;

  final List<ReviewEvent> history;

  FindingReview _copyWith({
    FindingReviewState? state,
    ReviewSnapshot? confirmedSnapshot,
    bool clearConfirmedSnapshot = false,
    bool? anotherViewRequested,
    ReviewEvent? event,
  }) => FindingReview(
    findingId: findingId,
    state: state ?? this.state,
    confirmedSnapshot: clearConfirmedSnapshot
        ? null
        : (confirmedSnapshot ?? this.confirmedSnapshot),
    anotherViewRequested: anotherViewRequested ?? this.anotherViewRequested,
    history: event == null ? history : List.unmodifiable([...history, event]),
  );
}

enum ReviewRejection {
  unknownFinding,

  emptyObservation,

  dismissed,

  notDismissed,
}

final class ReviewOutcome {
  const ReviewOutcome._(this.review, this.rejection);
  const ReviewOutcome.applied(FindingReview review) : this._(review, null);
  const ReviewOutcome.rejected(FindingReview? review, ReviewRejection rejection)
    : this._(review, rejection);

  final FindingReview? review;
  final ReviewRejection? rejection;

  bool get applied => rejection == null;
}

class FindingReviewTracker {
  FindingReviewTracker({DateTime Function()? clock})
    : _clock = clock ?? (() => DateTime.now().toUtc());

  final DateTime Function() _clock;
  final Map<String, FindingReview> _reviews = {};

  FindingReview? reviewOf(String findingId) => _reviews[findingId];

  Iterable<FindingReview> get all => _reviews.values;

  FindingReview start(String findingId) {
    final FindingReview? existing = _reviews[findingId];
    if (existing != null) return existing;
    final review = FindingReview(
      findingId: findingId,
      state: FindingReviewState.needsReview,
      confirmedSnapshot: null,
      anotherViewRequested: false,
      history: List.unmodifiable([
        ReviewEvent(ReviewEventKind.suggested, _clock()),
      ]),
    );
    _reviews[findingId] = review;
    return review;
  }

  ReviewOutcome confirm(String findingId, ReviewSnapshot current) {
    final FindingReview? review = _reviews[findingId];
    if (review == null) {
      return const ReviewOutcome.rejected(null, ReviewRejection.unknownFinding);
    }
    if (review.state == FindingReviewState.dismissed) {
      return ReviewOutcome.rejected(review, ReviewRejection.dismissed);
    }
    if (!current.hasObservation) {
      return ReviewOutcome.rejected(review, ReviewRejection.emptyObservation);
    }
    return _store(
      review._copyWith(
        state: FindingReviewState.confirmed,
        confirmedSnapshot: current,
        anotherViewRequested: false,
        event: ReviewEvent(ReviewEventKind.confirmed, _clock()),
      ),
    );
  }

  ReviewOutcome contentChanged(String findingId, ReviewSnapshot current) {
    final FindingReview? review = _reviews[findingId];
    if (review == null) {
      return const ReviewOutcome.rejected(null, ReviewRejection.unknownFinding);
    }
    if (review.state != FindingReviewState.confirmed ||
        review.confirmedSnapshot == current) {
      return ReviewOutcome.applied(review);
    }
    return _store(
      review._copyWith(
        state: FindingReviewState.needsReview,
        clearConfirmedSnapshot: true,
        event: ReviewEvent(ReviewEventKind.confirmationCleared, _clock()),
      ),
    );
  }

  ReviewOutcome dismiss(String findingId) {
    final FindingReview? review = _reviews[findingId];
    if (review == null) {
      return const ReviewOutcome.rejected(null, ReviewRejection.unknownFinding);
    }
    if (review.state == FindingReviewState.dismissed) {
      return ReviewOutcome.applied(review);
    }
    return _store(
      review._copyWith(
        state: FindingReviewState.dismissed,
        clearConfirmedSnapshot: true,
        anotherViewRequested: false,
        event: ReviewEvent(ReviewEventKind.dismissed, _clock()),
      ),
    );
  }

  ReviewOutcome restore(String findingId) {
    final FindingReview? review = _reviews[findingId];
    if (review == null) {
      return const ReviewOutcome.rejected(null, ReviewRejection.unknownFinding);
    }
    if (review.state != FindingReviewState.dismissed) {
      return ReviewOutcome.rejected(review, ReviewRejection.notDismissed);
    }
    return _store(
      review._copyWith(
        state: FindingReviewState.needsReview,
        event: ReviewEvent(ReviewEventKind.restored, _clock()),
      ),
    );
  }

  ReviewOutcome requestAnotherView(String findingId) {
    final FindingReview? review = _reviews[findingId];
    if (review == null) {
      return const ReviewOutcome.rejected(null, ReviewRejection.unknownFinding);
    }
    if (review.state == FindingReviewState.dismissed) {
      return ReviewOutcome.rejected(review, ReviewRejection.dismissed);
    }
    return _store(
      review._copyWith(
        state: FindingReviewState.needsReview,
        clearConfirmedSnapshot: true,
        anotherViewRequested: true,
        event: ReviewEvent(ReviewEventKind.anotherViewRequested, _clock()),
      ),
    );
  }

  ReviewOutcome viewAdded(String findingId) {
    final FindingReview? review = _reviews[findingId];
    if (review == null) {
      return const ReviewOutcome.rejected(null, ReviewRejection.unknownFinding);
    }
    if (!review.anotherViewRequested) return ReviewOutcome.applied(review);
    return _store(
      review._copyWith(
        anotherViewRequested: false,
        event: ReviewEvent(ReviewEventKind.newViewAdded, _clock()),
      ),
    );
  }

  bool forget(String findingId) => _reviews.remove(findingId) != null;

  void clear() => _reviews.clear();

  ReviewOutcome _store(FindingReview review) {
    _reviews[review.findingId] = review;
    return ReviewOutcome.applied(review);
  }
}
