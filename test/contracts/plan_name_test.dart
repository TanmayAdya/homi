import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/plan_name.dart';

void main() {
  test(
    'names trim, reset to null, and count Unicode scalars rather than UTF-16',
    () {
      expect(normalizePlanName(null), isNull);
      expect(normalizePlanName('   '), isNull);
      expect(normalizePlanName('  Grandma’s home 🏡  '), 'Grandma’s home 🏡');
      final eighty = List.filled(80, '🏡').join();
      expect(normalizePlanName(eighty), eighty);
      expect(() => normalizePlanName('$eighty🏡'), throwsFormatException);
    },
  );

  test(
    'multiline, control, bidi override and lone surrogate names are rejected',
    () {
      for (final name in [
        'Plan\n',
        '\tPlan',
        'Plan\rname',
        'Plan\u0000',
        'Plan\u007f',
        'Plan\u0085',
        'Plan\u2028',
        'Plan\u2029',
        'Plan\u202e',
        'Plan\u2067',
        String.fromCharCode(0xd800),
      ]) {
        expect(() => normalizePlanName(name), throwsFormatException);
      }
    },
  );

  test(
    'stored names require exact version, identity and normalized nonempty text',
    () {
      final record = PlanName(caseId: 'a.b', name: '  Upstairs  ').toJson();
      expect(PlanName.fromJson(record).name, 'Upstairs');
      expect(PlanName.storageKey('a.b'), 'plan-name.a.b');
      for (final malformed in [
        {...record, 'schemaVersion': '2'},
        {...record, 'name': null},
        {...record, 'name': ''},
        {...record, 'name': ' Upstairs '},
        {...record, 'extra': true},
        {...record, 'caseId': 'invalid/key'},
      ]) {
        expect(() => PlanName.fromJson(malformed), throwsFormatException);
      }
    },
  );
}
