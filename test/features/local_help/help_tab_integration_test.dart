import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/local_help_screen.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/features/tracking/task_editor_screen.dart';

import '../../app/core_localization_test.dart' show localized;
import 'local_help_screen_test.dart' show make, tap, reveal;
import 'referral_test_support.dart';

const _provider = 'provider-habitat-east-bay-silicon-valley';
const _organization = 'Habitat for Humanity East Bay/Silicon Valley';

Future<void> _tab(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('plan-tab-$name')));
  await tester.pumpAndSettle();
}

Future<void> _openHelp(WidgetTester tester) async {
  await _tab(tester, 'help');
  await tap(tester, find.byKey(const ValueKey('case-local-help')));
  expect(find.byType(LocalHelpScreen), findsOneWidget);
}

Future<void> _findProvider(WidgetTester tester) async {
  final query = find.byKey(const ValueKey('provider-search-query'));
  await reveal(tester, query);
  await tester.enterText(query, 'East Bay');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
  await reveal(tester, find.byKey(const ValueKey(_provider)));
}

Finder _providerAction(String label) => find.descendant(
  of: find.byKey(const ValueKey(_provider)),
  matching: find.text(label),
);

Future<void> _saveNote(WidgetTester tester, String note) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Contact note (optional)'),
    note,
  );
  await tester.tap(find.text('Save on this device'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Help directory contacts and shared follow-ups reach Tasks and survive offline restart',
    (tester) async {
      var h = await ReferralHarness.create();
      addTearDown(() => h.dispose());
      await tester.pumpWidget(
        localized(const Locale('en'), CaseWorkspaceScreen(services: h.app)),
      );
      await tester.pumpAndSettle();
      await _openHelp(tester);
      await _findProvider(tester);
      await tap(tester, _providerAction('Save · on this phone'));
      const privateNote = 'Fictional private contact note';
      await _saveNote(tester, privateNote);
      expect(
        (await LocalHelpRepository(
          h.app.coordinator,
        ).load()).contacts.single.providerId,
        _provider,
      );

      await tap(tester, _providerAction('Add follow-up'));
      expect(find.byType(ProgramProgressScreen), findsOneWidget);
      expect(h.server.tasks, isEmpty);
      await reveal(tester, find.byKey(const ValueKey('task-quick-add')));
      await tester.enterText(
        find.byKey(const ValueKey('task-quick-add')),
        'Fictional call about repairs',
      );
      await tap(tester, find.byKey(const ValueKey('task-quick-add-button')));
      final taskId = h.server.tasks.keys.single;
      expect(h.server.tasks[taskId]!['kind'], 'follow_up');
      expect(
        (h.server.tasks[taskId]!['referral'] as Map)['providerId'],
        _provider,
      );
      expect(h.server.tasks[taskId]!['programId'], isNull);
      expect(jsonEncode(h.server.tasks), isNot(contains(privateNote)));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tap(tester, find.text('Programs for this plan'));
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      await _tab(tester, 'tasks');
      await reveal(tester, find.text('Fictional call about repairs'));
      await reveal(tester, find.text('Referral: $_organization'));
      await tap(tester, find.text('Fictional call about repairs'));
      expect(find.byType(TaskEditorScreen), findsOneWidget);
      const edited = 'Fictional ask about address coverage';
      await tester.enterText(
        find.widgetWithText(TextFormField, 'What needs doing?'),
        edited,
      );
      await reveal(
        tester,
        find.widgetWithText(TextFormField, 'For (optional note)'),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'For (optional note)'),
        'Fictional resident',
      );
      await tap(tester, find.text('Save task'));
      expect(h.server.tasks.keys.single, taskId);
      expect(
        (h.server.tasks[taskId]!['referral'] as Map)['providerId'],
        _provider,
      );
      expect(h.server.tasks[taskId]!['title'], edited);
      expect(
        h.server.tasks[taskId]!['responsiblePerson'],
        'Fictional resident',
      );
      await tap(tester, find.byKey(ValueKey('task-done-$taskId')));
      expect(h.server.tasks[taskId]!['state'], 'completed');
      expect(h.device.requests, 0);
      expect(h.device.scheduled, isEmpty);

      final store = h.store, server = h.server;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      h.dispose();
      h = await ReferralHarness.create(store: store, server: server);
      server.offline = true;
      await tester.pumpWidget(
        localized(const Locale('en'), CaseWorkspaceScreen(services: h.app)),
      );
      await tester.pumpAndSettle();
      await _openHelp(tester);
      await reveal(tester, find.text(privateNote));
      await tap(tester, find.text('Edit contact note'));
      const offlineNote = 'Fictional note edited offline';
      await _saveNote(tester, offlineNote);
      await reveal(tester, find.text(offlineNote));
      final savedCard = find.ancestor(
        of: find.text(offlineNote),
        matching: find.byType(Card),
      );
      await tap(
        tester,
        find.descendant(of: savedCard, matching: find.text('Add follow-up')),
      );
      await tap(tester, find.text('Done (1)'));
      await reveal(tester, find.text(edited));
      expect(
        tester.widget<ListTile>(find.byKey(ValueKey('task-$taskId'))).onTap,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(find.byKey(ValueKey('task-done-$taskId')))
            .onChanged,
        isNull,
      );
      expect(server.tasks.keys.single, taskId);
      expect(server.tasks[taskId]!['state'], 'completed');
      expect(jsonEncode(server.tasks), isNot(contains(offlineNote)));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tap(tester, find.text('Programs for this plan'));
      await _tab(tester, 'tasks');
      await tap(tester, find.text('Done (1)'));
      await reveal(tester, find.text(edited));
      await _tab(tester, 'help');
      await tap(tester, find.byKey(const ValueKey('case-local-help')));
      await reveal(tester, find.text(offlineNote));
      await h.app.coordinator.clearSelected();
      await tester.pumpAndSettle();
      expect(find.text('This case is no longer selected.'), findsOneWidget);
      expect(find.text(offlineNote), findsNothing);
      expect(h.device.requests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsynced Help keeps contacts usable while follow-up tracking is unavailable',
    (tester) async {
      final app = await make();
      await tester.pumpWidget(
        localized(const Locale('en'), CaseWorkspaceScreen(services: app)),
      );
      await tester.pumpAndSettle();
      await _openHelp(tester);
      await _findProvider(tester);
      await tap(tester, _providerAction('Save · on this phone'));
      const note = 'Fictional unsynced contact';
      await _saveNote(tester, note);
      await tap(tester, _providerAction('Add follow-up'));
      await reveal(
        tester,
        find.text(
          'Save this plan online and enable My next steps to manage referral tasks. Saved local follow-ups are kept.',
        ),
      );
      expect(find.byType(ProgramProgressScreen), findsNothing);
      expect(
        (await LocalHelpRepository(
          app.coordinator,
        ).load()).contacts.single.note,
        note,
      );
      await tap(tester, find.text('Programs for this plan'));
      await _tab(tester, 'plan');
      await _openHelp(tester);
      await reveal(tester, find.text(note));
      expect(tester.takeException(), isNull);
    },
  );
}
