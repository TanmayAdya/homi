import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';

import 'live_workflows_test.dart' show services;
import 'profile_autosave_test.dart' show ProfileServer, makeApp, settleAutosave;
import 'profile_exit_durability_test.dart' show ExitProfileStore, openProfile;
import 'profile_recovery_test.dart' show ProfileTestStore, appFor, showProfile;
import 'profile_suggestions_test.dart' show field, type, choose;

class AcknowledgmentStore extends ProfileTestStore {
  final enteredAck = Completer<void>(), releaseAck = Completer<void>();
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('case.') &&
        value['snapshot'] is Map &&
        !enteredAck.isCompleted) {
      enteredAck.complete();
      await releaseAck.future;
    }
    await super.writeJson(key, value);
  }
}

Future<AppServices> storedApp(
  ProfileTestStore store,
  ProfileServer server,
) async {
  final app = services(store, server.transport);
  addTearDown(app.dispose);
  await app.coordinator.createDraft();
  return app;
}

void expectEditing(WidgetTester tester, String label) {
  final input = tester.widget<TextFormField>(field(label));
  expect(input.enabled, true);
  final editing = tester.widget<TextField>(
    find.descendant(of: field(label), matching: find.byType(TextField)),
  );
  expect(editing.focusNode!.hasFocus, true);
  expect(tester.testTextInput.isVisible, true);
}

