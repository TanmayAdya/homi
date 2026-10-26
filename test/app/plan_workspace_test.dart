import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/home_safety/home_safety_session.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_screen.dart';
import 'package:safe_at_home/features/assistant/plan_assistant_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/plan_workspace.dart';

import '../features/assessment/domain/scan/scan_test_fixtures.dart';
import '../features/assessment/home_safety/home_safety_support.dart';
import 'app_design_test.dart' show narrowLargeText;

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  if (key.startsWith('plan-tab-')) {
    await tester.tap(target);
  } else {
    final scroll = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(target, 160, scrollable: scroll);
    await Scrollable.ensureVisible(tester.element(target), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(target);
  }
  await tester.pumpAndSettle();
}

Widget app(
  Widget home, {
  Locale locale = const Locale('en'),
  bool dark = false,
}) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: dark ? SafeAtHomeTheme.dark() : SafeAtHomeTheme.light(),
  home: RepaintBoundary(key: const ValueKey('preview'), child: home),
);

Future<void> preview(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PREVIEWS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '/tmp/safeathome-ui-$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HomeSafetyCatalog catalog;
  setUpAll(() async {
    catalog = await HomeSafetyCatalog.load();
    const fontPath = String.fromEnvironment('UI_PREVIEW_FONT');
    if (fontPath.isNotEmpty) {
      final font = FontLoader('Roboto')
        ..addFont(
          File(fontPath).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  test('all new copy has every language and preserves placeholders', () {
    for (final entry in planWorkspaceTranslations.entries) {
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      });
      final pattern = RegExp(r'\{[^}]+\}');
      final original = pattern.allMatches(entry.key).map((m) => m[0]).toSet();
      for (final text in entry.value.values) {
        expect(text.trim(), isNotEmpty);
        expect(pattern.allMatches(text).map((m) => m[0]).toSet(), original);
      }
    }
  });

  for (final locale in AppLocalizations.supportedLocales) {
    for (final dark in [false, true]) {
      testWidgets('$locale $dark navigation and assistant at 3.2x text', (
        tester,
      ) async {
        narrowLargeText(tester, scale: 3.2);
        const assistantChannel = MethodChannel('safe_at_home/assistant');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var availabilityChecks = 0;
        messenger.setMockMethodCallHandler(assistantChannel, (call) async {
          if (call.method == 'availability') {
            availabilityChecks++;
            return 'unavailable';
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(assistantChannel, null),
        );
        final h = await safetyHarness(loadedCatalog: catalog, homeSafety: true);
        addTearDown(h.services.dispose);
        await tester.pumpWidget(
          app(
            CaseWorkspaceScreen(
              services: h.services,
              homeSafetyCatalog: h.server.catalog,
            ),
            locale: locale,
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();
        final words = AppLocalizations(locale);
        for (final destination in [
          'plan',
          'rooms',
          'help',
          'tasks',
          'assistant',
        ]) {
          expect(find.byKey(ValueKey('plan-tab-$destination')), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('case-assessment')), findsNothing);
        expect(find.byKey(const ValueKey('case-room-scans')), findsNothing);
        await tapKey(tester, 'plan-tab-assistant');
        expect(find.byType(PlanAssistantScreen), findsOneWidget);
        final assistantScroll = find.descendant(
          of: find.byKey(const ValueKey('assistant-messages')),
          matching: find.byType(Scrollable),
        );
        final unavailable = find.text(
          words.text(
            'Plan chat is unavailable right now. You can still use the help tools below.',
          ),
        );
        await tester.scrollUntilVisible(
          unavailable,
          180,
          scrollable: assistantScroll,
          maxScrolls: 60,
        );
        await tester.pumpAndSettle();
        expect(unavailable, findsOneWidget);
        expect(
          tester.getRect(unavailable).overlaps(tester.getRect(assistantScroll)),
          isTrue,
          reason: 'The translated status must be reachable in the viewport.',
        );
        expect(find.byType(TextField), findsNothing);
        expect(availabilityChecks, 1);
        await tapKey(tester, 'assistant-check-availability');
        expect(availabilityChecks, 2);
        expect(find.byType(TextField), findsNothing);
        await tapKey(tester, 'assistant-rooms');
        expect(find.byType(PlanAssistantScreen), findsNothing);
        expect(find.byType(HomeSafetyScreen), findsOneWidget);
        await tapKey(tester, 'plan-tab-tasks');
        expect(
          find.text(
            words.text(
              'Tasks are disabled in this build. Check feature availability in Settings.',
            ),
          ),
          findsOneWidget,
        );
        await tapKey(tester, 'plan-tab-plan');
        expect(find.byKey(const ValueKey('plan-tab-plan')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'named room connects model, questions and concerns and resumes after tab changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final h = await safetyHarness(
        loadedCatalog: catalog,
        homeSafety: true,
        tracking: true,
      );
      addTearDown(h.services.dispose);
      final session = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await session.initialize();
      await session.edit(
        addRoom('upstairs', type: 'bathroom', name: 'Main bathroom'),
      );
      await session.edit(
        addRoom('downstairs', type: 'bathroom', name: 'Guest bathroom'),
      );
      await session.save();
      final room = session.document.rooms.first;
      final caseId = session.caseId;
      session.dispose();
      final modelKey = BathroomScanSession.storageKey(caseId, room: room);
      h.store.bytes[modelKey] = Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            BathroomScanReview(
              scene: fictionalScanScene(),
            ).toJson(caseId, room: room),
          ),
        ),
      );
      final originalModel = Uint8List.fromList(h.store.bytes[modelKey]!);
      final root = CaseWorkspaceScreen(
        services: h.services,
        homeSafetyCatalog: h.server.catalog,
      );
      await tester.pumpWidget(app(root));
      await tester.pumpAndSettle();
      await preview(tester, 'plan');
      await tapKey(tester, 'plan-tab-rooms');
      await tapKey(tester, 'room-upstairs');
      expect(find.text('View room model'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('room-concerns')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('room-concerns')), findsOneWidget);
      await preview(tester, 'room');
      await tapKey(tester, 'room-continue-questions');
      expect(find.text('Room questions'), findsOneWidget);
      await tapKey(tester, 'rooms-back');
      await tester.pumpAndSettle();
      expect(find.text('View room model'), findsOneWidget);
      await tapKey(tester, 'room-concerns');
      expect(find.text('Concerns and evidence'), findsOneWidget);
      await tapKey(tester, 'rooms-back');
      await tester.pumpAndSettle();
      await tapKey(tester, 'plan-tab-tasks');
      expect(find.byType(ProgramProgressScreen), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      await preview(tester, 'tasks');
      await tapKey(tester, 'plan-tab-rooms');
      expect(find.text('Main bathroom'), findsOneWidget);
      expect(find.text('View room model'), findsOneWidget);
      expect(h.store.bytes[modelKey], originalModel);
      await tapKey(tester, 'rooms-back');
      await tester.pumpAndSettle();
      await tapKey(tester, 'room-downstairs');
      expect(
        find.byKey(const ValueKey('room-start-assessment')),
        findsOneWidget,
      );
      expect(find.text('View room model'), findsNothing);
      expect(h.store.bytes[modelKey], originalModel);
      await tapKey(tester, 'plan-tab-plan');
      await tapKey(tester, 'plan-tab-assistant');
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final outcome in ['online', 'offline', 'lost response']) {
    final offline = outcome == 'offline';
    testWidgets(
      'question edits save automatically; $outcome survives leaving and reopening',
      (tester) async {
        final h = await safetyHarness(loadedCatalog: catalog, homeSafety: true);
        addTearDown(h.services.dispose);
        final s = HomeSafetySession(
          services: h.services,
          catalog: h.server.catalog,
        );
        await s.initialize();
        await s.edit(addRoom('bedroom', name: 'Fictional bedroom'));
        await s.save();
        s.dispose();
        h.server.offline = offline;
        h.server.loseNextSave = outcome == 'lost response';
        await tester.pumpWidget(
          app(
            CaseWorkspaceScreen(
              services: h.services,
              homeSafetyCatalog: h.server.catalog,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapKey(tester, 'plan-tab-rooms');
        await tapKey(tester, 'room-bedroom');
        await tapKey(tester, 'room-continue-questions');
        await tapKey(tester, 'answer-bedroom.path-not_sure');
        if (!offline) {
          expect(
            h.server.document.answer('bedroom', 'bedroom.path')?.value,
            'not_sure',
          );
        }
        await tapKey(tester, 'plan-tab-plan');
        await tapKey(tester, 'plan-tab-rooms');
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('answer-bedroom.path')),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        final answer = tester.widget<RadioGroup<String>>(
          find.byKey(const ValueKey('answer-bedroom.path')),
        );
        expect(answer.groupValue, 'not_sure');
        expect(h.services.coordinator.currentCase().findings, isEmpty);
        if (outcome == 'lost response') expect(h.server.saves, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets('assistant shortcuts are ordinary navigation; dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final sections = <int>[];
      await tester.pumpWidget(
        app(PlanAssistantScreen(onSection: sections.add), dark: dark),
      );
      await tester.pumpAndSettle();
      await preview(tester, dark ? 'assistant-dark' : 'assistant');
      expect(find.byType(TextField), findsNothing);
      expect(
        find.text(
          'Plan chat is unavailable right now. You can still use the help tools below.',
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'assistant-next-step');
      await tapKey(tester, 'assistant-rooms');
      await tapKey(tester, 'assistant-help');
      expect(sections, [0, 1, 2]);
    });
  }

  testWidgets('room refresh cannot be interrupted by switching tabs', (
    tester,
  ) async {
    final h = await safetyHarness(loadedCatalog: catalog, homeSafety: true);
    addTearDown(h.services.dispose);
    await tester.pumpWidget(
      app(
        CaseWorkspaceScreen(
          services: h.services,
          homeSafetyCatalog: h.server.catalog,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'plan-tab-rooms');
    final release = Completer<void>();
    h.server.beforeRead = () => release.future;
    final refresh = find.widgetWithText(TextButton, 'Check saved state');
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('plan-tab-plan')));
    await tester.pump();
    expect(find.byType(HomeSafetyScreen), findsOneWidget);
    expect(
      find.text('Finish saving before changing sections.'),
      findsOneWidget,
    );
    release.complete();
    await tester.pumpAndSettle();
    await tapKey(tester, 'plan-tab-plan');
    expect(find.byType(HomeSafetyScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Plan keeps permanent entries without suggested next steps', (
    tester,
  ) async {
    final h = await safetyHarness(
      loadedCatalog: catalog,
      homeSafety: true,
      tracking: true,
    );
    addTearDown(h.services.dispose);
    h.server.tasks.add({
      'id': 'call',
      'programId': null,
      'findingId': null,
      'formId': null,
      'title': 'Fictional call to 李家',
      'kind': 'contact',
      'state': 'pending',
      'responsiblePerson': null,
      'dueOn': '2020-01-01',
      'basedOnCaseRevision': h.server.snapshot.revision,
      'basedOnRuleVersion': null,
      'revision': 1,
      'sourceEventId': null,
      'needsReview': false,
    });
    await h.services.progress!.refresh(h.server.snapshot.caseId);
    await tester.pumpWidget(
      app(
        CaseWorkspaceScreen(
          services: h.services,
          homeSafetyCatalog: h.server.catalog,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('case-next-step')), findsNothing);
    expect(find.text('Suggested next step'), findsNothing);
    expect(find.text('Start with a room'), findsNothing);
    await tapKey(tester, 'case-tasks');
    expect(find.byType(ProgramProgressScreen), findsOneWidget);
    h.server.tasks.single['needsReview'] = true;
    await h.services.progress!.refresh(h.server.snapshot.caseId);
    await tapKey(tester, 'plan-tab-plan');
    expect(find.byKey(const ValueKey('case-next-step')), findsNothing);
    await tapKey(tester, 'case-rooms');
    expect(find.byType(HomeSafetyScreen), findsOneWidget);
  });
}
