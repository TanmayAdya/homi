import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'app_design_test.dart' show reveal;
import 'case_coordinator_test.dart' show FakeTransport;
import 'profile_recovery_test.dart' show ProfileTestStore, appFor, cityField;

class ExitProfileStore extends ProfileTestStore {
  bool holdCase = false;
  bool holdCompletedCase = false;
  final caseEntered = Completer<void>(), caseRelease = Completer<void>();
  final journalAttempts = <Map<String, Object?>>[];

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('profile-edit.')) {
      journalAttempts.add(
        Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map),
      );
    }
    if (key.startsWith('case.') && holdCase && !caseEntered.isCompleted) {
      caseEntered.complete();
      await caseRelease.future;
    }
    await super.writeJson(key, value);
    if (key.startsWith('case.') &&
        holdCompletedCase &&
        !caseEntered.isCompleted) {
      caseEntered.complete();
      await caseRelease.future;
    }
  }
}

Future<void> openProfile(WidgetTester tester, AppServices app) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ProfileEditorScreen(services: app),
              ),
            ),
            child: const Text('Open profile'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open profile'));
  await tester.pumpAndSettle();
}

Future<void> editCity(WidgetTester tester, String text) async {
  await reveal(tester, cityField());
  await tester.enterText(cityField(), text);
  await tester.pump();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void expectNoHttp(AppServices app) =>
    expect((app.transport as FakeTransport).requests, isEmpty);

CaseDraft withLaterFinding(AppServices app) => CaseDraft.fromJson({
  ...app.coordinator.currentDraft().toJson(),
  'findings': [
    {
      'id': 'later-fictional-finding',
      'room': 'entrance',
      'observation': 'A fictional observation added after the profile save.',
      'reviewState': 'needs_review',
      'evidenceIds': <String>[],
      'measurements': <Map<String, Object?>>[],
    },
  ],
});

void main() {
  testWidgets(
    'profile save retry cannot overwrite a newer same-scope finding',
    (tester) async {
      final store = ExitProfileStore();
      final app = await appFor(store);
      final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
      await openProfile(tester, app);
      await editCity(tester, '  Pending fictional city  ');
      final journal = jsonEncode(store.records[key]);
      store.failCase = true;
      await reveal(tester, find.byKey(const ValueKey('profile-keep-edits')));
      await tapKey(tester, 'profile-keep-edits');
      expect(app.coordinator.localSaveFailed, true);
      final generation = app.coordinator.generation;
      store.failCase = false;
      final newer = withLaterFinding(app);
      await app.coordinator.updateDraft(newer);
      expect(app.coordinator.generation, generation);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tapKey(tester, 'draft-exit-retry');
      expect(find.byKey(const ValueKey('draft-exit-retry')), findsOneWidget);
      expect(app.coordinator.currentDraft().toJson(), newer.toJson());
      expect(jsonEncode(store.records[key]), journal);
      await tapKey(tester, 'draft-exit-keep-editing');
      expect(
        find.textContaining('The case changed while these edits'),
        findsOneWidget,
      );
      expectNoHttp(app);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late profile case save cannot remove a journal after findings change',
    (tester) async {
      final store = ExitProfileStore();
      final app = await appFor(store);
      final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
      await openProfile(tester, app);
      await editCity(tester, 'Held completed fictional city');
      final journal = jsonEncode(store.records[key]);
      final action = find.byKey(const ValueKey('profile-keep-edits'));
      await reveal(tester, action);
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      store.holdCompletedCase = true;
      await tester.tap(action);
      await tester.pump();
      expect(store.caseEntered.isCompleted, true);
      final generation = app.coordinator.generation;
      final newer = withLaterFinding(app);
      await app.coordinator.updateDraft(newer);
      expect(app.coordinator.generation, generation);
      store.caseRelease.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      expect(
        find.textContaining('The case changed while these edits'),
        findsOneWidget,
      );
      expect(app.coordinator.currentDraft().toJson(), newer.toJson());
      expect(jsonEncode(store.records[key]), journal);
      expectNoHttp(app);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed profile journal blocks Back and retries exact input', (
    tester,
  ) async {
    final store = ExitProfileStore();
    final app = await appFor(store);
    final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
    await openProfile(tester, app);
    store.failWrite = true;
    await editCity(tester, '  Fictional incomplete city  ');
    final expected = store.journalAttempts.single;
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditorScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('draft-exit-retry')), findsOneWidget);
    expect(store.records[key], isNull);
    store.failWrite = false;
    await tapKey(tester, 'draft-exit-retry');
    expect(find.byType(ProfileEditorScreen), findsNothing);
    expect(store.journalAttempts, [expected, expected]);
    expect(store.records[key], expected);
    expect(app.coordinator.currentDraft().profile.city, isNull);
    expectNoHttp(app);
    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(cityField()).controller!.text,
      '  Fictional incomplete city  ',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('system Back waits for a held profile journal before leaving', (
    tester,
  ) async {
    final store = ExitProfileStore();
    final app = await appFor(store);
    final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
    await openProfile(tester, app);
    store.blockWrite = true;
    await editCity(tester, 'Held fictional city');
    expect(store.entered.isCompleted, true);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('draft-exit-waiting')), findsOneWidget);
    expect(find.byType(ProfileEditorScreen), findsOneWidget);
    expect(store.records[key], isNull);
    store.release.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditorScreen), findsNothing);
    expect(
      (store.records[key]!['values'] as Map)['city'],
      'Held fictional city',
    );
    expectNoHttp(app);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'discard requires confirmation and retains prior profile journal',
    (tester) async {
      final store = ExitProfileStore();
      final app = await appFor(store);
      final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
      await openProfile(tester, app);
      await editCity(tester, 'Earlier fictional city');
      final earlier = jsonEncode(store.records[key]);
      store.failWrite = true;
      await editCity(tester, 'Latest unsaved fictional city');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tapKey(tester, 'draft-exit-keep-editing');
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      expect(
        tester.widget<TextFormField>(cityField()).controller!.text,
        'Latest unsaved fictional city',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tapKey(tester, 'draft-exit-discard');
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      expect(find.text('Leave this editor?'), findsOneWidget);
      expect(jsonEncode(store.records[key]), earlier);
      await tapKey(tester, 'draft-exit-confirm-discard');
      expect(find.byType(ProfileEditorScreen), findsNothing);
      expect(jsonEncode(store.records[key]), earlier);
      expect(app.coordinator.currentDraft().profile.city, isNull);
      expectNoHttp(app);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('successful Keep edits settles an earlier failed journal', (
    tester,
  ) async {
    final store = ExitProfileStore();
    final app = await appFor(store);
    final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
    await openProfile(tester, app);
    store.failWrite = true;
    await editCity(tester, '  Kept fictional city  ');
    store.failWrite = false;
    final action = find.byKey(const ValueKey('profile-keep-edits'));
    await reveal(tester, action);
    await tapKey(tester, 'profile-keep-edits');
    expect(find.byType(ProfileEditorScreen), findsNothing);
    expect(app.coordinator.currentDraft().profile.city, 'Kept fictional city');
    expect(store.records[key], isNull);
    expect(store.journalAttempts, hasLength(1));
    expectNoHttp(app);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back during Keep edits waits for case durability and cleanup', (
    tester,
  ) async {
    final store = ExitProfileStore();
    final app = await appFor(store);
    final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
    await openProfile(tester, app);
    await editCity(tester, 'Held case fictional city');
    final action = find.byKey(const ValueKey('profile-keep-edits'));
    await reveal(tester, action);
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    store.holdCase = true;
    await tester.tap(action);
    await tester.pump();
    expect(store.caseEntered.isCompleted, true);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('draft-exit-waiting')), findsOneWidget);
    expect(store.records[key], isNotNull);
    store.caseRelease.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditorScreen), findsNothing);
    expect(store.records[key], isNull);
    expect(app.coordinator.localSaveFailed, false);
    expectNoHttp(app);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed journal cleanup retries cleanup without resurrecting edits',
    (tester) async {
      final store = ExitProfileStore();
      final app = await appFor(store);
      final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
      await openProfile(tester, app);
      await editCity(tester, 'Cleanup fictional city');
      store.failDelete = true;
      final action = find.byKey(const ValueKey('profile-keep-edits'));
      await reveal(tester, action);
      await tapKey(tester, 'profile-keep-edits');
      expect(store.records[key], isNotNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-exit-retry')), findsOneWidget);
      store.failDelete = false;
      await tapKey(tester, 'draft-exit-retry');
      expect(find.byType(ProfileEditorScreen), findsNothing);
      expect(store.records[key], isNull);
      expect(store.journalAttempts, hasLength(1));
      expect(
        app.coordinator.currentDraft().profile.city,
        'Cleanup fictional city',
      );
      expectNoHttp(app);
      expect(tester.takeException(), isNull);
    },
  );
}
