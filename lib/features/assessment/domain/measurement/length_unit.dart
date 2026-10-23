enum LengthUnit {
  millimetre('mm', 1, 1),
  centimetre('cm', 10, 1),
  inch('in', 254, 10);

  const LengthUnit(this.symbol, this.mmNumerator, this.mmDenominator);

  final String symbol;

  final int mmNumerator;
  final int mmDenominator;

  static LengthUnit? fromSymbol(String symbol) {
    for (final LengthUnit unit in LengthUnit.values) {
      if (unit.symbol == symbol) return unit;
    }
    return null;
  }
}
