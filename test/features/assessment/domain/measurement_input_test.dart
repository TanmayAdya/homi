import 'package:flutter_test/flutter_test.dart';

import 'package:safe_at_home/features/assessment/domain/measurement/length_unit.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/measurement_input.dart';

const _point = MeasurementParser(DecimalSeparator.point);
const _comma = MeasurementParser(DecimalSeparator.comma);

MeasurementInput _ok(LengthParseResult result) {
  expect(result, isA<LengthParsed>());
  return (result as LengthParsed).input;
}

LengthParseError _err(LengthParseResult result) {
  expect(result, isA<LengthParseFailure>());
  return (result as LengthParseFailure).error;
}

void main() {
  group('conversion', () {
    test('millimetres pass through', () {
      expect(_ok(_point.parse('800', LengthUnit.millimetre)).millimetres, 800);
    });

    test('centimetres multiply by 10', () {
      expect(_ok(_point.parse('80.5', LengthUnit.centimetre)).millimetres, 805);
    });

    test('inches multiply by 25.4 exactly', () {
      expect(_ok(_point.parse('31.5', LengthUnit.inch)).millimetres, 800.1);
      expect(_ok(_point.parse('2.54', LengthUnit.inch)).millimetres, 64.516);
      expect(_ok(_point.parse('1', LengthUnit.inch)).millimetres, 25.4);
    });

    test('small decimals do not accumulate floating point error', () {
      expect(_ok(_point.parse('0.1', LengthUnit.centimetre)).millimetres, 1.0);
      expect(_ok(_point.parse('0.3', LengthUnit.centimetre)).millimetres, 3.0);
    });

    test('leading separator is allowed', () {
      expect(_ok(_point.parse('.5', LengthUnit.inch)).millimetres, 12.7);
    });

    test('same text and unit always give the same value', () {
      final MeasurementInput a = _ok(_point.parse('33.07', LengthUnit.inch));
      final MeasurementInput b = _ok(_point.parse('33.07', LengthUnit.inch));
      expect(a.millimetres, b.millimetres);
      expect(a, b);
    });
  });

  group('original input is preserved', () {
    test('keeps exact typed text including whitespace', () {
      final MeasurementInput input = _ok(
        _point.parse(' 80.50 ', LengthUnit.centimetre),
      );
      expect(input.originalText, ' 80.50 ');
      expect(input.displayPrecision, 2);
      expect(input.millimetres, 805);
    });

    test('leading zeros parse but precision reflects typed decimals', () {
      final MeasurementInput input = _ok(
        _point.parse('0080', LengthUnit.millimetre),
      );
      expect(input.millimetres, 80);
      expect(input.displayPrecision, 0);
    });

    test('zero is a recorded value, not missing', () {
      final MeasurementInput input = _ok(
        _point.parse('0', LengthUnit.millimetre),
      );
      expect(input.millimetres, 0);
    });
  });

  group('decimal separators', () {
    test('comma locale accepts comma decimals', () {
      expect(_ok(_comma.parse('1,5', LengthUnit.centimetre)).millimetres, 15);
    });

    test('point locale rejects comma as ambiguous', () {
      expect(
        _err(_point.parse('1,5', LengthUnit.centimetre)),
        LengthParseError.unexpectedSeparator,
      );
      expect(
        _err(_point.parse('1,500', LengthUnit.millimetre)),
        LengthParseError.unexpectedSeparator,
      );
    });

    test('comma locale rejects point', () {
      expect(
        _err(_comma.parse('1.500', LengthUnit.millimetre)),
        LengthParseError.unexpectedSeparator,
      );
    });

    test('both separators are rejected', () {
      expect(
        _err(_point.parse('1,500.5', LengthUnit.millimetre)),
        LengthParseError.unexpectedSeparator,
      );
    });
  });

  group('invalid input', () {
    test('empty and whitespace are missing, never zero', () {
      expect(
        _err(_point.parse('', LengthUnit.millimetre)),
        LengthParseError.empty,
      );
      expect(
        _err(_point.parse('   ', LengthUnit.millimetre)),
        LengthParseError.empty,
      );
    });

    test('negative values', () {
      expect(
        _err(_point.parse('-3', LengthUnit.millimetre)),
        LengthParseError.negative,
      );
      expect(
        _err(_point.parse('-.5', LengthUnit.millimetre)),
        LengthParseError.negative,
      );
    });

    test('not a number', () {
      for (final text in [
        'abc',
        '5.',
        '.',
        '1.2.3',
        '+5',
        '1e3',
        '8 0',
        '-',
        '\u0668\u0660',
      ]) {
        expect(
          _err(_point.parse(text, LengthUnit.millimetre)),
          LengthParseError.notANumber,
          reason: 'input "$text"',
        );
      }
    });

    test('too many decimals', () {
      expect(
        _err(_point.parse('12.34567', LengthUnit.millimetre)),
        LengthParseError.tooManyDecimals,
      );
    });

    test('too many significant digits', () {
      expect(
        _err(_point.parse('1234567890', LengthUnit.millimetre)),
        LengthParseError.tooManyDigits,
      );
    });

    test('leading zeros do not count toward the digit limit', () {
      expect(
        _ok(_point.parse('000000000012', LengthUnit.millimetre)).millimetres,
        12,
      );
    });
  });

  group('local JSON', () {
    test('round trips', () {
      final MeasurementInput input = _ok(
        _comma.parse('33,07', LengthUnit.inch),
      );
      final MeasurementInput restored = MeasurementInput.fromLocalJson(
        input.toLocalJson(),
      );
      expect(restored, input);
    });

    test('rejects a tampered millimetre value', () {
      final json = Map<String, Object?>.of(
        _ok(_point.parse('80', LengthUnit.centimetre)).toLocalJson(),
      );
      json['millimetres'] = 801.0;
      expect(() => MeasurementInput.fromLocalJson(json), throwsFormatException);
    });

    test('rejects unknown units', () {
      final json = Map<String, Object?>.of(
        _ok(_point.parse('80', LengthUnit.centimetre)).toLocalJson(),
      );
      json['unit'] = 'ft';
      expect(() => MeasurementInput.fromLocalJson(json), throwsFormatException);
    });
  });
}
