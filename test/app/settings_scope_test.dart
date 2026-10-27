import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;
import '../services/case_evidence_api_client_test.dart' as http;
import '../case_discovery_api_client_test.dart' show apiError;

void main() {
  late MemoryPrivateStore store;
  late FakeTransport transport;
  late AppServices app;
  Completer<void>? pendingRead;

  void initialize() {
    pendingRead = null;
    store = MemoryPrivateStore();
    transport = FakeTransport((request) async {
      final body = http.requestJson(request);
      switch (request.endpoint.path) {
        case '/v1/create-case':
          return http.jsonResponse({...body, 'revision': 1});
        case '/v1/list-evidence':
          return http.jsonResponse({
            'schemaVersion': '1',
            'caseId': body['caseId'],
            'caseRevision': body['expectedCaseRevision'],
            'catalogRevision': 0,
            'evidence': <Object>[],
          });
        case '/v1/delete-case':
          return http.jsonResponse({
            'schemaVersion': '1',
            'caseId': body['caseId'],
            'deleted': true,
          });
        case '/v1/read-case':
          await pendingRead?.future;
          return apiError('CASE_NOT_FOUND', 404);
        default:
          throw StateError('Unexpected settings request');
      }
    });
    app = services(store, transport);
  }

  tearDown(() {
    app.dispose();
    app.session.dispose();
  });

  Future<(String, String)> twoCases({bool saved = true}) async {
    await app.coordinator.createDraft();
    if (saved) await app.coordinator.save();
    final first = app.coordinator.draft!.caseId;
    await app.coordinator.createDraft();
    if (saved) await app.coordinator.save();
    final second = app.coordinator.draft!.caseId;
    await app.coordinator.restoreLocal(first);
    return (first, second);
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: AccountSettingsScreen(services: app),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('account-privacy')));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('case confirmation never carries over to another selected case', (
    tester,
  ) async {
    initialize();
    final (original, other) = await twoCases();
    await open(tester);
    await tap(tester, 'Delete this plan');
    await app.coordinator.restoreLocal(other);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(app.coordinator.snapshot!.caseId, other);
    expect(store.records.containsKey('case.$original'), true);
    expect(store.records.containsKey('case.$other'), true);
    expect(
      transport.requests.where((r) => r.endpoint.path == '/v1/delete-case'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local removal confirmation remains bound to its original draft',
    (tester) async {
      initialize();
      final (original, other) = await twoCases(saved: false);
      await open(tester);
      await tap(tester, 'Remove selected local draft');
      await app.coordinator.restoreLocal(other);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(app.coordinator.draft!.caseId, other);
      expect(store.records.containsKey('case.$original'), true);
      expect(store.records.containsKey('case.$other'), true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sign-out confirmation cannot sign out a replacement account', (
    tester,
  ) async {
    initialize();
    await open(tester);
    await tap(tester, 'Sign out and clear local data');
    final session = app.session as FakeSession;
    session.owner = 'another-fictional-owner';
    session.generation++;
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(session.userId, 'another-fictional-owner');
    expect(transport.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late missing-case result cannot clear a different draft', (
    tester,
  ) async {
    initialize();
    final (original, other) = await twoCases();
    store.records['case-delete.$original'] = {'pending': true};
    pendingRead = Completer<void>();
    await open(tester);
    await tester.scrollUntilVisible(
      find.text('Check whether plan deletion finished'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Check whether plan deletion finished'));
    await tester.pump();
    expect(transport.requests.last.endpoint.path, '/v1/read-case');
    await app.coordinator.restoreLocal(other);
    pendingRead!.complete();
    await tester.pumpAndSettle();
    expect(app.coordinator.snapshot!.caseId, other);
    expect(store.records.containsKey('case.$other'), true);
    expect(store.records.containsKey('case-delete.$original'), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed current case deletion still clears only that case', (
    tester,
  ) async {
    initialize();
    final (original, other) = await twoCases();
    await open(tester);
    await tap(tester, 'Delete this plan');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    final deletions = transport.requests
        .where((r) => r.endpoint.path == '/v1/delete-case')
        .toList();
    expect(deletions, hasLength(1));
    expect(http.requestJson(deletions.single)['caseId'], original);
    expect(app.coordinator.draft, isNull);
    expect(store.records.containsKey('case.$original'), false);
    expect(store.records.containsKey('case.$other'), true);
    expect(find.text('Plan deleted.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
