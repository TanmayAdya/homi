import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/cases/profile_suggestions.dart';

void main() {
  test('city lookup folds case, accents, combining accents, and spaces', () {
    for (final query in [
      'San Jose',
      'SAN JOSÉ',
      'San Jose\u0301',
      '  san   jose  ',
    ]) {
      expect(profileSuggestions('city', query).single.value, 'San José');
    }
  });

  test(
    'prefixes rank before contained names and exact names before prefixes',
    () {
      expect(
        profileSuggestions('city', 'Palo Alto').map((item) => item.value),
        ['Palo Alto', 'East Palo Alto'],
      );
      expect(
        profileSuggestions('city', 'Los Altos').map((item) => item.value),
        ['Los Altos', 'Los Altos Hills'],
      );
    },
  );

  test('city details and typed counties distinguish neighboring cities', () {
    final east = profileSuggestions('city', 'East Palo Alto').single;
    final palo = profileSuggestions('city', 'Palo Alto').first;
    expect(east.detail, 'San Mateo County');
    expect(east.county, 'San Mateo');
    expect(palo.detail, 'Santa Clara County');
    expect(palo.county, 'Santa Clara');
    expect(profileSuggestions('city', 'San Mateo County'), isEmpty);
  });

  test(
    'county aliases save the existing county spelling without its suffix',
    () {
      final county = profileSuggestions(
        'county',
        'County of Santa Clara',
      ).single;
      expect(county.value, 'Santa Clara');
      expect(county.label, 'Santa Clara County');
      expect(
        profileSuggestions('county', 'san mateo county').single.value,
        'San Mateo',
      );
    },
  );

  test('health plans accept abbreviations and never imply enrollment', () {
    final scfhp = profileSuggestions('healthPlan', 'scfhp').single;
    final hpsm = profileSuggestions('healthPlan', 'HPSM').single;
    expect(scfhp.value, 'Santa Clara Family Health Plan');
    expect(hpsm.value, 'Health Plan of San Mateo');
    expect(profileSuggestions('healthPlan', 'Medi-Cal'), isEmpty);
    expect(profileSuggestions('healthPlan', 'uninsured'), isEmpty);
  });

  test('other verified plan names stay distinct from SCFHP and HPSM', () {
    for (final name in [
      'Alameda Alliance for Health',
      'Anthem Blue Cross',
      'Contra Costa Health Plan',
      'Kaiser Permanente',
      'Partnership Health Plan of California',
      'San Francisco Health Plan',
    ]) {
      final selected = profileSuggestions('healthPlan', name).single;
      expect(selected.value, name);
      expect(selected.county, isNull);
      expect(selected.aliases, isEmpty);
      expect(selected.value, isNot('Santa Clara Family Health Plan'));
      expect(selected.value, isNot('Health Plan of San Mateo'));
    }
    expect(
      profileSuggestions('healthPlan', 'Kaiser').single.value,
      'Kaiser Permanente',
    );
    expect(
      profileSuggestions('healthPlan', 'San Francisco').single.value,
      'San Francisco Health Plan',
    );
  });

  test('only city suggestions carry a county mapping', () {
    for (final field in ['county', 'healthPlan']) {
      final suggestions = profileSuggestions(field, '');
      expect(suggestions, isNotEmpty);
      expect(
        suggestions.every((suggestion) => suggestion.county == null),
        isTrue,
      );
    }
    const custom = ProfileSuggestion(value: 'Custom', label: 'Custom');
    expect(custom.county, isNull);
  });

  test('county canonicalization matches complete names and aliases only', () {
    for (final input in [
      'Santa Clara',
      'SANTA CLARA COUNTY',
      '  County   of Santa Clara  ',
    ]) {
      expect(canonicalProfileCounty(input), 'Santa Clara');
    }
    for (final input in [
      'San Mateo',
      ' san mateo county ',
      'County of San Mateo',
    ]) {
      expect(canonicalProfileCounty(input), 'San Mateo');
    }
    for (final input in [
      '',
      'San',
      'Clara',
      'Santa Clara County extra',
      'Alameda',
      'San José',
      'a' * 257,
    ]) {
      expect(canonicalProfileCounty(input), isNull, reason: input);
    }
  });

  test('unknown fields and custom text do not get unrelated suggestions', () {
    expect(profileSuggestions('country', 'San'), isEmpty);
    expect(profileSuggestions('city', 'Oakland'), isEmpty);
    expect(profileSuggestions('county', 'Alameda'), isEmpty);
    expect(profileSuggestions('healthPlan', 'My employer plan'), isEmpty);
    expect(profileSuggestions('city', '東京'), isEmpty);
    expect(profileSuggestions('city', '???'), isEmpty);
  });

  test('results and work are bounded and result lists cannot be mutated', () {
    expect(profileSuggestions('city', ''), hasLength(6));
    expect(profileSuggestions('city', 'a'), hasLength(6));
    expect(profileSuggestions('city', 'a' * 257), isEmpty);
    expect(
      () => profileSuggestions('city', '').clear(),
      throwsUnsupportedError,
    );
  });

  test('all incorporated cities in the two reviewed lists are reachable', () {
    const santaClara = [
      'Campbell',
      'Cupertino',
      'Gilroy',
      'Los Altos',
      'Los Altos Hills',
      'Los Gatos',
      'Milpitas',
      'Monte Sereno',
      'Morgan Hill',
      'Mountain View',
      'Palo Alto',
      'San José',
      'Santa Clara',
      'Saratoga',
      'Sunnyvale',
    ];
    const sanMateo = [
      'Atherton',
      'Belmont',
      'Brisbane',
      'Burlingame',
      'Colma',
      'Daly City',
      'East Palo Alto',
      'Foster City',
      'Half Moon Bay',
      'Hillsborough',
      'Menlo Park',
      'Millbrae',
      'Pacifica',
      'Portola Valley',
      'Redwood City',
      'San Bruno',
      'San Carlos',
      'San Mateo',
      'South San Francisco',
      'Woodside',
    ];
    for (final city in santaClara) {
      final suggestion = profileSuggestions('city', city).first;
      expect(suggestion.value, city);
      expect(suggestion.detail, 'Santa Clara County');
      expect(suggestion.county, 'Santa Clara', reason: city);
    }
    for (final city in sanMateo) {
      final suggestion = profileSuggestions('city', city).first;
      expect(suggestion.value, city);
      expect(suggestion.detail, 'San Mateo County');
      expect(suggestion.county, 'San Mateo', reason: city);
    }
  });
}
