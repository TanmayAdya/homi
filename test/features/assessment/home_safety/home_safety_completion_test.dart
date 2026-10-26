import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/home_safety/home_safety_session.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_screen.dart';
import 'home_safety_support.dart';
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_report_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';

void main() {
  test(
    'Node completion fixture preserves notes, addressed reports, revisions and exact receipts in Dart',
    () async {
      final catalog = await HomeSafetyCatalog.load();
      final fixture =
          jsonDecode(
                await File(
                  'contracts/v3/fixtures/home-safety-completion.json',
                ).readAsString(),
              )
              as Map;
      final state = HomeSafetyState.fromJson(fixture['state'], catalog);
      final operations = state.history.map(
        (e) => Map<String, Object?>.from(e['operation'] as Map),
      );
      final link = state.document.findingRooms.single;
      expect(
        concernIsAddressed(
          state.document,
          state.snapshot,
          link,
          operations,
          evidenceCatalogRevision: state.evidenceCatalogRevision,
        ),
        true,
      );
      expect(
        answerAnnotation(operations, link.roomId, link.questionId!)!['note'],
        contains('Fictional resident note'),
      );
      for (final request in fixture['requests'] as List) {
        expect(
          state.acknowledges(SafetyMutation.fromJson(request, catalog)),
          true,
        );
      }
    },
  );
  test(
    'question notes work offline without inventing an answer and legacy suggestions do not infer other rooms',
    () async {
      final h = await safetyHarness();
      var s = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await s.initialize();
      await s.edit(
        addRoom('one', type: 'bathroom', name: 'Fictional first bathroom'),
      );
      await s.edit(
        addRoom('two', type: 'bathroom', name: 'Fictional second bathroom'),
      );
      expect(suggestedRooms(s.document, 'bathroom').map((r) => r.id), [
        'one',
        'two',
      ]);
      expect(suggestedRooms(s.document, 'other'), isEmpty);
      final question = s.catalog.forRoom(s.document.rooms.first).first;
      await s.edit({
        'type': 'annotate_answer',
        'roomId': 'one',
        'questionId': question.id,
        'answerRevision': 0,
        'note': 'Fictional original note',
        'expectedCatalogRevision': 0,
        'evidence': <Object>[],
      });
      expect(s.document.answer('one', question.id), isNull);
      s.dispose();
      h.server.offline = true;
      s = HomeSafetySession(services: h.services, catalog: h.server.catalog);
      await s.initialize();
      expect(
        answerAnnotation(s.operations, 'one', question.id)!['note'],
        'Fictional original note',
      );
      await s.edit({
        'type': 'annotate_answer',
        'roomId': 'one',
        'questionId': question.id,
        'answerRevision': 0,
        'note': 'Fictional corrected note',
        'expectedCatalogRevision': 0,
        'evidence': <Object>[],
      });
      h.server.offline = false;
      await s.save();
      expect(
        s.baseline.history
            .where((e) => (e['operation'] as Map)['type'] == 'annotate_answer')
            .length,
        2,
      );
      expect(answerAnnotation(s.operations, 'two', question.id), isNull);
      s.dispose();
      h.services.dispose();
    },
  );

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'checklist report controls remain reachable at 3.2x in $locale',
      (tester) async {
        final catalog = (await tester.runAsync(HomeSafetyCatalog.load))!;
        final h = await safetyHarness(loadedCatalog: catalog);
        final s = HomeSafetySession(services: h.services, catalog: catalog);
        await s.initialize();
        addTearDown(() {
          s.dispose();
          h.services.dispose();
        });
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(
                ctx,
              ).copyWith(textScaler: const TextScaler.linear(3.2)),
              child: child!,
            ),
            home: HomeSafetyReportScreen(services: h.services, session: s),
          ),
        );
        await tester.pumpAndSettle();
        final label = AppLocalizations(locale).text('Prepare checklist report');
        await tester.scrollUntilVisible(
          find.text(label),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(label), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'legacy room suggestion requires choosing between two bathrooms and preserves the observation',
    (tester) async {
      final catalog = (await tester.runAsync(HomeSafetyCatalog.load))!;
      final h = await safetyHarness(loadedCatalog: catalog);
      h.server.snapshot = parseCurrentCase({
        ...h.server.snapshot.toJson(),
        'findings': [
          {
            'id': 'legacy-bathroom',
            'room': 'bathroom',
            'observation': 'Fictional original bathroom observation',
            'reviewState': 'confirmed',
            'evidenceIds': <Object>[],
            'measurements': <Object>[],
          },
        ],
      });
      await h.services.coordinator.adoptRemoteSnapshot(h.server.snapshot);
      final s = HomeSafetySession(services: h.services, catalog: catalog);
      await s.initialize();
      await s.edit(
        addRoom('one', type: 'bathroom', name: 'Fictional first bathroom'),
      );
      await s.edit(
        addRoom('two', type: 'bathroom', name: 'Fictional second bathroom'),
      );
      await s.save();
      s.dispose();
      addTearDown(h.services.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeSafetyScreen(services: h.services, catalog: catalog),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Fictional original bathroom observation'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(h.server.document.findingRooms, isEmpty);
      await tester.tap(find.text('Fictional original bathroom observation'));
      await tester.pumpAndSettle();
      final dialog = find.byType(SimpleDialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Fictional first bathroom'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.text('Fictional second bathroom'),
        ),
      );
      await tester.pumpAndSettle();
      final record = h.store.records.values.firstWhere(
        (v) => v.containsKey('baseline'),
      );
      final operation =
          ((record['pending'] as List).single as Map)['operation'] as Map;
      expect(operation['roomId'], 'two');
      expect(
        h.server.snapshot.findings.single.observation,
        'Fictional original bathroom observation',
      );
      expect(h.server.snapshot.revision, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'optional note retry retains input; owner report previews only after deliberate preparation',
    (tester) async {
      final catalog = (await tester.runAsync(HomeSafetyCatalog.load))!;
      final h = await safetyHarness(loadedCatalog: catalog);
      final s = HomeSafetySession(services: h.services, catalog: catalog);
      await s.initialize();
      await s.edit(addRoom('one', name: 'Fictional bedroom'));
      await s.save();
      s.dispose();
      addTearDown(h.services.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeSafetyScreen(services: h.services, catalog: catalog),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> reveal(Finder finder) async {
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pump();
        await tester.scrollUntilVisible(
          finder,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      await reveal(find.text('Fictional bedroom'));
      await tester.tap(find.text('Fictional bedroom'));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('question-notes-bedroom.path'));
      await reveal(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Fictional retained note');
      h.store.fail = true;
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.text('Fictional retained note'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      h.store.fail = false;
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byTooltip('Room and checklist report'));
      await tester.pumpAndSettle();
      expect(find.text('Fictional report preview'), findsNothing);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Include question notes'),
            )
            .value,
        false,
      );
      await reveal(find.text('Prepare checklist report'));
      await tester.tap(find.text('Prepare checklist report'));
      await tester.pumpAndSettle();
      expect(find.text('Fictional report preview'), findsOneWidget);
      var privateCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('safe_at_home/private_media'),
        (call) async {
          privateCalls++;
          return '/unused-private-root';
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('safe_at_home/private_media'),
          null,
        ),
      );
      h.server.apply(
        SafetyMutation.fromJson({
          'schemaVersion': '3',
          'caseId': h.server.snapshot.caseId,
          'expectedCaseRevision': h.server.snapshot.revision,
          'expectedSafetyRevision': h.server.history.length,
          'mutationId': 'fictional-remote-rename',
          'operation': {
            'type': 'rename_room',
            'roomId': 'one',
            'name': 'Fictional changed room',
          },
        }, catalog),
      );
      await reveal(find.text('Open share sheet'));
      await tester.tap(find.text('Open share sheet'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Open share sheet'),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(
        find.text(
          'The report changed or could not be shared. Prepare a fresh report and try again.',
        ),
      );
      expect(privateCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
