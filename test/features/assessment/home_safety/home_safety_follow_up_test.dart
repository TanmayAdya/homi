import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/home_safety/home_safety_session.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'home_safety_support.dart';

void main() {
  testWidgets(
    'checklist entry is hidden by default and enabled independently',
    (tester) async {
      for (final enabled in [false, true]) {
        final h = (await tester.runAsync(
          () => safetyHarness(homeSafety: enabled),
        ))!;
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: CaseWorkspaceScreen(
              services: h.services,
              homeSafetyCatalog: h.server.catalog,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('plan-tab-rooms')));
        await tester.pumpAndSettle();
        expect(
          find.byType(HomeSafetyScreen),
          enabled ? findsOneWidget : findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        h.services.dispose();
      }
    },
  );

  testWidgets(
    'checklist links the existing task editor and completion stays separate from addressed progress',
    (tester) async {
      final catalog = (await tester.runAsync(HomeSafetyCatalog.load))!;
      final h = await (() async {
        final h = await safetyHarness(tracking: true, loadedCatalog: catalog);
        final s = HomeSafetySession(
          services: h.services,
          catalog: h.server.catalog,
        );
        await s.initialize();
        await s.edit(addRoom('bedroom', name: 'Fictional bedroom'));
        await s.edit(answer('bedroom', 'yes'));
        await s.edit({
          'type': 'review_concern',
          'roomId': 'bedroom',
          'questionId': 'bedroom.path',
          'findingId': 'new-concern',
          'observation': 'Fictional lighting concern',
          'state': 'confirmed',
        });
        await s.save();
        s.dispose();
        h.server.tasks.add({
          'id': 'unrelated',
          'programId': null,
          'findingId': null,
          'formId': null,
          'title': 'Unrelated follow-up',
          'kind': 'other',
          'state': 'pending',
          'responsiblePerson': null,
          'dueOn': null,
          'basedOnCaseRevision': h.server.snapshot.revision,
          'basedOnRuleVersion': null,
          'revision': 1,
          'sourceEventId': null,
          'needsReview': false,
        });
        return h;
      })();
      addTearDown(h.services.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeSafetyScreen(
            services: h.services,
            catalog: h.server.catalog,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> reveal(Finder target) async {
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pump();
        await tester.scrollUntilVisible(
          target,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      await reveal(find.text('Fictional bedroom'));
      await tester.tap(find.text('Fictional bedroom'));
      await tester.pumpAndSettle();
      final taskButton = find.byKey(
        const ValueKey('concern-tasks-new-concern'),
      );
      await reveal(taskButton);
      expect(
        tester.widget<TextButton>(taskButton).onPressed,
        isNotNull,
        reason:
            'case dirty=${h.services.coordinator.hasUnsavedChanges} conflict=${h.services.coordinator.conflict}',
      );
      await tester.tap(taskButton);
      await tester.pumpAndSettle();
      expect(
        find.text('Next steps for this concern'),
        findsOneWidget,
        reason: find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .join(' | '),
      );
      expect(find.text('Unrelated follow-up'), findsNothing);
      final quickAdd = find.byKey(const ValueKey('task-quick-add'));
      await reveal(quickAdd);
      await tester.enterText(quickAdd, 'Fictional check of the bedroom lamp');
      await tester.tap(find.byKey(const ValueKey('task-quick-add-button')));
      await tester.pumpAndSettle();
      expect(
        h.server.tasks.where((t) => t['findingId'] == 'new-concern').length,
        1,
      );
      expect(
        h.server.tasks
            .where((t) => t['findingId'] == 'new-concern')
            .single['kind'],
        'room_review',
      );
      final task = h.server.tasks.singleWhere(
        (t) => t['findingId'] == 'new-concern',
      );
      expect(task['title'], 'Fictional check of the bedroom lamp');
      final done = find.byKey(ValueKey('task-done-${task['id']}'));
      await reveal(done);
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(
        h.server.tasks
            .where((t) => t['findingId'] == 'new-concern')
            .single['state'],
        'completed',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await reveal(find.text('0 of 1 concerns addressed'));
      final addressedButton = find.byKey(
        const ValueKey('concern-addressed-new-concern'),
      );
      await reveal(addressedButton);
      await tester.tap(addressedButton);
      await tester.pumpAndSettle();
      expect(find.text('Mark concern addressed?'), findsOneWidget);
      await tester.tap(find.text('Mark addressed').last);
      await tester.pumpAndSettle();
      await reveal(find.text('1 of 1 concerns addressed'));
      expect(find.text('1 of 1 concerns addressed'), findsOneWidget);
      expect(h.server.tasks.length, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
