import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/local_help_screen.dart';
import 'package:safe_at_home/features/local_help/nationwide_help_browser.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/features/tracking/task_editor_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../test/features/local_help/referral_test_support.dart';

const _providerId = 'rt-seattle-wa';

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: SafeAtHomeTheme.light(),
  home: home,
);

Future<void> _settle(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 100));

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final scrollable = find.byType(Scrollable).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await _settle(tester);
  for (var i = 0; i < 250 && finder.evaluate().isEmpty; i++) {
    final rect = tester.getRect(scrollable);
    await tester.dragFrom(
      Offset(rect.left + 8, rect.center.dy),
      const Offset(0, -220),
    );
    await _settle(tester);
  }
  expect(finder, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _selectWashington(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('help-location-state')));
  final option = find.widgetWithText(DropdownMenuItem<String>, 'Washington');
  await tester.scrollUntilVisible(
    option,
    220,
    scrollable: find.byType(Scrollable).last,
    maxScrolls: 100,
  );
  await Scrollable.ensureVisible(tester.element(option), alignment: .5);
  await _settle(tester);
  await tester.tap(
    find.descendant(of: option, matching: find.text('Washington')),
  );
  await _settle(tester);
}

Finder _providerAction(String label) => find.descendant(
  of: find.byKey(const ValueKey(_providerId)),
  matching: find.widgetWithText(TextButton, label),
);

Future<void> _findSeattle(WidgetTester tester, {bool savedPlan = false}) async {
  if (savedPlan) {
    await _tap(tester, find.byKey(const ValueKey('local-provider-search')));
  }
  final query = find.byKey(const ValueKey('provider-search-query'));
  await _reveal(tester, query);
  await tester.enterText(query, 'Seattle');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await _settle(tester);
  await _tap(
    tester,
    find.byKey(const ValueKey('provider-result-$_providerId')),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'nationwide browser confirms Washington and preserves restricted area and private link boundaries',
    (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        _app(
          NationwideHelpBrowser(
            now: () => DateTime(2026, 10, 26),
            openExternal: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await _settle(tester);
      expect(opened, isEmpty);
      await _selectWashington(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'ZIP code or city (optional)'),
        'Fictional private city',
      );
      await _tap(tester, find.text('Add county (optional)'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'County (optional)'),
        'King',
      );
      await _tap(tester, find.text('Confirm location'));
      expect(
        find.textContaining('Fictional private city, King, Washington'),
        findsOneWidget,
      );
      await _findSeattle(tester);
      final card = find.byKey(const ValueKey(_providerId));
      await _reveal(
        tester,
        find.descendant(
          of: card,
          matching: find.textContaining('selected areas only'),
        ),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Coverage unknown: contact to confirm.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(
            'Listed for this county; confirm address coverage.',
          ),
        ),
        findsNothing,
      );
      await _tap(tester, find.widgetWithText(TextButton, 'Find my local 211'));
      expect(
        opened.single.toString(),
        'https://211.org/about-us/your-local-211',
      );
      expect(opened.single.hasQuery, isFalse);
      expect(opened.single.hasFragment, isFalse);
      await _tap(tester, _providerAction('Save · on this phone'));
      expect(find.text('Save to a plan'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.text('Create or open a plan to save contacts and add follow-ups.'),
        findsWidgets,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Washington contact and explicitly saved linked task survive reopening without notifications or real HTTP',
    (tester) async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final repository = LocalHelpRepository(h.app.coordinator);
      await repository.confirmLocation(
        HelpLocation(
          stateCode: 'WA',
          city: 'Seattle',
          county: 'King',
          zip: '98101',
        ),
      );
      await tester.pumpWidget(
        _app(
          LocalHelpScreen(
            services: h.app,
            now: () => DateTime(2026, 10, 26),
            openExternal: (_) async =>
                throw StateError('No external launch expected'),
          ),
        ),
      );
      await _settle(tester);
      await _findSeattle(tester, savedPlan: true);
      await _tap(tester, _providerAction('Save · on this phone'));
      const note = 'Fictional Washington follow-up note';
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Contact note (optional)'),
        note,
      );
      await tester.tap(find.text('Save on this device'));
      await _settle(tester);
      expect((await repository.load()).contacts.single.providerId, _providerId);
      expect((await repository.load()).contacts.single.note, note);
      await _tap(tester, _providerAction('Add follow-up'));
      expect(find.byType(ProgramProgressScreen), findsOneWidget);
      expect(h.server.tasks, isEmpty);
      await _tap(tester, find.text('Add with details'));
      expect(find.byType(TaskEditorScreen), findsOneWidget);
      const title = 'Fictional ask about Seattle corridor coverage';
      await tester.enterText(
        find.widgetWithText(TextFormField, 'What needs doing?'),
        title,
      );
      await _tap(tester, find.text('Save task'));
      expect(h.server.tasks, hasLength(1));
      final task = h.server.tasks.values.single;
      expect((task['referral'] as Map)['providerId'], _providerId);
      expect(task['programId'], isNull);
      expect(task['title'], title);
      expect(h.device.requests, 0);
      expect(h.device.scheduled, isEmpty);
      await tester.pageBack();
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      await tester.pumpWidget(_app(LocalHelpScreen(services: h.app)));
      await _settle(tester);
      await _reveal(tester, find.text(note));
      expect((await repository.load()).location!.stateCode, 'WA');
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
