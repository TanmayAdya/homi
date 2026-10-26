import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/local_help_screen.dart';
import 'package:safe_at_home/features/local_help/nationwide_help_browser.dart';
import 'package:safe_at_home/features/local_help/provider_search.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../app/app_design_test.dart' show narrowLargeText;
import '../../app/core_localization_test.dart' show localized;
import 'local_help_screen_test.dart' show make, tap, reveal;
import 'referral_test_support.dart';

const providerId = 'provider-cid-san-mateo';
Finder providerAction(String label, {String id = providerId}) =>
    find.descendant(of: find.byKey(ValueKey(id)), matching: find.text(label));

Future<void> search(WidgetTester tester, String text) async {
  final query = find.byKey(const ValueKey('provider-search-query'));
  await reveal(tester, query);
  await tester.enterText(query, text);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('new county listings show results before referral routes', (
    tester,
  ) async {
    final app = await make();
    await LocalHelpRepository(app.coordinator).confirmLocation(
      HelpLocation(stateCode: 'CA', city: '', county: 'Alameda', zip: null),
    );
    await tester.pumpWidget(
      localized(const Locale('en'), LocalHelpScreen(services: app)),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Providers found: 3'));
    await reveal(tester, find.text('Listed organizations near Alameda, CA'));
    expect(find.byKey(const ValueKey('help-empty-results')), findsNothing);
    await reveal(tester, find.text('Ask who serves this address'));
    await reveal(tester, find.byKey(const ValueKey('referral-211-national')));
    await reveal(tester, find.byKey(const ValueKey('referral-211-bay-area')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'closed Sonoma intake is visible on its single card and keeps contact actions',
    (tester) async {
      final app = await make();
      await LocalHelpRepository(app.coordinator).confirmLocation(
        HelpLocation(stateCode: 'CA', city: '', county: 'Sonoma', zip: null),
      );
      final opened = <Uri>[];
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          LocalHelpScreen(
            services: app,
            openExternal: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      const closedId = 'provider-habitat-sonoma-county';
      final card = find.byKey(const ValueKey(closedId));
      await reveal(tester, card);
      expect(
        find.descendant(
          of: card,
          matching: find.text('Intake closed: ask about alternatives.'),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.text('Intake closed: ask about alternatives.'),
          matching: find.byType(Card),
        ),
        findsOneWidget,
        reason: 'A result is one card, never a card inside a card.',
      );
      expect(opened, isEmpty);
      await tap(tester, providerAction('Call organization', id: closedId));
      expect(opened.single.toString(), 'tel:7075787707');
      await tap(tester, providerAction('Save · on this phone', id: closedId));
      await tester.tap(find.text('Save on this device'));
      await tester.pumpAndSettle();
      expect(
        (await LocalHelpRepository(
          app.coordinator,
        ).load()).contacts.single.providerId,
        closedId,
      );
      await reveal(
        tester,
        providerAction('Saved · on this phone', id: closedId),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only confirmed county changes the filter; stale coverage stays unknown',
    (tester) async {
      final app = await make();
      final repo = LocalHelpRepository(app.coordinator);
      await repo.confirmLocation(
        HelpLocation(stateCode: 'CA', city: '', county: 'San Mateo', zip: null),
      );
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          LocalHelpScreen(services: app, now: () => DateTime(2027)),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Providers found: 2'));
      await tap(tester, find.byKey(const ValueKey('help-location-change')));
      final county = find.widgetWithText(TextFormField, 'County (optional)');
      await reveal(tester, county);
      await tester.enterText(county, 'Santa Clara County');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Providers found: 2'));
      expect((await repo.load()).location!.county, 'San Mateo');
      await tap(tester, find.text('Confirm location'));
      await reveal(tester, find.text('Providers found: 2'));
      final card = find.byKey(
        const ValueKey('provider-rebuilding-together-silicon-valley'),
      );
      await reveal(
        tester,
        find.descendant(
          of: card,
          matching: find.text('Coverage unknown: contact to confirm.'),
        ),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Listing needs review. Contact to confirm.'),
        ),
        findsOneWidget,
      );
      await tap(tester, find.byKey(const ValueKey('help-type-coordination')));
      final wholeState = searchLocalProviders(
        const OfficialReferralDirectory(),
        stateCode: 'CA',
        service: ReferralService.coordination,
      );
      expect(wholeState, isNotEmpty);
      if (find.text('Providers found: 0').evaluate().isNotEmpty) {
        await tap(tester, find.text('Search the whole state'));
        await reveal(
          tester,
          find.text('Providers found: ${wholeState.length}'),
        );
        await reveal(tester, find.text('Listed organizations near California'));
      }
      await tap(tester, find.text('Clear search and filters'));
      await reveal(tester, find.text('Providers found: 2'));
      expect((await repo.load()).location!.county, 'Santa Clara County');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty results explain why, list every-address referrals and widen the area',
    (tester) async {
      final app = await make();
      await LocalHelpRepository(app.coordinator).confirmLocation(
        HelpLocation(
          stateCode: 'CA',
          city: '',
          county: 'Unlisted county',
          zip: null,
        ),
      );
      await tester.pumpWidget(
        localized(const Locale('en'), LocalHelpScreen(services: app)),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Providers found: 0'));
      final empty = find.byKey(const ValueKey('help-empty-results'));
      await reveal(tester, empty);
      expect(
        find.descendant(
          of: empty,
          matching: find.text(
            'No listed organizations near Unlisted county, CA yet',
          ),
        ),
        findsOneWidget,
      );
      for (final name in ['211', 'Eldercare Locator', 'Rebuilding Together']) {
        expect(
          find.descendant(of: empty, matching: find.text(name)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: empty,
          matching: find.text('Show all kinds of help'),
        ),
        findsNothing,
      );
      await tap(
        tester,
        find.descendant(
          of: empty,
          matching: find.text('Search the whole state'),
        ),
      );
      final california = searchLocalProviders(
        const OfficialReferralDirectory(),
        stateCode: 'CA',
      ).length;
      await reveal(tester, find.text('Providers found: $california'));
      await search(tester, 'San José');
      await reveal(tester, find.text('Providers found: 1'));
      await reveal(
        tester,
        find.byKey(
          const ValueKey('provider-rebuilding-together-silicon-valley'),
        ),
      );
      await search(tester, 'fictional no result');
      await reveal(
        tester,
        find.text(
          'No listed organizations near California match these filters',
        ),
      );
      await reveal(tester, find.byKey(const ValueKey('referral-211-national')));
      await reveal(
        tester,
        find.byKey(const ValueKey('referral-rebuilding-together-national')),
      );
      await tap(tester, find.text('Show all kinds of help'));
      await reveal(tester, find.text('Providers found: 0'));
      expect(
        find.text('Listed organizations near Unlisted county, CA'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new provider contact survives reopen and filtering; links carry no search or note',
    (tester) async {
      final app = await make();
      final repo = LocalHelpRepository(app.coordinator);
      await repo.confirmLocation(
        HelpLocation(stateCode: 'CA', city: '', county: 'San Mateo', zip: null),
      );
      final opened = <Uri>[];
      Widget screen() => localized(
        const Locale('en'),
        LocalHelpScreen(
          key: UniqueKey(),
          services: app,
          openExternal: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      );
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tap(tester, providerAction('Save · on this phone'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Contact note (optional)'),
        'Fictional private note',
      );
      await tester.tap(find.text('Save on this device'));
      await tester.pumpAndSettle();
      expect((await repo.load()).contacts.single.providerId, providerId);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await reveal(tester, providerAction('Saved · on this phone'));
      await tap(tester, providerAction('Open official website'));
      expect(
        opened.single.toString(),
        const OfficialReferralDirectory().provider(providerId)!.website,
      );
      await search(tester, 'no result');
      final query = find.byKey(const ValueKey('provider-search-query'));
      await reveal(tester, find.text('Fictional private note'));
      expect(
        (await repo.load()).contacts.single.note,
        'Fictional private note',
      );
      expect(opened.single.hasQuery, isFalse);
      await reveal(tester, query);
      expect(tester.widget<TextField>(query).controller!.text, 'no result');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('details open as their own page with named sources', (
    tester,
  ) async {
    final app = await make();
    await LocalHelpRepository(app.coordinator).confirmLocation(
      HelpLocation(stateCode: 'CA', city: '', county: 'San Mateo', zip: null),
    );
    final opened = <Uri>[];
    await tester.pumpWidget(
      localized(
        const Locale('en'),
        LocalHelpScreen(
          services: app,
          openExternal: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const ValueKey('help-details-$providerId')));
    final provider = const OfficialReferralDirectory().provider(providerId)!;
    expect(find.text('Where they work'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Where they work')).dy,
      lessThan(tester.getTopLeft(find.text('What they may help with')).dy),
    );
    for (final source in provider.sources) {
      expect(find.text(source), findsNothing);
    }
    final source = find.byKey(
      ValueKey('referral-source-$providerId-${provider.sources.first}'),
    );
    await reveal(tester, source);
    expect(
      find.descendant(of: source, matching: find.text('cidsanmateo.org')),
      findsOneWidget,
    );
    await tap(tester, source);
    expect(opened.single.toString(), provider.sources.first);
    await tap(tester, find.text('Save · on this phone'));
    await tester.tap(find.text('Save on this device'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Saved · on this phone'));
    await reveal(
      tester,
      find.text(
        'Saved contacts stay on this phone and are removed when you sign out.',
      ),
    );
    expect(
      (await LocalHelpRepository(
        app.coordinator,
      ).load()).contacts.single.providerId,
      providerId,
    );
    expect(tester.takeException(), isNull);
  });

  for (final id in [providerId, 'provider-habitat-east-bay-silicon-valley']) {
    testWidgets(
      'provider $id creates and reopens its shared follow-up identity',
      (tester) async {
        final h = await ReferralHarness.create();
        addTearDown(h.dispose);
        await tester.pumpWidget(
          localized(const Locale('en'), LocalHelpScreen(services: h.app)),
        );
        await tester.pumpAndSettle();
        await search(
          tester,
          const OfficialReferralDirectory().provider(id)!.name,
        );
        await tap(tester, providerAction('Add follow-up', id: id));
        expect(find.byType(ProgramProgressScreen), findsOneWidget);
        expect(h.server.tasks, isEmpty);
        await reveal(tester, find.byKey(const ValueKey('task-quick-add')));
        await tester.enterText(
          find.byKey(const ValueKey('task-quick-add')),
          'Fictional ask about modifications',
        );
        await tap(tester, find.byKey(const ValueKey('task-quick-add-button')));
        expect(h.server.tasks.values.single['kind'], 'follow_up');
        expect(
          (h.server.tasks.values.single['referral'] as Map)['providerId'],
          id,
        );
        expect(h.server.tasks.values.single['programId'], isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tap(tester, providerAction('Add follow-up', id: id));
        await reveal(tester, find.text('Fictional ask about modifications'));
        expect(h.server.tasks, hasLength(1));
        expect(h.device.requests, 0);
      },
    );
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'search, type chips and role filter wrap at large text in ${locale.toLanguageTag()}',
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
        await search(tester, tr.text('Service coordination'));
        final six = find.text(
          tr.text('Providers found: {count}', {'count': '6'}),
        );
        await reveal(tester, six);
        await tap(tester, find.text(tr.text('Clear search and filters')));
        expect(six, findsNothing);
        await tap(tester, find.byKey(const ValueKey('help-type-coordination')));
        await reveal(tester, six);
        await tap(tester, find.text(tr.text('Filter by organization role')));
        await reveal(tester, find.byKey(const ValueKey('provider-role-')));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
