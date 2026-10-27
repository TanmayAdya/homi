import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/request_history_screen.dart';

import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, program;
import '../request_tracking_test.dart' as fixture;
import '../services/case_evidence_api_client_test.dart' as http;

class _EditorStore extends MemoryPrivateStore {
  bool failEdits = false, holdEdits = false;
  int editWrites = 0;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('history-edit.')) {
      editWrites++;
      if (holdEdits && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      if (failEdits) throw StateError('Fictional device write failure');
    }
    await super.writeJson(key, value);
  }
}

Finder get _note => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == 'Optional note',
);

Future<({String key, FakeTransport transport})> _open(
  WidgetTester tester,
  _EditorStore store,
) async {
  final transport = FakeTransport((request) async {
    final body = http.requestJson(request);
    if (request.endpoint.path == '/v1/create-case') {
      return http.jsonResponse({...body, 'revision': 1});
    }
    expect(request.endpoint.path, '/v1/read-request-history');
    return http.jsonResponse({
      ...fixture.historyJson(caseRevision: 1),
      'caseId': body['caseId'],
      'programId': 'fictional-program',
    });
  });
  final app = services(store, transport);
  addTearDown(app.dispose);
  await app.coordinator.createDraft();
  await app.coordinator.save();
  final key =
      'history-edit.${app.coordinator.snapshot!.caseId}.fictional-program';
  await store.writeJson(key, {'date': '2026-10-23', 'note': 'Last saved note'});
  store.editWrites = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    RequestHistoryScreen(services: app, program: program()),
              ),
            ),
            child: const Text('Open history'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open history'));
  await tester.pumpAndSettle();
  expect(tester.widget<TextField>(_note).controller!.text, 'Last saved note');
  return (key: key, transport: transport);
}

Future<void> _edit(WidgetTester tester) async {
  await tester.ensureVisible(_note);
  await tester.enterText(_note, 'Latest fictional conversation');
  await tester.pump();
}

void _noRemoteSave(FakeTransport transport) => expect(
  transport.requests.where(
    (r) => r.endpoint.path == '/v1/append-request-update',
  ),
  isEmpty,
);

void main() {
  testWidgets(
    'Back retains failed history edits and explicit retry persists them before exit',
    (tester) async {
      final store = _EditorStore();
      final f = await _open(tester, store);
      store.failEdits = true;
      await _edit(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-exit-retry')), findsOneWidget);
      expect(store.records[f.key]!['note'], 'Last saved note');
      await tester.tap(find.byKey(const ValueKey('draft-exit-keep-editing')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_note).controller!.text,
        'Latest fictional conversation',
      );
      expect(store.editWrites, 1);
      store.failEdits = false;
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('draft-exit-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Open history'), findsOneWidget);
      expect(store.records[f.key]!['note'], 'Latest fictional conversation');
      await tester.tap(find.text('Open history'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_note).controller!.text,
        'Latest fictional conversation',
      );
      _noRemoteSave(f.transport);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'system Back waits for an accepted history write before leaving',
    (tester) async {
      final store = _EditorStore();
      final f = await _open(tester, store);
      store.holdEdits = true;
      await _edit(tester);
      expect(store.entered.isCompleted, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const ValueKey('draft-exit-waiting')), findsOneWidget);
      expect(store.records[f.key]!['note'], 'Last saved note');
      store.release.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open history'), findsOneWidget);
      expect(store.records[f.key]!['note'], 'Latest fictional conversation');
      _noRemoteSave(f.transport);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late failed history write requires explicit discard and retains the last saved journal',
    (tester) async {
      final store = _EditorStore();
      final f = await _open(tester, store);
      store.holdEdits = true;
      store.failEdits = true;
      await _edit(tester);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(find.byKey(const ValueKey('draft-exit-waiting')), findsOneWidget);
      expect(find.byKey(const ValueKey('draft-exit-discard')), findsNothing);
      store.release.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('draft-exit-discard')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('draft-exit-confirm-discard')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('draft-exit-cancel-discard')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_note).controller!.text,
        'Latest fictional conversation',
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('draft-exit-discard')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('draft-exit-confirm-discard')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open history'), findsOneWidget);
      expect(store.records[f.key]!['note'], 'Last saved note');
      expect(store.editWrites, 1);
      store.failEdits = false;
      await tester.tap(find.text('Open history'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_note).controller!.text,
        'Last saved note',
      );
      _noRemoteSave(f.transport);
      expect(tester.takeException(), isNull);
    },
  );
}
