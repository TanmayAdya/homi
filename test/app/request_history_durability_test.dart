import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/request_history_screen.dart';
import 'package:safe_at_home/shared/models/request_tracking.dart';

import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, program;
import '../request_tracking_test.dart' as fixture;
import '../services/case_evidence_api_client_test.dart' as http;

class _InterruptedHistoryStore extends MemoryPrivateStore {
  bool failEditorWrite = false,
      holdEditorWrite = false,
      holdPendingDelete = false;
  final entered = Completer<void>(), release = Completer<void>();
  final deletedKeys = <String>[];

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('history-edit.')) {
      if (failEditorWrite) throw StateError('Fictional device write failure');
      if (holdEditorWrite && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    }
    await super.writeJson(key, value);
  }

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
    if (holdPendingDelete &&
        key.startsWith('history.') &&
        !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.delete(key);
  }
}

const _note = 'Fictional pending conversation that has no editable copy yet';
const _editor = <String, Object?>{
  'date': '2026-10-17',
  'note': _note,
  'action': 'Call fictional program',
  'follow': '2026-10-25',
  'status': 'needs_information',
  'source': 'program_contact',
  'party': 'caregiver',
};

Future<
  ({
    AppServices app,
    FakeTransport transport,
    String pendingKey,
    String editKey,
    Map<String, Object?> pending,
  })
>
_open(WidgetTester tester, _InterruptedHistoryStore store) async {
  final transport = FakeTransport((request) async {
    final body = http.requestJson(request);
    if (request.endpoint.path == '/v1/create-case') {
      return http.jsonResponse({...body, 'revision': 1});
    }
    expect(request.endpoint.path, '/v1/read-request-history');
    return http.jsonResponse({
      ...fixture.historyJson(count: 1, caseRevision: 1),
      'caseId': body['caseId'],
      'programId': 'fictional-program',
    });
  });
  final app = services(store, transport);
  addTearDown(app.dispose);
  await app.coordinator.createDraft();
  await app.coordinator.save();
  final id = app.coordinator.snapshot!.caseId;
  final pendingKey = 'history.$id.fictional-program';
  final editKey = 'history-edit.$id.fictional-program';
  final pending = PendingRequestUpdate(
    request: ReadRequestHistoryRequest(
      caseId: id,
      expectedCaseRevision: 1,
      programId: 'fictional-program',
    ),
    expectedRequestRevision: 0,
    update: RequestUpdate.fromJson({
      ...fixture.updateJson(number: 9, status: 'needs_information'),
      'note': _note,
      'source': 'program_contact',
      'nextAction': 'Call fictional program',
      'responsibleParty': 'caregiver',
      'followUpOn': '2026-10-25',
    }),
  ).toJson();
  await store.writeJson(pendingKey, pending);
  await tester.pumpWidget(
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: RequestHistoryScreen(services: app, program: program()),
    ),
  );
  await tester.pumpAndSettle();
  return (
    app: app,
    transport: transport,
    pendingKey: pendingKey,
    editKey: editKey,
    pending: pending,
  );
}

Future<void> _returnToEditor(WidgetTester tester) async {
  final action = find.text('Review against changed history and edit');
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Return to editor'));
  await tester.pump();
}

void _noAppend(FakeTransport transport) => expect(
  transport.requests.where(
    (r) => r.endpoint.path == '/v1/append-request-update',
  ),
  isEmpty,
);

void main() {
  testWidgets(
    'failed editable copy keeps the exact pending history for retry',
    (tester) async {
      final store = _InterruptedHistoryStore();
      final f = await _open(tester, store);
      store.failEditorWrite = true;
      await _returnToEditor(tester);
      await tester.pumpAndSettle();
      expect(store.records[f.pendingKey], f.pending);
      expect(store.records[f.editKey], isNull);
      expect(store.deletedKeys, isEmpty);
      expect(find.text('Pending update'), findsOneWidget);
      _noAppend(f.transport);

      store.failEditorWrite = false;
      await _returnToEditor(tester);
      await tester.pumpAndSettle();
      expect(store.records[f.pendingKey], isNull);
      expect(store.records[f.editKey], _editor);
      expect(find.text('Pending update'), findsNothing);
      expect(find.byKey(const ValueKey('history-editor')), findsOneWidget);
      expect(find.text('Add update'), findsOneWidget);
      _noAppend(f.transport);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editor is already durable when pending deletion begins, including after disposal',
    (tester) async {
      final store = _InterruptedHistoryStore();
      final f = await _open(tester, store);
      store.holdPendingDelete = true;
      await _returnToEditor(tester);
      expect(store.entered.isCompleted, isTrue);
      expect(store.records[f.editKey], _editor);
      expect(store.records[f.pendingKey], f.pending);
      await tester.pumpWidget(const MaterialApp(home: Text('Another screen')));
      store.release.complete();
      await tester.pumpAndSettle();
      expect(store.records[f.editKey], _editor);
      expect(store.records[f.pendingKey], isNull);
      _noAppend(f.transport);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a case switch during editable-copy persistence preserves the pending journal',
    (tester) async {
      final store = _InterruptedHistoryStore();
      final f = await _open(tester, store);
      store.holdEditorWrite = true;
      await _returnToEditor(tester);
      expect(store.entered.isCompleted, isTrue);
      expect(store.records[f.pendingKey], f.pending);
      await f.app.coordinator.createDraft();
      await f.app.coordinator.save();
      final otherKey =
          'history-edit.${f.app.coordinator.snapshot!.caseId}.fictional-program';
      await store.writeJson(otherKey, {'note': 'Other case untouched'});
      store.release.complete();
      await tester.pumpAndSettle();
      expect(store.records[f.pendingKey], f.pending);
      expect(store.records[f.editKey], _editor);
      expect(store.records[otherKey], {'note': 'Other case untouched'});
      expect(store.deletedKeys, isEmpty);
      _noAppend(f.transport);
      expect(tester.takeException(), isNull);
    },
  );
}
