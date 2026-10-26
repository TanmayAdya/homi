import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;
import 'profile_exit_durability_test.dart' show openProfile, editCity;
import 'profile_recovery_test.dart' show ProfileTestStore, cityField;
import '../services/case_evidence_api_client_test.dart' as http;

class ProfileServer {
  Map<String, Object?>? saved;
  bool loseResponse = false, rejectRequest = false;
  Completer<void>? hold;
  late final transport = FakeTransport((request) async {
    final input = http.requestJson(request);
    if (rejectRequest) return http.apiError('RATE_LIMITED', 429);
    if (request.endpoint.path == '/v1/read-case') {
      return http.jsonResponse(saved);
    }
    final revision = (input.remove('expectedCaseRevision') as int? ?? 0) + 1;
    saved = {...input, 'revision': revision};
    final waiting = hold;
    hold = null;
    if (waiting != null) await waiting.future;
    if (loseResponse) {
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    return http.jsonResponse(saved);
  });
}

Future<AppServices> makeApp(ProfileServer server) async {
  final app = services(MemoryPrivateStore(), server.transport);
  addTearDown(app.dispose);
  await app.coordinator.createDraft();
  return app;
}

Future<void> settleAutosave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('typing saves automatically without closing the profile', (
    tester,
  ) async {
    final server = ProfileServer();
    final app = await makeApp(server);
    await openProfile(tester, app);
    await editCity(tester, 'Fictional c');
    await tester.pump(const Duration(milliseconds: 300));
    await editCity(tester, 'Fictional city');
    expect(server.transport.requests, isEmpty);
    await settleAutosave(tester);
    expect(app.coordinator.currentDraft().profile.city, 'Fictional city');
    expect(app.coordinator.currentCase().profile.city, 'Fictional city');
    expect(server.transport.requests, hasLength(1));
    expect(find.byType(ProfileEditorScreen), findsOneWidget);
    expect(tester.widget<TextFormField>(cityField()).enabled, true);
    expect(find.text('Saved online'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening unchanged details makes no new server write', (
    tester,
  ) async {
    final server = ProfileServer();
    final app = await makeApp(server);
    await openProfile(tester, app);
    await editCity(tester, 'Fictional city');
    await settleAutosave(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    await settleAutosave(tester);
    expect(server.transport.requests, hasLength(1));
    expect(app.coordinator.currentCase().revision, 1);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(server.transport.requests, hasLength(1));
  });

  for (final systemBack in [false, true]) {
    testWidgets(
      'immediate ${systemBack ? 'system ' : ''}Back flushes valid edits',
      (tester) async {
        final server = ProfileServer();
        final app = await makeApp(server);
        await openProfile(tester, app);
        await editCity(tester, 'Fast fictional city');
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(BackButton));
        }
        await tester.pumpAndSettle();
        expect(find.byType(ProfileEditorScreen), findsNothing);
        expect(
          app.coordinator.currentDraft().profile.city,
          'Fast fictional city',
        );
        expect(
          app.coordinator.currentCase().profile.city,
          'Fast fictional city',
        );
        expect(server.transport.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Back never waits for a network reply and newer edits sync next',
    (tester) async {
      final server = ProfileServer();
      final app = await makeApp(server);
      final held = Completer<void>();
      server.hold = held;
      await openProfile(tester, app);
      await editCity(tester, 'First fictional city');
      await settleAutosave(tester);
      expect(app.coordinator.busy, true);
      expect(tester.widget<TextFormField>(cityField()).enabled, true);
      await editCity(tester, 'Later fictional city');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditorScreen), findsNothing);
      expect(
        app.coordinator.currentDraft().profile.city,
        'Later fictional city',
      );
      expect(server.transport.requests, hasLength(1));
      held.complete();
      await tester.pumpAndSettle();
      expect(server.transport.requests, hasLength(2));
      expect(app.coordinator.currentCase().revision, 2);
      expect(
        app.coordinator.currentCase().profile.city,
        'Later fictional city',
      );
      expect(app.coordinator.uncertain, false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid input stays local and never becomes an unknown online', (
    tester,
  ) async {
    final server = ProfileServer();
    final app = await makeApp(server);
    await openProfile(tester, app);
    final age = find.widgetWithText(TextFormField, 'Age in years');
    await tester.ensureVisible(age);
    await tester.enterText(age, '-');
    await settleAutosave(tester);
    expect(server.transport.requests, isEmpty);
    expect(app.coordinator.currentDraft().profile.ageYears, isNull);
    final store = app.store as MemoryPrivateStore;
    final journal =
        store.records['profile-edit.${app.coordinator.currentDraft().caseId}']!;
    expect((journal['values'] as Map)['ageYears'], '-');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditorScreen), findsNothing);
    expect(server.transport.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lost response preserves local edits and does not auto retry', (
    tester,
  ) async {
    final server = ProfileServer()..loseResponse = true;
    final app = await makeApp(server);
    await openProfile(tester, app);
    await editCity(tester, 'Offline fictional city');
    await settleAutosave(tester);
    expect(app.coordinator.uncertain, true);
    expect(
      app.coordinator.currentDraft().profile.city,
      'Offline fictional city',
    );
    await editCity(tester, 'Later offline city');
    await settleAutosave(tester);
    expect(app.coordinator.currentDraft().profile.city, 'Later offline city');
    expect(server.transport.requests, hasLength(1));
    expect(
      find.text('Saved on this device · check saved state from your case.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejected online save can be retried without editing again', (
    tester,
  ) async {
    final server = ProfileServer()..rejectRequest = true;
    final app = await makeApp(server);
    await openProfile(tester, app);
    await editCity(tester, 'Retry fictional city');
    await settleAutosave(tester);
    expect(app.coordinator.uncertain, false);
    expect(app.coordinator.currentDraft().profile.city, 'Retry fictional city');
    expect(server.transport.requests, hasLength(1));
    server.rejectRequest = false;
    final retry = find.byKey(const ValueKey('profile-retry-online'));
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(server.transport.requests, hasLength(2));
    expect(app.coordinator.currentCase().profile.city, 'Retry fictional city');
    expect(find.byType(ProfileEditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed device acknowledgment keeps the known server revision editable',
    (tester) async {
      final server = ProfileServer();
      final store = ProfileTestStore();
      final app = services(store, server.transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      final held = Completer<void>();
      server.hold = held;
      await openProfile(tester, app);
      await editCity(tester, 'Acknowledged fictional city');
      await settleAutosave(tester);
      store.failCase = true;
      held.complete();
      await tester.pumpAndSettle();
      expect(app.coordinator.currentCase().revision, 1);
      expect(app.coordinator.localSaveFailed, true);
      expect(tester.widget<TextFormField>(cityField()).enabled, true);
      expect(
        find.text('Device save needs attention. Your entries are still here.'),
        findsOneWidget,
      );
      store.failCase = false;
      await editCity(tester, 'Corrected fictional city');
      await settleAutosave(tester);
      expect(app.coordinator.currentCase().revision, 2);
      expect(
        app.coordinator.currentCase().profile.city,
        'Corrected fictional city',
      );
      expect(app.coordinator.localSaveFailed, false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account change cancels a pending automatic profile write', (
    tester,
  ) async {
    final server = ProfileServer();
    final app = await makeApp(server);
    await openProfile(tester, app);
    await editCity(tester, 'Old account city');
    await (app.session as FakeSession).signOut();
    await settleAutosave(tester);
    expect(server.transport.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
