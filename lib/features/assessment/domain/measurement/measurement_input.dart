import 'length_unit.dart';

enum DecimalSeparator {
  point('.'),
  comma(',');

  const DecimalSeparator(this.character);
  final String character;

  DecimalSeparator get other => this == DecimalSeparator.point
      ? DecimalSeparator.comma
      : DecimalSeparator.point;
}

enum LengthParseError {
  empty,

  notANumber,

  negative,

  unexpectedSeparator,

  tooManyDigits,

  tooManyDecimals,
}

sealed class LengthParseResult {
  const LengthParseResult();
}

final class LengthParsed extends LengthParseResult {
  const LengthParsed(this.input);
  final MeasurementInput input;
}

final class LengthParseFailure extends LengthParseResult {
  const LengthParseFailure(this.error);
  final LengthParseError error;
}

final class MeasurementInput {
  const MeasurementInput._({
    required this.originalText,
    required this.unit,
    required this.decimalSeparator,
    required this.millimetres,
    required this.displayPrecision,
  });

  final String originalText;

  final LengthUnit unit;

  final DecimalSeparator decimalSeparator;

  final double millimetres;

  final int displayPrecision;

  Map<String, Object> toLocalJson() => {
    'originalText': originalText,
    'unit': unit.symbol,
    'decimalSeparator': decimalSeparator.name,
    'millimetres': millimetres,
    'displayPrecision': displayPrecision,
  };

  static MeasurementInput fromLocalJson(Map<String, Object?> json) {
    final Object? text = json['originalText'];
    final Object? unitSymbol = json['unit'];
    final Object? separatorName = json['decimalSeparator'];
    final Object? storedMm = json['millimetres'];
    if (text is! String ||
        unitSymbol is! String ||
        separatorName is! String ||
        storedMm is! num) {
      throw const FormatException('Malformed measurement input record.');
    }
    final LengthUnit? unit = LengthUnit.fromSymbol(unitSymbol);
    final DecimalSeparator? separator = DecimalSeparator.values
        .where((s) => s.name == separatorName)
        .firstOrNull;
    if (unit == null || separator == null) {
      throw const FormatException('Unknown unit or decimal separator.');
    }
    final LengthParseResult result = MeasurementParser(
      separator,
    ).parse(text, unit);
    if (result is! LengthParsed) {
      throw const FormatException('Stored original text no longer parses.');
    }
    if (result.input.millimetres != storedMm.toDouble()) {
      throw const FormatException(
        'Stored millimetres do not match original text.',
      );
    }
    return result.input;
  }

  @override
  bool operator ==(Object other) =>
      other is MeasurementInput &&
      other.originalText == originalText &&
      other.unit == unit &&
      other.decimalSeparator == decimalSeparator &&
      other.millimetres == millimetres &&
      other.displayPrecision == displayPrecision;

  @override
  int get hashCode => Object.hash(
    originalText,
    unit,
    decimalSeparator,
    millimetres,
    displayPrecision,
  );

  @override
  String toString() =>
      'MeasurementInput("$originalText" ${unit.symbol} = $millimetres mm)';
}

class MeasurementParser {
  const MeasurementParser(this.separator);

  final DecimalSeparator separator;

  static const int maxSignificantDigits = 9;

  static const int maxDecimalPlaces = 4;

  LengthParseResult parse(String text, LengthUnit unit) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const LengthParseFailure(LengthParseError.empty);
    }

    if (trimmed.contains(separator.other.character)) {
      return const LengthParseFailure(LengthParseError.unexpectedSeparator);
    }

    final String sep = RegExp.escape(separator.character);
    if (RegExp('^-[0-9$sep]').hasMatch(trimmed)) {
      return const LengthParseFailure(LengthParseError.negative);
    }

    final RegExpMatch? match = RegExp(
      '^([0-9]*)(?:$sep([0-9]+))?\$',
    ).firstMatch(trimmed);
    if (match == null) {
      return const LengthParseFailure(LengthParseError.notANumber);
    }
    final String intPart = match.group(1) ?? '';
    final String fracPart = match.group(2) ?? '';
    if (intPart.isEmpty && fracPart.isEmpty) {
      return const LengthParseFailure(LengthParseError.notANumber);
    }

    if (fracPart.length > maxDecimalPlaces) {
      return const LengthParseFailure(LengthParseError.tooManyDecimals);
    }
    final digits = '$intPart$fracPart';
    final String significant = digits.replaceFirst(RegExp('^0+'), '');
    if (significant.length > maxSignificantDigits) {
      return const LengthParseFailure(LengthParseError.tooManyDigits);
    }

    final int mantissa = significant.isEmpty ? 0 : int.parse(significant);
    final int scale = fracPart.length;
    var scaleFactor = 1;
    for (var i = 0; i < scale; i++) {
      scaleFactor *= 10;
    }

    final int numerator = mantissa * unit.mmNumerator;
    final int denominator = scaleFactor * unit.mmDenominator;
    final double millimetres = numerator / denominator;

    return LengthParsed(
      MeasurementInput._(
        originalText: text,
        unit: unit,
        decimalSeparator: separator,
        millimetres: millimetres,
        displayPrecision: scale,
      ),
    );
  }
}
