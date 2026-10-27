import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/provider_search.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';

void main() {
  const directory = OfficialReferralDirectory();
  const silicon = 'provider-rebuilding-together-silicon-valley';
  test(
    'all nine counties have reviewed records without inventing city-wide funding',
    () {
      expect(
        localProviderCatalog
            .where((p) => p.stateCodes.contains('CA'))
            .expand((p) => p.counties)
            .toSet(),
        {
          'Alameda',
          'Contra Costa',
          'Marin',
          'Napa',
          'San Francisco',
          'San Mateo',
          'Santa Clara',
          'Solano',
          'Sonoma',
        },
      );
      for (final county
          in localProviderCatalog
              .where((p) => p.stateCodes.contains('CA'))
              .expand((p) => p.counties)
              .toSet()) {
        expect(
          searchLocalProviders(
            directory,
            stateCode: 'CA',
            county: '$county County',
          ),
          isNotEmpty,
        );
      }
      expect(
        searchLocalProviders(directory, query: 'Petaluma').single.id,
        'provider-rebuilding-together-petaluma',
      );
      expect(
        searchLocalProviders(directory, query: 'Yountville').single.id,
        'provider-napa-housing-rehabilitation',
      );
      expect(
        searchLocalProviders(directory, query: 'Berkeley').single.id,
        'provider-cil-residential-access',
      );
      expect(
        directory.provider('provider-cil-residential-access')!.areaNote,
        contains('limited to Berkeley'),
      );
      expect(
        directory
            .provider('provider-habitat-east-bay-silicon-valley')!
            .areaNote,
        contains('selected cities'),
      );
      expect(
        directory
            .provider('provider-rebuilding-together-solano-county')!
            .areaNote,
        contains('April 30, 2026'),
      );
      expect(
        directory.provider('provider-alameda-county-healthy-homes')!.areaNote,
        contains('awaiting funding'),
      );
      expect(
        directory.provider('provider-rebuilding-together-petaluma')!.cities,
        isNot(contains('Calistoga')),
      );
    },
  );

  test(
    'original four identities and contact destinations remain unchanged',
    () {
      const original = {
        'provider-rebuilding-together-silicon-valley': (
          'https://rebuildingtogethersv.org/apply/',
          '4085789519',
        ),
        'provider-rebuilding-together-san-francisco': (
          'https://rebuildingtogethersf.org/apply/',
          '4159051611',
        ),
        'provider-habitat-greater-san-francisco': (
          'https://habitatgsf.org/home-repair-work/',
          '4156251000',
        ),
        'provider-cid-san-mateo': (
          'https://www.cidsanmateo.org/services/assistive-technology.php',
          '6506451780',
        ),
      };
      for (final entry in original.entries) {
        final p = directory.provider(entry.key)!;
        expect((p.website, p.phone), entry.value);
        expect(p.reviewedOn, '2026-10-24');
      }
    },
  );

  test(
    'closed intake remains discoverable with its closure and alternatives intact',
    () {
      final p = searchLocalProviders(
        directory,
        stateCode: 'CA',
        county: 'Sonoma',
        query: 'Habitat',
      ).single;
      expect(p.availability, ReferralAvailability.closed);
      expect(p.areaNote, contains('intake is closed at review'));
      expect(p.needsReview(DateTime.parse(p.reviewAfter)), isTrue);
      expect(
        p.coverage('Sonoma', DateTime(2026, 11, 24)),
        ReferralCoverage.unknown,
      );
      expect(
        searchLocalProviders(
          directory,
          stateCode: 'CA',
          county: 'Sonoma',
          query: 'Rebuilding',
        ).single.availability,
        ReferralAvailability.unknown,
      );
    },
  );
  test(
    'catalog has stable unique identities, sources and bounded review dates',
    () {
      expect(
        directory.providers.map((p) => p.id).toSet().length,
        directory.providers.length,
      );
      expect(localProviderCatalogVersion, 'us-pilot-2026-10-26-v2');
      for (final p in localProviderCatalog.where(
        (p) => p.stateCodes.contains('CA'),
      )) {
        expect(directory.provider(p.id), same(p));
        expect(p.isLocalProvider, isTrue);
        expect(p.counties, isNotEmpty);
        expect(p.sources, contains(p.website));
        for (final copy in [p.description, ?p.areaNote]) {
          for (final locale in ['es', 'zh-Hans', 'zh-Hant', 'vi', 'fil']) {
            expect(
              AppLocalizations.translations[copy]?[locale],
              isNotEmpty,
              reason: '${p.id}: missing $locale content',
            );
          }
        }
        for (final source in p.sources) {
          expect(Uri.parse(source).scheme, 'https');
        }
        expect(referralDestination(p).hasQuery, isFalse);
        expect(referralDestination(p, phone: true).scheme, 'tel');
        expect(
          DateTime.parse(
            p.reviewAfter,
          ).difference(DateTime.parse(p.reviewedOn)).inDays,
          30,
        );
        expect(
          p.availability,
          p.id == 'provider-habitat-sonoma-county'
              ? ReferralAvailability.closed
              : ReferralAvailability.unknown,
        );
        expect(p.needsReview(DateTime.parse(p.reviewAfter)), isTrue);
        expect(
          p.coverage(p.counties.first, DateTime.parse(p.reviewAfter)),
          ReferralCoverage.unknown,
        );
      }
    },
  );

  test(
    'search finds individual organizations rather than national locators',
    () {
      final all = searchLocalProviders(directory);
      expect(all, hasLength(17));
      expect(
        all.any((p) => p.isLocator || officialReferrals.contains(p)),
        isFalse,
      );
      expect(
        searchLocalProviders(directory, query: '  SAN JOSÉ!  ').single.id,
        silicon,
      );
      expect(
        searchLocalProviders(directory, query: 'rebuilding silicon').single.id,
        silicon,
      );
      expect(
        searchLocalProviders(
          directory,
          query: 'Cupertino',
          stateCode: 'CA',
          county: 'Santa Clara County',
        ).single.id,
        silicon,
      );
      expect(
        searchLocalProviders(
          directory,
          query: 'Cupertino',
          stateCode: 'CA',
          county: 'San Mateo',
        ),
        isEmpty,
      );
      expect(searchLocalProviders(directory, query: '94105'), isEmpty);
      expect(
        searchLocalProviders(directory, query: 'Fictional unavailable repair'),
        isEmpty,
      );
      expect(
        searchLocalProviders(directory, stateCode: 'CA', county: 'not listed'),
        isEmpty,
      );
      expect(searchLocalProviders(directory, query: '   '), all);
      expect(() => all.clear(), throwsUnsupportedError);
    },
  );

  test(
    'service filters distinguish coordination and direct repair discovery',
    () {
      expect(
        searchLocalProviders(directory, service: ReferralService.homeRepair),
        hasLength(13),
      );
      expect(
        searchLocalProviders(
          directory,
          stateCode: 'CA',
          county: 'SAN MATEO county',
          service: ReferralService.coordination,
        ).single.id,
        'provider-cid-san-mateo',
      );
      expect(
        searchLocalProviders(
          directory,
          stateCode: 'CA',
          county: 'San Mateo',
          service: ReferralService.accessibility,
        ).single.id,
        'provider-habitat-greater-san-francisco',
      );
      expect(
        searchLocalProviders(
          directory,
          stateCode: 'CA',
          county: 'Santa Clara',
          service: ReferralService.coordination,
        ),
        isEmpty,
      );
    },
  );

  test(
    'translated service and description text is searchable without renaming organizations',
    () {
      for (final locale in AppLocalizations.supportedLocales) {
        final tr = AppLocalizations(locale);
        final results = searchLocalProviders(
          directory,
          stateCode: 'CA',
          query: tr.text('Service coordination'),
          translate: tr.text,
        );
        expect(results.map((p) => p.id), contains('provider-cid-san-mateo'));
        expect(results, hasLength(4));
      }
      final tr = AppLocalizations(const Locale('es'));
      expect(
        searchLocalProviders(
          directory,
          stateCode: 'CA',
          query: 'tecnologia',
          translate: tr.text,
        ).map((p) => p.id),
        containsAll([
          'provider-cid-san-mateo',
          'provider-marin-center-independent-living',
        ]),
      );
    },
  );
}
