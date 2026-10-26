import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/provider_search.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';

void main() {
  const directory = OfficialReferralDirectory();
  final reviewed = DateTime(2026, 10, 26);

  test('all 50 states and DC have unique routing codes and official FIPS', () {
    const expected = {
      'AL': '01',
      'AK': '02',
      'AZ': '04',
      'AR': '05',
      'CA': '06',
      'CO': '08',
      'CT': '09',
      'DE': '10',
      'DC': '11',
      'FL': '12',
      'GA': '13',
      'HI': '15',
      'ID': '16',
      'IL': '17',
      'IN': '18',
      'IA': '19',
      'KS': '20',
      'KY': '21',
      'LA': '22',
      'ME': '23',
      'MD': '24',
      'MA': '25',
      'MI': '26',
      'MN': '27',
      'MS': '28',
      'MO': '29',
      'MT': '30',
      'NE': '31',
      'NV': '32',
      'NH': '33',
      'NJ': '34',
      'NM': '35',
      'NY': '36',
      'NC': '37',
      'ND': '38',
      'OH': '39',
      'OK': '40',
      'OR': '41',
      'PA': '42',
      'RI': '44',
      'SC': '45',
      'SD': '46',
      'TN': '47',
      'TX': '48',
      'UT': '49',
      'VT': '50',
      'VA': '51',
      'WA': '53',
      'WV': '54',
      'WI': '55',
      'WY': '56',
    };
    expect(usStates, hasLength(51));
    expect({for (final state in usStates) state.code: state.fips}, expected);
    expect(usStates.map((s) => s.fips).toSet(), hasLength(51));
    for (final state in usStates) {
      expect(state.name, isNotEmpty);
      expect(state.routingSupported, isTrue, reason: state.code);
      expect(referralState(state.code), same(state));
    }
    expect(referralState('ZZ'), isNull);
  });

  test('legacy locations preserve exact JSON and do not infer a state', () {
    const old = {'city': 'San Jose', 'county': 'Santa Clara', 'zip': '95112'};
    final restored = HelpLocation.fromJson(old);
    expect(restored.stateCode, isNull);
    expect(restored.countyFips, isNull);
    expect(restored.toJson(), old);
    expect(
      HelpLocation(city: 'Seattle', county: 'King', zip: '98101').stateCode,
      isNull,
    );
  });

  test(
    'confirmed geography round trips and rejects contradictory state FIPS',
    () {
      final location = HelpLocation(
        city: 'Roanoke',
        county: 'Roanoke city',
        zip: '24011',
        stateCode: 'VA',
        countyFips: '51770',
      );
      expect(
        HelpLocation.fromJson(location.toJson()).toJson(),
        location.toJson(),
      );
      expect(location.toJson()['stateCode'], 'VA');
      expect(location.toJson()['countyFips'], '51770');
      expect(
        () => HelpLocation(
          city: '',
          county: 'Roanoke',
          zip: null,
          stateCode: 'CA',
          countyFips: '51161',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'same county name in another state cannot match a reviewed provider',
    () {
      final seattle = directory.provider('rt-seattle-wa')!;
      expect(seattle.stateCodes, contains('WA'));
      expect(
        seattle.listsCounty('King', stateCode: 'TX', countyFips: '48269'),
        isFalse,
      );
      expect(
        searchLocalProviders(directory, stateCode: 'TX', county: 'King'),
        isEmpty,
      );
      expect(
        seattle.coverage(
          'King',
          reviewed,
          stateCode: 'TX',
          countyFips: '48269',
        ),
        ReferralCoverage.unknown,
      );
    },
  );

  test('Virginia county and independent city FIPS remain distinct', () {
    final provider = directory.provider('renovation-alliance-va')!;
    for (final (county, fips) in [
      ('Roanoke', '51161'),
      ('Roanoke city', '51770'),
      ('Salem city', '51775'),
      ('Craig', '51045'),
    ]) {
      expect(
        provider.listsCounty(county, stateCode: 'VA', countyFips: fips),
        isTrue,
        reason: '$county ($fips)',
      );
    }
    expect(
      provider.listsCounty('Roanoke', stateCode: 'VA', countyFips: '51760'),
      isFalse,
      reason: 'Richmond city is not Roanoke city or Roanoke County.',
    );
    expect(
      provider.listsCounty('Franklin', stateCode: 'PA', countyFips: '42055'),
      isFalse,
    );
  });

  test('partial areas and missing state cannot establish address coverage', () {
    final seattle = directory.provider('rt-seattle-wa')!;
    expect(
      seattle.coverage('King', reviewed, stateCode: 'WA', countyFips: '53033'),
      ReferralCoverage.unknown,
    );
    final original = directory.provider(
      'provider-rebuilding-together-silicon-valley',
    )!;
    expect(
      original.coverage('Santa Clara', reviewed),
      ReferralCoverage.unknown,
    );
    expect(
      original.coverage(
        'Santa Clara',
        reviewed,
        stateCode: 'CA',
        countyFips: '06085',
      ),
      ReferralCoverage.unknown,
      reason: 'County alone cannot satisfy a selected-city restriction.',
    );
  });

  test(
    'stale and closed records remain unknown rather than implying availability',
    () {
      final pilot = directory.provider('renovation-alliance-va')!;
      expect(
        pilot.coverage(
          'Craig',
          DateTime.parse(pilot.reviewAfter),
          stateCode: 'VA',
          countyFips: '51045',
        ),
        ReferralCoverage.unknown,
      );
      final closed = directory.provider('provider-habitat-sonoma-county')!;
      expect(closed.availability, ReferralAvailability.closed);
      expect(
        closed.coverage(
          'Sonoma',
          reviewed,
          stateCode: 'CA',
          countyFips: '06097',
        ),
        ReferralCoverage.unknown,
      );
    },
  );

  test(
    'reviewed pilot records have independent identity and bounded provenance',
    () {
      final pilots = [
        directory.provider('rt-seattle-wa')!,
        directory.provider('renovation-alliance-va')!,
        directory.provider('austin-habitat-tx')!,
      ];
      expect(pilots.expand((p) => p.stateCodes).toSet(), {'WA', 'VA', 'TX'});
      expect(pilots.map((p) => p.organizationId).toSet(), hasLength(3));
      for (final provider in pilots) {
        expect(provider.serviceAreas, isNotEmpty);
        expect(provider.sources, contains(provider.website));
        expect(provider.reviewedOn, '2026-10-26');
        expect(provider.reviewAfter, '2027-01-24');
        expect(provider.availability, ReferralAvailability.unknown);
        expect(provider.isLocator, isFalse);
        expect(provider.services, contains(ReferralService.accessibility));
      }
    },
  );

  test('national routes use exact official URLs without resident data', () {
    const destinations = {
      'referral-211-national': 'https://211.org/about-us/your-local-211',
      'referral-rebuilding-together-national':
          'https://rebuildingtogether.org/find-your-local-affiliate',
      'referral-eldercare-national': 'https://eldercare.acl.gov/home',
    };
    for (final entry in destinations.entries) {
      final provider = directory.provider(entry.key)!;
      expect(provider.isLocator, isTrue);
      final uri = referralDestination(provider);
      expect(uri.toString(), entry.value);
      expect(uri.hasQuery, isFalse);
      expect(uri.hasFragment, isFalse);
      expect(uri.userInfo, isEmpty);
    }
    for (final provider in directory.providers) {
      final uri = referralDestination(provider);
      expect(uri.scheme, 'https');
      expect(uri.hasQuery || uri.hasFragment, isFalse, reason: provider.id);
    }
  });

  test(
    'external routes reject URL-carried private data and embedded credentials',
    () {
      ReferralProvider destination(String url) => ReferralProvider(
        id: 'fictional-private-destination',
        name: 'Fictional provider',
        description: 'Fictional test only',
        website: url,
        sources: [url],
        reviewedOn: '2026-10-26',
        reviewAfter: '2027-01-24',
      );
      for (final url in [
        'https://example.org/?caseId=fictional-case',
        'https://example.org/#fictional-resident-notes',
        'https://fictional-token@example.org/',
        'http://example.org/',
      ]) {
        expect(
          () => referralDestination(destination(url)),
          throwsFormatException,
        );
      }
    },
  );
}
