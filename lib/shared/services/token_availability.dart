class RetryableTokenUnavailableException implements Exception {
  const RetryableTokenUnavailableException();
  @override
  String toString() => 'The current token is temporarily unavailable.';
}
