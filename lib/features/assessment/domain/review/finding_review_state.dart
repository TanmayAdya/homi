enum FindingReviewState {
  needsReview('needs_review'),
  confirmed('confirmed'),
  dismissed('dismissed');

  const FindingReviewState(this.wireValue);

  final String wireValue;

  static FindingReviewState fromWire(String wireValue) {
    for (final FindingReviewState state in values) {
      if (state.wireValue == wireValue) return state;
    }
    throw FormatException('Unknown finding review state.', wireValue);
  }
}
