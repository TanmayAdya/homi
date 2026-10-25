import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/request_history_screen.dart';
import 'package:safe_at_home/shared/models/request_tracking.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, program;
import '../request_tracking_test.dart' as fixture;
import '../services/case_evidence_api_client_test.dart' as http;

class DelayedHistoryStore extends MemoryPrivateStore {
  String? blockedReadKey, blockedDeleteKey;
  final entered = Completer<void>(), release = Completer<void>();
  final deletedKeys = <String>[];
  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    final value = await super.readJson(key);
    if (key == blockedReadKey && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
    if (key == blockedDeleteKey && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.delete(key);
  }
}

void main() {
  for (final dispose in [false, true]) {
    testWidgets(
      'late history read after ${dispose ? 'screen disposal' : 'case switch'} makes no request or cleanup',
      (tester) async {
        final transport = FakeTransport((request) async {
          expect(request.endpoint.path, '/v1/create-case');
          return http.jsonResponse({
            ...http.requestJson(request),
            'revision': 1,
          });
        });
        final store = DelayedHistoryStore();
        final app = services(store, transport);
        addTearDown(app.dispose);
        await app.coordinator.createDraft();
        await app.coordinator.save();
        final original = app.coordinator.snapshot!.caseId;
        await app.coordinator.createDraft();
        await app.coordinator.save();
        final other = app.coordinator.snapshot!.caseId;
        final otherKey = 'history-edit.$other.fictional-program';
        await store.writeJson(otherKey, {'note': 'Other case unfinished edit'});
        await app.coordinator.restoreLocal(original);
        store.blockedReadKey = 'history.$original.fictional-program';
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            home: RequestHistoryScreen(services: app, program: program()),
          ),
        );
        await tester.pump();
        expect(store.entered.isCompleted, true);
        if (dispose) {
          await tester.pumpWidget(
            const MaterialApp(home: Text('Other screen')),
          );
        }
        await app.coordinator.restoreLocal(other);
        store.release.complete();
        await tester.pumpAndSettle();
        expect(
          transport.requests.where((r) => r.endpoint.path != '/v1/create-case'),
          isEmpty,
        );
        expect(store.deletedKeys, isEmpty);
        expect(store.records[otherKey], {'note': 'Other case unfinished edit'});
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'case change during acknowledged-history cleanup preserves both editor journals',
    (tester) async {
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
      final store = DelayedHistoryStore();
      final app = services(store, transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      await app.coordinator.save();
      final original = app.coordinator.snapshot!.caseId;
      await app.coordinator.createDraft();
      await app.coordinator.save();
      final other = app.coordinator.snapshot!.caseId;
      final oldPending = 'history.$original.fictional-program';
      final oldEditor = 'history-edit.$original.fictional-program';
      final otherEditor = 'history-edit.$other.fictional-program';
      final pending = PendingRequestUpdate(
        request: ReadRequestHistoryRequest(
          caseId: original,
          expectedCaseRevision: 1,
          programId: 'fictional-program',
        ),
        expectedRequestRevision: 0,
        update: RequestUpdate.fromJson(fixture.updateJson()),
      );
      await store.writeJson(oldPending, pending.toJson());
      await store.writeJson(oldEditor, {
        'note': 'Original case unfinished edit',
      });
      await store.writeJson(otherEditor, {
        'note': 'Other case unfinished edit',
      });
      await app.coordinator.restoreLocal(original);
      store.blockedDeleteKey = oldPending;
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: RequestHistoryScreen(services: app, program: program()),
        ),
      );
      await tester.pump();
      expect(store.entered.isCompleted, true);
      await app.coordinator.restoreLocal(other);
      store.release.complete();
      await tester.pumpAndSettle();
      expect(store.deletedKeys, [oldPending]);
      expect(store.records[oldEditor], {
        'note': 'Original case unfinished edit',
      });
      expect(store.records[otherEditor], {
        'note': 'Other case unfinished edit',
      });
      final reads = transport.requests.where(
        (r) => r.endpoint.path == '/v1/read-request-history',
      );
      expect(reads, hasLength(1));
      expect(http.requestJson(reads.single)['caseId'], original);
      expect(tester.takeException(), isNull);
    },
  );
}
