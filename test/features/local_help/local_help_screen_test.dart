import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/cases/profile_response_state.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/local_help_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/local_help.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';

import '../../app/app_design_test.dart' show narrowLargeText;
import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../app/core_localization_test.dart' show localized;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import 'local_help_test.dart' show FailingHelpStore;

Future<AppServices> make({
  bool enabled = true,
  MemoryPrivateStore? store,
}) async {
  final app = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://example.org'),
      supabaseUrl: Uri.parse('https://example.supabase.co'),
      publishableKey: 'fictional',
      localHelpEnabled: enabled,
    ),
    session: FakeSession(),
    store: store ?? MemoryPrivateStore(),
    transport: FakeTransport(
      (_) async => throw StateError('No network allowed'),
    ),
  );
  await app.coordinator.createDraft();
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  return app;
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  await tester.pumpAndSettle();
  final scrollable = find.byType(Scrollable).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: scrollable,
    maxScrolls: 800,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Finder firstProviderAction(String label) => find.descendant(
  of: find.byKey(const ValueKey('referral-211-national')),
  matching: find.text(label),
);
Future<void> tap(WidgetTester tester, Finder finder) async {
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'feature flag hides entry; enabled workspace opens finder offline',
    (tester) async {
      final off = await make(enabled: false);
      await tester.pumpWidget(
        localized(const Locale('en'), CaseWorkspaceScreen(services: off)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan-tab-help')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('case-local-help')), findsNothing);
      final app = await make();
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          CaseWorkspaceScreen(key: UniqueKey(), services: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('plan-tab-help')));
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('case-local-help')));
      expect(find.byType(LocalHelpScreen), findsOneWidget);
      expect(find.text('Find help'), findsOneWidget);
      expect(find.text('Organizations and referrals'), findsOneWidget);
      expect(find.text('Programs for this plan'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    },
  );

  testWidgets('a closed plan shows recovery without exposing saved contacts', (
    tester,
  ) async {
    final app = await make();
    await app.coordinator.clearSelected();
    await tester.pumpWidget(
      localized(const Locale('en'), LocalHelpScreen(services: app)),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Reopen the selected plan to use local help.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'explicit tap opens fixed dialer; failure shows useful fallback',
    (tester) async {
      final app = await make();
      final opened = <Uri>[];
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          LocalHelpScreen(
            services: app,
            openExternal: (uri) async {
              opened.add(uri);
              return false;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await tap(tester, find.text('Call 211'));
      expect(opened.single.toString(), 'tel:211');
      await reveal(
        tester,
        find.textContaining('Could not open this link or dialer.'),
      );
      expect(
        find.textContaining('Could not open this link or dialer.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('contact save failure retains input, then retry saves once', (
    tester,
  ) async {
    final store = FailingHelpStore();
    final app = await make(store: store);
    await tester.pumpWidget(
      localized(const Locale('en'), LocalHelpScreen(services: app)),
    );
    await tester.pumpAndSettle();
    await tap(tester, firstProviderAction('Save · on this phone'));
    final field = find.widgetWithText(TextFormField, 'Contact note (optional)');
    await tester.enterText(field, 'Fictional note {count}');
    store.fail = true;
    await tester.tap(find.text('Save on this device'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Fictional note {count}'), findsOneWidget);
    store.fail = false;
    await tester.tap(find.text('Save on this device'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      (await LocalHelpRepository(app.coordinator).load()).contacts.single.note,
      'Fictional note {count}',
    );
    await reveal(tester, firstProviderAction('Saved · on this phone'));
    await reveal(
      tester,
      find.textContaining('Saved on this phone only for this plan.'),
    );
  });

  testWidgets(
    'disabled tracking retains local work and offers a recovery message',
    (tester) async {
      final app = await make();
      await tester.pumpWidget(
        localized(const Locale('en'), LocalHelpScreen(services: app)),
      );
      await tester.pumpAndSettle();
      await tap(tester, firstProviderAction('Add follow-up'));
      await reveal(
        tester,
        find.textContaining('Save this plan online and enable My next steps'),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        (await LocalHelpRepository(app.coordinator).load()).tasks,
        isEmpty,
      );
    },
  );

  testWidgets(
    'confirmed unsupported location retains national fallback and does not send location',
    (tester) async {
      final app = await make();
      await LocalHelpRepository(
        app.coordinator,
      ).saveContact('referral-211-bay-area', 'Fictional saved contact');
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
      await tap(tester, find.text('Add county (optional)'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'County (optional)'),
        'Fictional county',
      );
      final state = find.byKey(const ValueKey('help-location-state'));
      tester.state<FormFieldState<String>>(state).didChange('NY');
      tester.widget<DropdownButtonFormField<String>>(state).onChanged!('NY');
      await tester.pumpAndSettle();
      await tap(tester, find.text('Confirm location'));
      await reveal(
        tester,
        find.text('Searching near · Fictional county, New York'),
      );
      expect(find.text('Confirm location'), findsNothing);
      await tap(tester, find.text('Find my local 211'));
      expect(
        opened.single.toString(),
        'https://211.org/about-us/your-local-211',
      );
      expect(find.byKey(const ValueKey('referral-211-bay-area')), findsNothing);
      await reveal(tester, find.text('8002736222'));
      expect(find.text('8002736222'), findsOneWidget);
      expect(find.text('https://211bayarea.org/contact/'), findsNothing);
      expect(
        (await LocalHelpRepository(app.coordinator).load()).location!.zip,
        isNull,
      );
    },
  );

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('large text finder and saved resident notes in $locale', (
      tester,
    ) async {
      narrowLargeText(tester, scale: 3.2);
      final app = await make();
      final repository = LocalHelpRepository(app.coordinator);
      await repository.saveContact(
        'referral-211-national',
        'Fictional resident {count}',
      );
      await repository.saveTask(
        HelpFollowUp(
          id: 'fictional-task',
          providerId: 'referral-211-national',
          title: 'Fictional task',
          responsible: '',
          dueDate: null,
          createdAt: '2026-10-24T00:00:00.000Z',
        ),
      );
      await tester.pumpWidget(
        localized(locale, LocalHelpScreen(services: app)),
      );
      await tester.pumpAndSettle();
      final tr = AppLocalizations(locale);
      await reveal(tester, find.text(tr.text('Saved contacts')));
      await reveal(tester, find.text('Fictional resident {count}'));
      await reveal(tester, find.text(tr.text('Import local follow-up')));
      expect((await repository.load()).tasks.single.completedAt, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'new copy has translations in every supported language with matching placeholders',
    () {
      for (final entry in localHelpTranslations.entries) {
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
          expect(
            RegExp(r'\{[^}]+\}').allMatches(text).map((m) => m[0]).toSet(),
            placeholders,
          );
        }
      }
    },
  );

  testWidgets(
    'Help starts near the resident and can return after searching elsewhere',
    (tester) async {
      final app = await make();
      final c = app.coordinator;
      final value = c.currentDraft().toJson();
      value['profile'] = {
        ...(value['profile'] as Map<String, Object?>),
        'city': 'Fictional city',
        'county': 'Santa Clara',
      };
      await c.updateDraft(CaseDraft.fromJson(value));
      final draft = c.currentDraft();
      await app.profileResponses.write(
        draft.caseId,
        draft.profile,
        const ProfileResponseState(stateCode: 'CA', zip: '95112'),
      );
      await tester.pumpWidget(
        localized(const Locale('en'), LocalHelpScreen(services: app)),
      );
      await tester.pumpAndSettle();
      const resident =
          'Near the resident · Fictional city, Santa Clara, California, 95112';
      await reveal(tester, find.text(resident));
      expect(find.text('Confirm location'), findsNothing);
      expect(
        find.byKey(const ValueKey('help-use-resident-area')),
        findsNothing,
      );
      expect((await LocalHelpRepository(c).load()).location, isNull);

      await tap(tester, find.byKey(const ValueKey('help-location-change')));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'ZIP code or city (optional)'),
        '10001',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'County (optional)'),
        '',
      );
      await tap(tester, find.text('Confirm location'));
      await reveal(tester, find.text('Searching near · New York, 10001'));

      await tap(tester, find.byKey(const ValueKey('help-use-resident-area')));
      await reveal(tester, find.text(resident));
      final saved = (await LocalHelpRepository(c).load()).location!;
      expect(
        (saved.stateCode, saved.zip, saved.city),
        ('CA', '95112', 'Fictional city'),
      );
      expect(
        find.byKey(const ValueKey('help-use-resident-area')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
