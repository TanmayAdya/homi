import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/referral_geography.dart';
import 'package:safe_at_home/features/local_help/zip_states.dart';

void main() {
  test('edge prefixes resolve to the allocated state or territory', () {
    const cases = {
      '00501': 'NY',
      '00601': 'PR',
      '00801': 'VI',
      '00901': 'PR',
      '01001': 'MA',
      '05501': 'MA',
      '05601': 'VT',
      '20001': 'DC',
      '20101': 'VA',
      '20201': 'DC',
      '20601': 'MD',
      '56901': 'DC',
      '39901': 'GA',
      '73301': 'TX',
      '73401': 'OK',
      '88501': 'TX',
      '96701': 'HI',
      '96799': 'AS',
      '99950': 'AK',
      '94103-1234': 'CA',
    };
    for (final entry in cases.entries) {
      expect(stateForZip(entry.key), entry.value, reason: entry.key);
    }
  });

  test('unknown, shared, military and malformed ZIPs ask for the state', () {
    for (final zip in [
      '00000',
      '00401',
      '09001',
      '34001',
      '96201',
      '96910',
      '21301',
      '26901',
      '1234',
      '123456',
      'abcde',
      '12345-12',
      '',
    ]) {
      expect(stateForZip(zip), isNull, reason: zip);
    }
  });

  test('every state and DC is reachable from some prefix', () {
    final reachable = {
      for (var p = 0; p < 1000; p++) stateForZip('${'$p'.padLeft(3, '0')}01'),
    };
    for (final state in usStates) {
      expect(reachable, contains(state.code), reason: state.code);
    }
  });
}
