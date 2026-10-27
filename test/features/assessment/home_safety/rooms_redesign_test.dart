import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/home_safety/home_safety_session.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_screen.dart';
import 'home_safety_support.dart';

Map<String, Object?> _concern(String state) => {
  'type': 'review_concern',
  'roomId': 'bedroom',
  'questionId': 'bedroom.path',
  'findingId': 'path-concern',
  'observation': 'Fictional cluttered path',
  'state': state,
};

void main() {
  testWidgets(
    'rooms show one status each and the room next step moves from review to help',
    (tester) async {
      final catalog = (await tester.runAsync(HomeSafetyCatalog.load))!;
      final h = (await tester.runAsync(() async {
        final h = await safetyHarness(homeSafety: true, loadedCatalog: catalog);
        final s = HomeSafetySession(services: h.services, catalog: catalog);
        await s.initialize();
        await s.edit(addRoom('bedroom', name: 'Fictional bedroom'));
        await s.edit(addRoom('hall', name: 'Fictional hall'));
        await s.edit(
          addRoom('yard', type: 'outdoorPaths', name: 'Fictional yard'),
        );
        await s.edit(answer('bedroom', 'yes'));
        await s.edit(_concern('needs_review'));
        await s.save();
        s.dispose();
        return h;
      }))!;
      addTearDown(h.services.dispose);
      String? helpFor;
      final key = GlobalKey<HomeSafetyScreenState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeSafetyScreen(
              key: key,
              services: h.services,
              catalog: catalog,
              workspaceMode: true,
              embedded: true,
              onFindHelp: (id) => helpFor = id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder inRow(String room, String text) => find.descendant(
        of: find.byKey(ValueKey('room-$room')),
        matching: find.text(text),
      );
      expect(inRow('bedroom', '1 suggested concern to review'), findsOneWidget);
      expect(inRow('hall', 'Not started'), findsOneWidget);
      expect(find.text('Inside'), findsOneWidget);
      expect(find.text('Outside'), findsOneWidget);
      expect(find.textContaining('0 of'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('rooms-save-status')),
          matching: find.text('Saved'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('rooms-sync')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('room-bedroom')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-next-review')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room-next-review')));
      await tester.pumpAndSettle();
      expect(find.text('Fictional cluttered path'), findsOneWidget);
      expect(find.text('Needs your review'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('concern-find-help-path-concern')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('rooms-back')));
      await tester.pumpAndSettle();

      final state = key.currentState!;
      await tester.runAsync(() async {
        await state.session!.edit(_concern('confirmed'));
        await state.session!.save();
      });
      await tester.pumpAndSettle();
      final help = find.byKey(const ValueKey('room-find-help'));
      expect(help, findsOneWidget);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(helpFor, 'path-concern');

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('room-continue-questions')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('room-continue-questions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('room-continue-questions')));
      await tester.pumpAndSettle();
      expect(find.text('Room questions'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('room-return-overview')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('room-find-help')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('room-return-overview')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('room-return-overview')));
      await tester.pumpAndSettle();
      expect(state.selectedRoom, 'bedroom');
      await tester.tap(find.byKey(const ValueKey('rooms-back')));
      await tester.pumpAndSettle();
      expect(inRow('bedroom', '1 concern'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('room-yard')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-next-questions')), findsOneWidget);
      expect(find.byKey(const ValueKey('room-start-assessment')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a changed concern status offers Undo on the same finding, and an answer can be cleared',
    (tester) async {
      final catalog = (await tester.runAsync(HomeSafetyCatalog.load))!;
      final h = (await tester.runAsync(() async {
        final h = await safetyHarness(homeSafety: true, loadedCatalog: catalog);
        final s = HomeSafetySession(services: h.services, catalog: catalog);
        await s.initialize();
        await s.edit(addRoom('bedroom', name: 'Fictional bedroom'));
        await s.edit(answer('bedroom', 'yes'));
        await s.edit(_concern('needs_review'));
        await s.save();
        s.dispose();
        return h;
      }))!;
      addTearDown(h.services.dispose);
      final key = GlobalKey<HomeSafetyScreenState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeSafetyScreen(
              key: key,
              services: h.services,
              catalog: catalog,
              workspaceMode: true,
              embedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> reveal(Finder target) async {
        await tester.scrollUntilVisible(
          target,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder target) async {
        await reveal(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      String state() => key.currentState!.session!.snapshot.findings
          .singleWhere((f) => f.id == 'path-concern')
          .reviewState;
      await tester.tap(find.byKey(const ValueKey('room-bedroom')));
      await tester.pumpAndSettle();
      await tap(find.byKey(const ValueKey('room-continue-questions')));
      await reveal(find.byKey(const ValueKey('answer-state-bedroom.path')));
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('answer-state-bedroom.path')),
            )
            .data,
        'Answered',
      );
      await tap(find.text('Review linked concern').first);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmed').last);
      await tester.pumpAndSettle();
      Future<void> settle() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Save reviewed concern'));
      await settle();
      expect(state(), 'confirmed');
      expect(find.text('Concern updated'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await settle();
      expect(state(), 'needs_review');
      expect(
        key.currentState!.session!.snapshot.findings.map((f) => f.id),
        ['path-concern'],
        reason: 'Undo reuses the same finding ID',
      );

      await tap(find.byKey(const ValueKey('answer-clear-bedroom.path')));
      expect(
        key.currentState!.session!.document
            .answer('bedroom', 'bedroom.path')
            ?.value,
        'unanswered',
      );
      expect(
        tester
            .widget<RadioGroup<String>>(
              find.byKey(const ValueKey('answer-bedroom.path')),
            )
            .groupValue,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
