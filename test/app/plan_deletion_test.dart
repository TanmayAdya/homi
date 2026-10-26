import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/plan_deletion_action.dart';
import 'package:safe_at_home/features/cases/plan_deletion_dialog.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../case_discovery_api_client_test.dart' show apiError;
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

class _DeletionStore extends MemoryPrivateStore {
  bool failReceipt = false;
  String? failDelete;
  String? failRead;

  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    if (key == failRead) {
      throw const FormatException('Fictional damaged receipt');
    }
    return super.readJson(key);
  }

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (failReceipt && key.startsWith('case-delete.')) {
      throw StateError('Fictional storage failure');
    }
    await super.writeJson(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (key == failDelete) throw StateError('Fictional cleanup failure');
    await super.delete(key);
  }
}

void main() {
  late _DeletionStore store;
  late FakeTransport transport;
  late AppServices app;
  late Map<String, Map<String, Object?>> server;
  bool loseDeleteResponse = false;
  bool conflictOnDelete = false;
  Completer<void>? pendingRead;

  void initialize() {
    store = _DeletionStore();
    server = {};
    loseDeleteResponse = false;
    conflictOnDelete = false;
    pendingRead = null;
    transport = FakeTransport((request) async {
      final body = http.requestJson(request);
      final id = body['caseId'] as String;
      switch (request.endpoint.path) {
        case '/v1/create-case':
          server[id] = {...body, 'revision': 1};
          return http.jsonResponse(server[id]);
        case '/v1/read-case':
          await pendingRead?.future;
          return server[id] == null
              ? apiError('CASE_NOT_FOUND', 404)
              : http.jsonResponse(server[id]);
        case '/v1/list-evidence':
          return http.jsonResponse({
            'schemaVersion': '1',
            'caseId': id,
            'caseRevision': body['expectedCaseRevision'],
            'catalogRevision': 3,
            'evidence': <Object>[],
          });
        case '/v1/delete-case':
          if (conflictOnDelete) {
            return apiError('CASE_REVISION_MISMATCH', 409);
          }
          server.remove(id);
          if (loseDeleteResponse) {
            throw const MatchingTransportException(
              MatchingTransportFailure.network,
            );
          }
          return http.jsonResponse({
            'schemaVersion': '1',
            'caseId': id,
            'deleted': true,
          });
        default:
          throw StateError('Unexpected fictional request');
      }
    });
    app = services(store, transport);
  }

  setUp(initialize);

  tearDown(() {
    app.dispose();
    app.session.dispose();
  });

  Future<(String, String)> twoPlans({bool online = true}) async {
    await app.coordinator.createDraft();
    if (online) await app.coordinator.save();
    final first = app.coordinator.draft!.caseId;
    await app.coordinator.createDraft();
    if (online) await app.coordinator.save();
    final second = app.coordinator.draft!.caseId;
    store.records['assessment:$first:photo:fictional'] = {'fictional': true};
    store.records['assessment:$second:photo:fictional'] = {'fictional': true};
    store.records['assessment:$first:metadata'] = {'fictional': true};
    return (first, second);
  }

  int getDeleteCount() => transport.requests
      .where((request) => request.endpoint.path == '/v1/delete-case')
      .length;

  PlanDeletionAction action(String id, {int? revision}) => PlanDeletionAction(
    services: app,
    caseId: id,
    minimumCaseRevision: revision,
  );

  test('deleting an unselected online plan preserves selected work', () async {
    final (target, selected) = await twoPlans();
    final selection = app.coordinator.generation;
    final removal = action(target, revision: 1);
    await removal.prepare();
    expect(app.coordinator.draft!.caseId, selected);
    await removal.deleteConfirmed();
    expect(server.containsKey(target), false);
    expect(server.containsKey(selected), true);
    expect(app.coordinator.draft!.caseId, selected);
    expect(app.coordinator.generation, selection);
    expect(store.records.keys.any((key) => key.contains(target)), false);
    expect(
      store.records.containsKey('assessment:$selected:photo:fictional'),
      true,
    );
    expect(getDeleteCount(), 1);
    final request = transport.requests.last;
    expect(http.requestJson(request)['expectedCatalogRevision'], 3);
  });

  test('device-only removal is offline and preserves other drafts', () async {
    final (target, selected) = await twoPlans(online: false);
    final removal = action(target);
    await removal.prepare();
    expect(removal.localOnly, true);
    await removal.deleteConfirmed();
    expect(transport.requests, isEmpty);
    expect(app.coordinator.draft!.caseId, selected);
    expect(store.records.containsKey('case.$selected'), true);
    expect(store.records.keys.any((key) => key.contains(target)), false);
  });

  test('removing selected plan clears only its coordinator state', () async {
    final (other, target) = await twoPlans();
    final removal = action(target);
    await removal.prepare();
    await removal.deleteConfirmed();
    expect(app.coordinator.draft, isNull);
    expect(store.records.containsKey('case.$other'), true);
  });

  test('lost deletion response checks status without another delete', () async {
    final (target, selected) = await twoPlans();
    final removal = action(target);
    await removal.prepare();
    loseDeleteResponse = true;
    await expectLater(
      removal.deleteConfirmed(),
      throwsA(
        isA<MatchingApiException>().having(
          (error) => error.code,
          'code',
          'DELETION_UNCERTAIN',
        ),
      ),
    );
    expect(store.records.containsKey('case-delete.$target'), true);
    expect(store.records.containsKey('case.$target'), true);
    final resumed = action(target);
    await resumed.prepare();
    expect(resumed.pending, true);
    expect(resumed.ready, false);
    expect(await resumed.checkPending(), true);
    expect(getDeleteCount(), 1);
    expect(app.coordinator.draft!.caseId, selected);
    expect(store.records.keys.any((key) => key.contains(target)), false);
  });

  test('conflicting deletion needs another explicit review', () async {
    final (target, _) = await twoPlans();
    final removal = action(target);
    await removal.prepare();
    conflictOnDelete = true;
    await expectLater(
      removal.deleteConfirmed(),
      throwsA(isA<MatchingApiException>()),
    );
    expect(await removal.checkPending(), false);
    expect(removal.pending, false);
    expect(removal.ready, true);
    expect(server.containsKey(target), true);
    expect(getDeleteCount(), 1);
  });

  test('failed durable receipt prevents any remote deletion', () async {
    final (target, _) = await twoPlans();
    final removal = action(target);
    await removal.prepare();
    store.failReceipt = true;
    await expectLater(removal.deleteConfirmed(), throwsStateError);
    expect(server.containsKey(target), true);
    expect(getDeleteCount(), 0);
  });

  test(
    'interrupted local cleanup retains a retryable deletion receipt',
    () async {
      final (target, selected) = await twoPlans();
      final removal = action(target);
      await removal.prepare();
      store.failDelete = 'assessment:$target:photo:fictional';
      await expectLater(removal.deleteConfirmed(), throwsStateError);
      expect(server.containsKey(target), false);
      expect(store.records['case-delete.$target']?['serverDeleted'], true);
      expect(store.records.containsKey('case.$target'), true);
      store.failDelete = null;
      final resumed = action(target);
      await resumed.prepare();
      expect(await resumed.checkPending(), true);
      expect(getDeleteCount(), 1);
      expect(app.coordinator.draft!.caseId, selected);
    },
  );

  test('new local edits invalidate the removal confirmation', () async {
    final (target, _) = await twoPlans(online: false);
    final removal = action(target);
    await removal.prepare();
    store.records['case.$target']!['uncertain'] = true;
    await expectLater(
      removal.deleteConfirmed(),
      throwsA(isA<MatchingApiException>()),
    );
    expect(store.records.containsKey('case.$target'), true);
    expect(getDeleteCount(), 0);
  });

  test(
    'account change during read cannot delete or clear either plan',
    () async {
      final (target, selected) = await twoPlans();
      pendingRead = Completer<void>();
      final removal = action(target);
      final preparing = removal.prepare();
      final rejected = expectLater(
        preparing,
        throwsA(isA<MatchingApiException>()),
      );
      await Future<void>.delayed(Duration.zero);
      final session = app.session as FakeSession;
      session.generation++;
      session.owner = 'other-fictional-owner';
      pendingRead!.complete();
      await rejected;
      expect(store.records.containsKey('case.$target'), true);
      expect(store.records.containsKey('case.$selected'), true);
      expect(getDeleteCount(), 0);
    },
  );

  test('selection changes revoke a prior removal confirmation', () async {
    final (target, _) = await twoPlans();
    final removal = action(target);
    await removal.prepare();
    await app.coordinator.restoreLocal(target);
    await expectLater(
      removal.deleteConfirmed(),
      throwsA(isA<MatchingApiException>()),
    );
    expect(getDeleteCount(), 0);
    expect(store.records.containsKey('case.$target'), true);
  });

  test('receipt discovery includes pending and receipt-only plans', () async {
    final (target, other) = await twoPlans();
    store.records['case-delete.$target'] = {'serverDeleted': true};
    store.records['case-delete.$other'] = {'localOnly': true};
    store.records.remove('case.$target');
    final pending = await readPendingPlanRemovals(app);
    expect(pending.keys, unorderedEquals([target, other]));
    expect(pending[target]!.serverDeleted, true);
    expect(pending[other]!.localOnly, true);
    expect(app.coordinator.draft!.caseId, other);
    expect(getDeleteCount(), 0);
  });

  test(
    'damaged receipt remains visible and recovers via server read',
    () async {
      final (target, selected) = await twoPlans();
      server.remove(target);
      store.records['case-delete.$target'] = {'pending': true};
      store.failRead = 'case-delete.$target';
      final pending = await readPendingPlanRemovals(app);
      expect(pending.containsKey(target), true);
      expect(pending[target]!.serverDeleted, false);
      final resumed = action(target);
      await resumed.prepare();
      expect(resumed.pending, true);
      expect(await resumed.checkPending(), true);
      expect(getDeleteCount(), 0);
      expect(app.coordinator.draft!.caseId, selected);
      expect(store.records.keys.any((key) => key.contains(target)), false);
    },
  );

  test(
    'unknown or mixed receipt fields never bypass server status check',
    () async {
      final (target, _) = await twoPlans();
      store.records['case-delete.$target'] = {
        'serverDeleted': true,
        'unexpected': true,
      };
      final pending = await readPendingPlanRemovals(app);
      expect(pending[target]!.serverDeleted, false);
      final resumed = action(target);
      await resumed.prepare();
      expect(await resumed.checkPending(), false);
      expect(server.containsKey(target), true);
      expect(store.records.containsKey('case.$target'), true);
      expect(getDeleteCount(), 0);
    },
  );

  for (final target in ['case', 'a.b']) {
    test('local cleanup owns exact namespaces for legal ID $target', () async {
      final (_, selected) = await twoPlans(online: false);
      final record = (await store.readJson('case.$selected'))!;
      (record['draft'] as Map)['caseId'] = target;
      store.records['case.$target'] = record;
      store.records['profile-edit.$target'] = {'values': <String, Object?>{}};
      final owned = [
        'form.$target.fictional-program',
        'intake.$target.fictional-program',
        'history.$target.fictional-program',
        'history-edit.$target.fictional-program',
        'export.$target.fictional-program',
        'annotation-review.$target.fictional-evidence',
        'assessment:$target:photo:fictional',
      ];
      for (final key in owned) {
        store.records[key] = {'fictional': true};
      }
      final otherRecords = [
        'form.$selected.$target',
        'history.$selected.$target',
        'annotation-review.$selected.$target',
        'assessment:$selected:photo:$target',
      ];
      for (final key in otherRecords) {
        store.records[key] = {'fictional': true};
      }
      final removal = action(target);
      await removal.prepare();
      await removal.deleteConfirmed();
      expect(store.records.containsKey('case.$target'), false);
      expect(store.records.containsKey('profile-edit.$target'), false);
      for (final key in owned) {
        expect(store.records.containsKey(key), false, reason: key);
      }
      for (final key in otherRecords) {
        expect(store.records.containsKey(key), true, reason: key);
      }
      expect(store.records.containsKey('case.$selected'), true);
      expect(app.coordinator.draft!.caseId, selected);
    });
  }

  for (final target in ['a', 'a.b']) {
    test(
      'ambiguous legacy keys never choose between a and a.b for $target',
      () async {
        final (_, selected) = await twoPlans(online: false);
        for (final id in ['a', 'a.b']) {
          final record = (await store.readJson('case.$selected'))!;
          (record['draft'] as Map)['caseId'] = id;
          store.records['case.$id'] = record;
        }
        store.records['form.a.b.fictional'] = {'fictional': true};
        final before = store.records.keys.toSet();
        final removal = action(target);
        await removal.prepare();
        await expectLater(removal.deleteConfirmed(), throwsStateError);
        expect(store.records.keys, containsAll(before));
        expect(store.records['case-delete.$target']?['localOnly'], true);
        expect(app.coordinator.draft!.caseId, selected);
        expect(getDeleteCount(), 0);
      },
    );
  }

  Future<void> openDialog(WidgetTester tester, String target) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPlanDeletionDialog(
                context: context,
                services: app,
                caseId: target,
                title: 'Fictional San José home plan',
              ),
              child: const Text('Manage plan'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Manage plan'));
    await tester.pumpAndSettle();
  }

  testWidgets('cancelling never changes selection or deletes a plan', (
    tester,
  ) async {
    app.dispose();
    app.session.dispose();
    initialize();
    final (target, selected) = await twoPlans();
    final selection = app.coordinator.generation;
    await openDialog(tester, target);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.coordinator.draft!.caseId, selected);
    expect(app.coordinator.generation, selection);
    expect(getDeleteCount(), 0);
    expect(store.records.containsKey('case.$target'), true);
  });

  testWidgets('confirmation remains usable at 320px and 3.2x text', (
    tester,
  ) async {
    app.dispose();
    app.session.dispose();
    initialize();
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3.2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final (target, selected) = await twoPlans();
    await openDialog(tester, target);
    expect(find.text('Delete plan'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Delete plan'));
    await tester.tap(find.text('Delete plan'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-deletion-dialog')), findsNothing);
    expect(app.coordinator.draft!.caseId, selected);
    expect(getDeleteCount(), 1);
    expect(tester.takeException(), isNull);
  });
}
