import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/local_help_screen.dart';
import 'package:safe_at_home/features/local_help/nationwide_help_browser.dart';
import 'package:safe_at_home/features/local_help/provider_search.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/nationwide_help.dart';
import 'package:safe_at_home/l10n/catalogs/redesign_help.dart';

import '../../app/app_design_test.dart' show narrowLargeText;
import '../../app/core_localization_test.dart' show localized;
import 'local_help_screen_test.dart' show make, reveal, tap;

class _Directory implements ReferralDirectory {
  const _Directory(this.providers);
  @override
  final List<ReferralProvider> providers;
  @override
  ReferralProvider? provider(String id) =>
      providers.where((p) => p.id == id).firstOrNull;
}

Future<void> selectState(WidgetTester tester, String state) async {
  final field = find.byKey(const ValueKey('help-location-state'));
  await reveal(tester, field);
  tester.state<FormFieldState<String>>(field).didChange(state);
  tester.widget<DropdownButtonFormField<String>>(field).onChanged!(state);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'location editor confirms all 50 states and DC without GPS or county guessing',
    (tester) async {
      final confirmed = <HelpLocation>[];
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          Scaffold(
            body: SingleChildScrollView(
              child: ReferralLocationEditor(onConfirm: confirmed.add),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.text('Confirm location'));
      expect(confirmed, isEmpty);
      expect(
        find.text('Choose your state or DC. No GPS is needed.'),
        findsOneWidget,
      );
      final place = find.widgetWithText(
        TextFormField,
        'ZIP code or city (optional)',
      );
      await selectState(tester, 'OR');
      await tester.enterText(place, '1234');
      await tap(tester, find.text('Confirm location'));
      expect(confirmed, isEmpty);
      expect(find.text('Enter a 5-digit ZIP or ZIP+4.'), findsOneWidget);
      await tester.enterText(place, 'Fictional city');
      await tap(tester, find.text('Confirm location'));
      expect(confirmed.single.city, 'Fictional city');
      expect(confirmed.single.zip, isNull);
      confirmed.clear();
      expect(
        find.widgetWithText(TextFormField, 'County (optional)'),
        findsNothing,
      );
      await tap(tester, find.text('Add county (optional)'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'County (optional)'),
        'Washington',
      );
      await tester.enterText(place, '12345-6789');
      for (final state in usStates) {
        await selectState(tester, state.code);
        await tap(tester, find.text('Confirm location'));
        expect(confirmed.last.stateCode, state.code);
        expect(confirmed.last.county, 'Washington');
        expect(confirmed.last.countyFips, isNull);
        expect(confirmed.last.zip, '12345-6789');
        expect(confirmed.last.city, isEmpty);
      }
      expect(confirmed, hasLength(51));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read-only browser opens exact official locators and never sends browsing inputs',
    (tester) async {
      final opened = <Uri>[];
      var choosePlan = 0;
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          NationwideHelpBrowser(
            now: () => DateTime(2026, 10, 26),
            onChoosePlan: () => choosePlan++,
            openExternal: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'ZIP code or city (optional)'),
        '82001',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Filled from ZIP code 82001. You can change it.'),
        findsOneWidget,
      );
      await tap(tester, find.text('Confirm location'));
      await reveal(tester, find.text('Searching near · Wyoming, 82001'));
      expect(find.text('Providers found: 0'), findsOneWidget);
      final empty = find.byKey(const ValueKey('help-empty-results'));
      await reveal(tester, empty);
      expect(
        find.descendant(
          of: empty,
          matching: find.text('No listed organizations near Wyoming yet'),
        ),
        findsOneWidget,
      );
      await tap(
        tester,
        find.descendant(of: empty, matching: find.text('Eldercare Locator')),
      );
      expect(opened.single.toString(), 'https://eldercare.acl.gov/home');
      for (final entry in const {
        'Find my local 211': 'https://211.org/about-us/your-local-211',
        'Find a Rebuilding Together affiliate':
            'https://rebuildingtogether.org/find-your-local-affiliate',
        'Open Eldercare Locator': 'https://eldercare.acl.gov/home',
      }.entries) {
        await tap(
          tester,
          find.ancestor(
            of: find.text(entry.key),
            matching: find.bySubtype<ButtonStyleButton>(),
          ),
        );
        expect(opened.last.toString(), entry.value);
        expect(opened.last.hasQuery, isFalse);
        expect(opened.last.hasFragment, isFalse);
      }
      for (final uri in opened) {
        expect(uri.toString(), isNot(contains('82001')));
        expect(uri.toString(), isNot(contains('Wyoming')));
      }
      final save = find.descendant(
        of: find.byKey(const ValueKey('referral-211-national')),
        matching: find.text('Save · on this phone'),
      );
      await tap(tester, save);
      expect(
        find.text('Create or open a plan to save contacts and add follow-ups.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Saved contacts stay on this phone and are removed when you sign out.',
        ),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const ValueKey('help-choose-plan')));
      await tester.pumpAndSettle();
      expect(choosePlan, 1);
      expect(find.text('Save to a plan'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'browser works without a selected plan and link failure keeps official destinations',
    (tester) async {
      final app = await make();
      await app.coordinator.clearSelected();
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          Scaffold(body: LocalHelpButton(services: app)),
        ),
      );
      await tester.tap(find.byTooltip('Find local help'));
      await tester.pumpAndSettle();
      expect(find.byType(NationwideHelpBrowser), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          NationwideHelpBrowser(openExternal: (_) async => false),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.text('Find my local 211'));
      await reveal(
        tester,
        find.textContaining('Could not open this link or dialer.'),
      );
      await tap(
        tester,
        find.byKey(const ValueKey('help-details-referral-211-national')),
      );
      expect(find.text('Where they work'), findsOneWidget);
      expect(
        find.text('https://211.org/about-us/your-local-211'),
        findsNothing,
      );
      final source = find.byKey(
        const ValueKey(
          'referral-source-referral-211-national-https://211.org/about-us/your-local-211',
        ),
      );
      await reveal(tester, source);
      expect(
        find.descendant(of: source, matching: find.text('211.org')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: source, matching: find.textContaining('Checked ')),
        findsOneWidget,
      );
      await tap(tester, source);
      await reveal(
        tester,
        find.textContaining('Could not open this link or dialer.'),
      );
      await reveal(
        tester,
        find.text(
          'Saved contacts stay on this phone and are removed when you sign out.',
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old saved county stays state-unknown until the resident confirms a state',
    (tester) async {
      final app = await make();
      final repo = LocalHelpRepository(app.coordinator);
      await repo.confirmLocation(
        HelpLocation(
          city: 'Fictional city',
          county: 'Santa Clara',
          zip: '95050',
        ),
      );
      await tester.pumpWidget(
        localized(const Locale('en'), LocalHelpScreen(services: app)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('help-location-state')),
            )
            .initialValue,
        isNull,
      );
      expect(
        find.widgetWithText(TextFormField, 'County (optional)'),
        findsOneWidget,
      );
      await tap(tester, find.text('Confirm location'));
      expect(
        find.text('Choose your state or DC. No GPS is needed.'),
        findsOneWidget,
      );
      expect((await repo.load()).location!.stateCode, isNull);
      await selectState(tester, 'TX');
      await tap(tester, find.text('Confirm location'));
      expect((await repo.load()).location!.stateCode, 'TX');
      expect((await repo.load()).location!.county, 'Santa Clara');
      expect((await repo.load()).location!.zip, '95050');
      await reveal(tester, find.text('Providers found: 0'));
      await reveal(tester, find.text('Find my local 211'));
      expect(tester.takeException(), isNull);
    },
  );

  test('same named counties do not leak records across state filters', () {
    const ca = ReferralProvider(
      id: 'fictional-ca',
      name: 'Fictional CA organization',
      description: 'Fictional service',
      website: 'https://example.org/ca',
      sources: ['https://example.org/ca'],
      reviewedOn: '2026-10-26',
      reviewAfter: '2027-01-24',
      stateCodes: ['CA'],
      counties: ['Washington'],
      services: [ReferralService.homeRepair],
    );
    const or = ReferralProvider(
      id: 'fictional-or',
      name: 'Fictional OR organization',
      description: 'Fictional service',
      website: 'https://example.org/or',
      sources: ['https://example.org/or'],
      reviewedOn: '2026-10-26',
      reviewAfter: '2027-01-24',
      stateCodes: ['OR'],
      counties: ['Washington'],
      services: [ReferralService.homeRepair],
    );
    const directory = _Directory([ca, or]);
    expect(
      searchLocalProviders(
        directory,
        stateCode: 'OR',
        county: 'Washington',
      ).map((p) => p.id),
      ['fictional-or'],
    );
    expect(
      searchLocalProviders(
        directory,
        stateCode: 'CA',
        county: 'Washington',
      ).map((p) => p.id),
      ['fictional-ca'],
    );
    expect(
      searchLocalProviders(directory, stateCode: 'NY', county: 'Washington'),
      isEmpty,
    );
    expect(searchLocalProviders(directory, county: 'Washington'), isEmpty);
  });

  test(
    'county FIPS filters apply without a county name and roles do not imply repair crews',
    () {
      const directory = OfficialReferralDirectory();
      expect(
        searchLocalProviders(
          directory,
          stateCode: 'CA',
          countyFips: '06085',
        ).map((p) => p.id),
        contains('provider-rebuilding-together-silicon-valley'),
      );
      expect(
        searchLocalProviders(directory, stateCode: 'TX', countyFips: '06085'),
        isEmpty,
      );
      expect(searchLocalProviders(directory, countyFips: '06085'), isEmpty);
      expect(
        searchLocalProviders(directory, stateCode: 'CA', countyFips: '99999'),
        isEmpty,
      );
      final coordination = searchLocalProviders(
        directory,
        role: ReferralRole.coordinator,
      );
      expect(coordination.map((p) => p.id), contains('provider-cid-san-mateo'));
      expect(
        searchLocalProviders(
          directory,
          role: ReferralRole.repairProvider,
        ).map((p) => p.id),
        isNot(contains('provider-cid-san-mateo')),
      );
      for (final result in coordination) {
        expect(result.roles, contains(ReferralRole.coordinator));
      }
    },
  );

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'national routes and location controls remain usable at 320px and 3.2x in $locale',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final tr = AppLocalizations(locale);
        await tester.pumpWidget(
          localized(
            locale,
            NationwideHelpBrowser(now: () => DateTime(2026, 10, 26)),
          ),
        );
        await tester.pumpAndSettle();
        await selectState(tester, 'DC');
        await tap(tester, find.text(tr.text('Confirm location')));
        await reveal(tester, find.text(tr.text('Ask who serves this address')));
        await reveal(tester, find.text(tr.text('Open Eldercare Locator')));
        await reveal(
          tester,
          find.text(tr.text('Program research and preparation')),
        );
        await reveal(tester, find.text(tr.text('About this list')));
        await reveal(
          tester,
          find.byKey(const ValueKey('provider-search-query')),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('nationwide copy has five translations with preserved placeholders', () {
    for (final entry in {
      ...nationwideHelpTranslations,
      ...redesignHelpTranslations,
    }.entries) {
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      });
      final placeholders = RegExp(
        r'\{[^}]+\}',
      ).allMatches(entry.key).map((m) => m[0]).toSet();
      for (final text in entry.value.values) {
        expect(text.trim(), isNotEmpty);
        expect(
          RegExp(r'\{[^}]+\}').allMatches(text).map((m) => m[0]).toSet(),
          placeholders,
        );
      }
    }
  });
}