void main() {
  testWidgets(
    'scrolling a focused field away hides suggestions and restores them on return',
    (tester) async {
      final app = await appFor(ProfileTestStore());
      await showProfile(tester, app);
      await type(tester, 'City', 'san jo');
      final panel = find.byKey(const ValueKey('profile-suggestions-city'));
      final position = Scrollable.of(tester.element(field('City'))).position;
      final originalOffset = position.pixels;
      expect(panel, findsOneWidget);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expectEditing(tester, 'City');
      expect(
        tester.widget<TextFormField>(field('City')).controller!.text,
        'san jo',
      );
      position.jumpTo(originalOffset);
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expectEditing(tester, 'City');
      await choose(tester, 'city', 'San José');
      expectEditing(tester, 'City');
      expect(
        tester.widget<TextFormField>(field('City')).controller!.text,
        'San José',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('automatic saving keeps the keyboard, focus and field position', (
    tester,
  ) async {
    final server = ProfileServer();
    final app = await makeApp(server);
    await openProfile(tester, app);
    await type(tester, 'City', 'Fictional city');
    expectEditing(tester, 'City');
    final before = tester.getTopLeft(field('City'));
    await settleAutosave(tester);
    expectEditing(tester, 'City');
    expect(tester.getTopLeft(field('City')), before);
    expect(app.coordinator.currentCase().profile.city, 'Fictional city');
    await tester.enterText(field('City'), 'Fictional city continued');
    await settleAutosave(tester);
    expectEditing(tester, 'City');
    expect(
      app.coordinator.currentCase().profile.city,
      'Fictional city continued',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'typing and Back during a device save preserve the newer journal',
    (tester) async {
      final store = ExitProfileStore();
      final server = ProfileServer();
      final app = await storedApp(store, server);
      final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
      await openProfile(tester, app);
      store.holdCase = true;
      await type(tester, 'City', 'First fictional city');
      await tester.pump(const Duration(milliseconds: 900));
      expect(store.caseEntered.isCompleted, true);
      expectEditing(tester, 'City');
      await tester.enterText(field('City'), '  Later fictional city  ');
      await tester.pump();
      expectEditing(tester, 'City');
      expect(
        (store.records[key]!['values'] as Map)['city'],
        '  Later fictional city  ',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      store.caseRelease.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditorScreen), findsNothing);
      expect(
        app.coordinator.currentDraft().profile.city,
        'Later fictional city',
      );
      expect(
        app.coordinator.currentCase().profile.city,
        'Later fictional city',
      );
      expect(store.records[key], isNull);
      await tester.tap(find.text('Open profile'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('City')).controller!.text,
        'Later fictional city',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an acknowledged revision waiting on disk never defocuses typing',
    (tester) async {
      final store = AcknowledgmentStore();
      final server = ProfileServer();
      final app = await storedApp(store, server);
      final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
      await openProfile(tester, app);
      await type(tester, 'City', 'Before acknowledgment');
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(store.enteredAck.isCompleted, true);
      expect(app.coordinator.currentCase().revision, 1);
      expectEditing(tester, 'City');
      await tester.enterText(field('City'), '  After acknowledgment  ');
      await tester.pump();
      expect(
        (store.records[key]!['values'] as Map)['city'],
        '  After acknowledgment  ',
      );
      expect(store.records[key]!['baseCaseRevision'], 1);
      store.releaseAck.complete();
      await tester.pumpAndSettle();
      expectEditing(tester, 'City');
      await settleAutosave(tester);
      expectEditing(tester, 'City');
      expect(
        app.coordinator.currentCase().profile.city,
        'After acknowledgment',
      );
      expect(app.coordinator.currentCase().revision, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all suggestion fields retain focus and the editing connection', (
    tester,
  ) async {
    final app = await appFor(ProfileTestStore());
    await showProfile(tester, app);
    for (final entry in [
      ('City', 'city', 'san jo', 'San José'),
      ('County', 'county', 'mateo', 'San Mateo'),
      ('Health plan', 'healthPlan', 'kaiser', 'Kaiser Permanente'),
    ]) {
      await type(tester, entry.$1, entry.$3);
      await choose(tester, entry.$2, entry.$4);
      expectEditing(tester, entry.$1);
      expect(
        tester.widget<TextFormField>(field(entry.$1)).controller!.text,
        entry.$4,
      );
      expect(
        find.byKey(ValueKey('profile-suggestions-${entry.$2}')),
        findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('filtering suggestions does not change the form scroll extent', (
    tester,
  ) async {
    final app = await appFor(ProfileTestStore());
    await showProfile(tester, app);
    await type(tester, 'City', 'san');
    final position = Scrollable.of(tester.element(field('City'))).position;
    final extent = position.maxScrollExtent;
    final origin = tester.getTopLeft(field('City'));
    expect(
      find.byKey(const ValueKey('profile-suggestions-city')),
      findsOneWidget,
    );
    await tester.enterText(field('City'), 'san jo');
    await tester.pumpAndSettle();
    expect(position.maxScrollExtent, extent);
    expect(tester.getTopLeft(field('City')), origin);
    await tester.enterText(field('City'), 'Fictional unlisted city');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('profile-suggestions-city')),
      findsNothing,
    );
    expect(position.maxScrollExtent, extent);
    expect(tester.getTopLeft(field('City')), origin);
    expectEditing(tester, 'City');
    expect(tester.takeException(), isNull);
  });

  testWidgets('suggestions stay above the keyboard without moving the form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    final app = await appFor(ProfileTestStore());
    await showProfile(tester, app);
    await type(tester, 'Health plan', 'kaiser');
    final panel = find.byKey(const ValueKey('profile-suggestions-healthPlan'));
    expect(panel, findsOneWidget);
    expect(tester.getRect(panel).bottom, lessThanOrEqualTo(544));
    await choose(tester, 'healthPlan', 'Kaiser Permanente');
    expectEditing(tester, 'Health plan');
    expect(tester.takeException(), isNull);
  });

  testWidgets('other coverage, no coverage and unknown save distinct answers', (
    tester,
  ) async {
    final server = ProfileServer();
    final app = await makeApp(server);
    await openProfile(tester, app);
    await type(tester, 'Health plan', 'Kaiser');
    await choose(tester, 'healthPlan', 'Kaiser Permanente');
    await settleAutosave(tester);
    expect(
      app.coordinator.currentCase().profile.healthPlan,
      'Kaiser Permanente',
    );
    final hasPlan = find.byKey(const ValueKey('profile-has-health-plan'));
    await tester.ensureVisible(field('Health plan'));
    await tester.tap(field('Health plan'));
    await tester.pump();
    expectEditing(tester, 'Health plan');
    await tester.enterText(field('Health plan'), 'Fictional employer coverage');
    await settleAutosave(tester);
    expect(
      app.coordinator.currentCase().profile.healthPlan,
      'Fictional employer coverage',
    );
    for (final choice in [
      ('profile-no-health-coverage', 'No health coverage'),
      ('profile-unknown-health-coverage', null),
    ]) {
      final button = find.byKey(ValueKey(choice.$1));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await settleAutosave(tester);
      expect(app.coordinator.currentCase().profile.healthPlan, choice.$2);
      expect(field('Health plan'), findsNothing);
    }
    final none = find.byKey(const ValueKey('profile-no-health-coverage'));
    await tester.ensureVisible(none);
    await tester.pumpAndSettle();
    await tester.tap(none);
    await settleAutosave(tester);
    await tester.ensureVisible(hasPlan);
    await tester.pumpAndSettle();
    await tester.tap(hasPlan);
    await tester.pumpAndSettle();
    expectEditing(tester, 'Health plan');
    expect(
      tester.widget<TextFormField>(field('Health plan')).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
