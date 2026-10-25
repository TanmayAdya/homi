extension DoubleExtensions on double {
  bool isAlmostIdentical(double another, {double error = 1e-10}) {
    return (this - another).abs() < error;
  }

  bool isAlmostIdenticalRationally(double another, {double error = 1e-10}) {
    assert(this > 0 && another > 0);
    final d = this > another ? this / another : another / this;
    return d - 1 < error;
  }

  double round10BitFrac() {
    if (isInfinite || isNaN) {
      return this;
    }
    return (this * 1024).round() / 1024;
  }
}
