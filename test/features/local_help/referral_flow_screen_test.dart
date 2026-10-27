import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/local_help_screen.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/features/tracking/task_editor_screen.dart';
import '../../app/core_localization_test.dart' show localized;
import 'local_help_screen_test.dart' show tap, reveal, firstProviderAction;
import 'referral_task_import_test.dart' show source;
import 'referral_test_support.dart';

class _ClosedDirectory implements ReferralDirectory {
  const _ClosedDirectory();
  @override
  List<ReferralProvider> get providers => [
    officialReferrals.first,
    officialReferrals[1],
    const ReferralProvider(
      id: 'closed-referral',
      stateCodes: ['CA'],
      name: 'Fictional closed organization',
      description: 'Ask about local home repair and community services.',
      website: 'https://example.org',
      sources: ['https://example.org'],
      counties: ['San Mateo'],
      reviewedOn: '2026-10-24',
      reviewAfter: '2026-11-23',
      availability: ReferralAvailability.closed,
    ),
  ];
  @override
  ReferralProvider? provider(String id) =>
      providers.where((p) => p.id == id).firstOrNull;
}

void main() {
  testWidgets(
    'provider opens existing shared next steps and new tasks retain the referral without creating a benefit program',
    (tester) async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      await tester.pumpWidget(
        localized(const Locale('en'), LocalHelpScreen(services: h.app)),
      );
      await tester.pumpAndSettle();
      await tap(tester, firstProviderAction('Add follow-up'));
      expect(find.byType(ProgramProgressScreen), findsOneWidget);
      expect(h.server.tasks, isEmpty);
      await reveal(tester, find.byKey(const ValueKey('task-quick-add')));
      await tester.enterText(
        find.byKey(const ValueKey('task-quick-add')),
        'Fictional call for repair referrals',
      );
      await tap(tester, find.byKey(const ValueKey('task-quick-add-button')));
      expect(h.server.tasks.length, 1);
      final task = h.server.tasks.values.single;
      expect((task['referral'] as Map)['providerId'], 'referral-211-national');
      expect(task['programId'], isNull);
      expect(task['kind'], 'follow_up');
      expect(task['title'], 'Fictional call for repair referrals');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tap(tester, firstProviderAction('Add follow-up'));
      await reveal(tester, find.text('Fictional call for repair referrals'));
      expect(h.server.tasks.length, 1);
      expect(find.text('Fictional call for repair referrals'), findsOneWidget);
      expect(h.device.requests, 0);
    },
  );

  testWidgets(
    'cancel leaves original intact; explicit import confirms dates and offers opt-in reminders in shared tasks',
    (tester) async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final local = LocalHelpRepository(h.app.coordinator),
          original = source('one');
      await local.saveTask(original);
      await tester.pumpWidget(
        localized(const Locale('en'), LocalHelpScreen(services: h.app)),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.text('Import local follow-up'));
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.server.tasks, isEmpty);
      expect((await local.load()).tasks.single.toJson(), original.toJson());
      await tap(tester, find.text('Import local follow-up'));
      await tester.tap(find.text('Import follow-up'));
      await tester.pumpAndSettle();
      expect(h.server.tasks.length, 1);
      expect(h.server.tasks.values.single['dueOn'], isNull);
      expect(h.device.requests, 0);
      await tap(tester, find.text('Open My next steps'));
      await reveal(tester, find.text(original.title));
      expect(find.text(original.title), findsOneWidget);
      await tap(tester, find.text(original.title));
      expect(find.byType(TaskEditorScreen), findsOneWidget);
      await reveal(tester, find.text('Original local follow-up'));
      await tap(tester, find.text('Device reminder'));
      await tap(tester, find.byKey(const ValueKey('reminder-date')));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      h.device.permission = false;
      await tester.tap(find.text('Enable reminder'));
      await tester.pumpAndSettle();
      expect(h.device.requests, 1);
      expect(h.server.tasks.length, 1);
      expect(h.device.scheduled, isEmpty);
      final reminder = h.app.progress!.reminders.forTask(
        h.app.coordinator.currentCase().caseId,
        h.server.tasks.keys.single,
      )!;
      expect(reminder.enabled, isTrue);
      expect(reminder.data['date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(reminder.data['time'], matches(RegExp(r'^\d{2}:\d{2}$')));
      expect(h.server.tasks.values.single['dueOn'], isNull);
    },
  );

  testWidgets(
    'stale closed regional listing keeps contact-to-confirm and national locators available',
    (tester) async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final local = LocalHelpRepository(h.app.coordinator);
      await local.confirmLocation(
        HelpLocation(stateCode: 'CA', city: '', county: 'San Mateo', zip: null),
      );
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          LocalHelpScreen(
            services: h.app,
            directory: const _ClosedDirectory(),
            now: () => DateTime(2027),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Intake closed: ask about alternatives.'));
      expect(
        find.text('Listing needs review. Contact to confirm.'),
        findsWidgets,
      );
      await reveal(tester, find.text('Coverage unknown: contact to confirm.'));
      await reveal(tester, find.text('Find my local 211'));
      await reveal(
        tester,
        find.ancestor(
          of: find.text('Find a Rebuilding Together affiliate'),
          matching: find.bySubtype<ButtonStyleButton>(),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
