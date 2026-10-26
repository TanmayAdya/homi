import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/case_coordinator.dart';
import 'package:safe_at_home/shared/services/case_discovery_api_client.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/case_list.dart';
import 'package:safe_at_home/shared/models/plan_name.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore;

class _LocalApp {
  _LocalApp(MemoryPrivateStore store, FakeTransport transport) {
    coordinator = CaseCoordinator(
      session: session,
      store: store,
      cases: http.clientFor(transport),
      discovery: CaseDiscoveryApiClient(
        listCasesEndpoint: Uri.parse('https://example.org/v1/list-cases'),
        caseEndpoint: Uri.parse('https://example.org/v1/read-case'),
        tokenProvider: session.accessToken,
        transport: transport,
      ),
    );
  }
  final session = FakeSession();
  late final CaseCoordinator coordinator;
  void dispose() => coordinator.dispose();
}

class _NameStore extends MemoryPrivateStore {
  bool failNameWrite = false, failNameDelete = false, rejectKeys = false;
  bool failJournalClear = false;
  String? heldNameKey;
  bool holdReadOnce = false;
  Completer<Map<String, Object?>?>? readGate;
  Completer<void>? writeGate;
  final enteredRead = Completer<void>(), enteredWrite = Completer<void>();

  @override
  Future<List<String>> keys() {
    if (rejectKeys) throw StateError('Name reads must not enumerate the vault');
    return super.keys();
  }

  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    if (key == heldNameKey && readGate != null) {
      if (holdReadOnce) heldNameKey = null;
      if (!enteredRead.isCompleted) enteredRead.complete();
      return readGate!.future;
    }
    return super.readJson(key);
  }

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('plan-name.')) {
      if (failNameWrite) throw StateError('Fictional full private storage');
      if (writeGate != null) {
        if (!enteredWrite.isCompleted) enteredWrite.complete();
        await writeGate!.future;
      }
    }
    if (failJournalClear &&
        key.startsWith('case.') &&
        !value.containsKey('pendingPlanName')) {
      throw StateError('Fictional final journal write failure');
    }
    await super.writeJson(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (failNameDelete && key.startsWith('plan-name.')) {
      throw StateError('Fictional name reset failure');
    }
    await super.delete(key);
  }
}

Map<String, Object?> _record(String id) {
  final draft = CaseDraft.fromJson({
    'schemaVersion': '1',
    'caseId': id,
    'profile': {
      'city': null,
      'county': null,
      'healthPlan': null,
      'tenure': null,
      'ageYears': null,
      'householdSize': null,
      'annualIncomeUsd': null,
      'ownerConsentReported': null,
    },
    'unresolvedFields': <String>[],
    'findings': <Object>[],
  });
  return {
    'version': 1,
    'draft': draft.toJson(),
    'snapshot': null,
    'uncertain': false,
    'conflict': false,
  };
}

void main() {
  late _NameStore store;
  late _LocalApp app;
  late FakeTransport transport;
  late Map<String, Map<String, Object?>> server;

  setUp(() {
    store = _NameStore();
    server = {};
    transport = FakeTransport((request) async {
      final body = http.requestJson(request);
      final id = body['caseId'] as String;
      if (request.endpoint.path == '/v1/create-case') {
        server[id] = {...body, 'revision': 1};
        return http.jsonResponse(server[id]);
      }
      if (request.endpoint.path == '/v1/read-case') {
        return http.jsonResponse(server[id]);
      }
      throw StateError('Unexpected fictional request');
    });
    app = _LocalApp(store, transport);
  });
  tearDown(() {
    app.dispose();
    app.session.dispose();
  });

  void restart() {
    app.dispose();
    app.session.dispose();
    app = _LocalApp(store, transport);
  }

  test(
    'named creation, online save, restart and resume preserve only a local title',
    () async {
      await app.coordinator.createDraft(name: '  Grandma’s home  ');
      final id = app.coordinator.draft!.caseId;
      expect(app.coordinator.planNameFor(id), 'Grandma’s home');
      expect(
        store.records['case.$id']!.containsKey('pendingPlanName'),
        isFalse,
      );
      expect(app.coordinator.draft!.toJson().containsKey('name'), isFalse);
      await app.coordinator.save();
      expect(jsonEncode(server), isNot(contains('Grandma')));
      expect(jsonEncode(server), isNot(contains('plan-name')));
      restart();
      await app.coordinator.restoreLocal(id);
      expect(app.coordinator.planNameFor(id), 'Grandma’s home');
      await app.coordinator.resume(
        CaseSummary.fromJson({'caseId': id, 'caseRevision': 1}),
      );
      expect(app.coordinator.planNameFor(id), 'Grandma’s home');
      expect(app.coordinator.snapshot!.revision, 1);
      expect(app.coordinator.hasUnsavedChanges, false);
    },
  );

  test(
    'rename and reset another plan preserve selection, case content and revisions',
    () async {
      await app.coordinator.createDraft(name: 'First');
      final target = app.coordinator.draft!.caseId;
      await app.coordinator.save();
      await app.coordinator.createDraft(name: 'Selected');
      await app.coordinator.save();
      final selected = app.coordinator.draft!.caseId;
      final generation = app.coordinator.generation;
      final caseRows = jsonEncode(
        store.records.entries
            .where((e) => e.key.startsWith('case.'))
            .toList()
            .map((e) => e.value)
            .toList(),
      );
      final serverRows = jsonEncode(server);
      final requests = transport.requests.length;
      await app.coordinator.savePlanName(target, '  Entrance project  ');
      expect(app.coordinator.planNameFor(target), 'Entrance project');
      await app.coordinator.savePlanName(target, '   ');
      expect(app.coordinator.planNameFor(target), isNull);
      expect(store.records.containsKey('plan-name.$target'), isFalse);
      expect(app.coordinator.planNameFor(selected), 'Selected');
      expect(app.coordinator.draft!.caseId, selected);
      expect(app.coordinator.generation, generation);
      expect(app.coordinator.snapshot!.revision, 1);
      expect(app.coordinator.hasUnsavedChanges, false);
      expect(
        jsonEncode(
          store.records.entries
              .where((e) => e.key.startsWith('case.'))
              .toList()
              .map((e) => e.value)
              .toList(),
        ),
        caseRows,
      );
      expect(jsonEncode(server), serverRows);
      expect(transport.requests.length, requests);
    },
  );

  test(
    'unknown targets and pending removals reject names; parsed listed IDs are usable',
    () async {
      await expectLater(
        app.coordinator.savePlanName('unknown', 'Name'),
        throwsStateError,
      );
      final summary = CaseSummary.fromJson({
        'caseId': 'listed',
        'caseRevision': 1,
      });
      app.coordinator.rememberListedCases([summary]);
      await app.coordinator.savePlanName('listed', 'Online plan, local name');
      expect(app.coordinator.draft, isNull);
      expect(transport.requests, isEmpty);
      store.records['case-delete.listed'] = {'serverDeleted': true};
      final retained = jsonEncode(store.records);
      await expectLater(
        app.coordinator.savePlanName('listed', 'Wrong'),
        throwsStateError,
      );
      await expectLater(
        app.coordinator.loadPlanName('listed'),
        throwsStateError,
      );
      expect(jsonEncode(store.records), retained);
    },
  );

  test(
    'invalid input is rejected before creating or changing a plan',
    () async {
      await app.coordinator.createDraft(name: 'Existing');
      final id = app.coordinator.draft!.caseId;
      final generation = app.coordinator.generation;
      final retained = jsonEncode(store.records);
      await expectLater(
        app.coordinator.createDraft(name: 'Bad\nname'),
        throwsFormatException,
      );
      await expectLater(
        app.coordinator.savePlanName(id, List.filled(81, '🏡').join()),
        throwsFormatException,
      );
      expect(app.coordinator.generation, generation);
      expect(app.coordinator.planNameFor(id), 'Existing');
      expect(jsonEncode(store.records), retained);
    },
  );

  test(
    'failed rename and reset preserve the last saved cache and permit retry',
    () async {
      await app.coordinator.createDraft(name: 'Original');
      final id = app.coordinator.draft!.caseId;
      store.failNameWrite = true;
      await expectLater(
        app.coordinator.savePlanName(id, 'New name'),
        throwsStateError,
      );
      expect(app.coordinator.planNameFor(id), 'Original');
      expect(store.records['plan-name.$id']!['name'], 'Original');
      store.failNameWrite = false;
      await app.coordinator.savePlanName(id, 'New name');
      store.failNameDelete = true;
      await expectLater(
        app.coordinator.savePlanName(id, null),
        throwsStateError,
      );
      expect(app.coordinator.planNameFor(id), 'New name');
      expect(app.coordinator.busy, false);
      store.failNameDelete = false;
      await app.coordinator.savePlanName(id, null);
      expect(app.coordinator.planNameFor(id), isNull);
    },
  );

  for (final phase in ['name', 'journal']) {
    test(
      'interrupted named creation at $phase remains recoverable after restart',
      () async {
        store.failNameWrite = phase == 'name';
        store.failJournalClear = phase == 'journal';
        await expectLater(
          app.coordinator.createDraft(name: 'Retained name'),
          throwsStateError,
        );
        final id = app.coordinator.draft!.caseId;
        expect(app.coordinator.planNameFor(id), 'Retained name');
        expect(app.coordinator.localSaveFailed, true);
        expect(
          store.records['case.$id']!['pendingPlanName'],
          PlanName(caseId: id, name: 'Retained name').toJson(),
        );
        await expectLater(app.coordinator.createDraft(), throwsStateError);
        restart();
        await app.coordinator.restoreLocal(id);
        expect(app.coordinator.localSaveFailed, true);
        expect(app.coordinator.planNameFor(id), 'Retained name');
        await expectLater(
          app.coordinator.savePlanName(id, 'Different'),
          throwsStateError,
        );
        store.failNameWrite = false;
        store.failJournalClear = false;
        await app.coordinator.retryDeviceSave();
        expect(app.coordinator.localSaveFailed, false);
        expect(app.coordinator.draft!.caseId, id);
        expect(
          store.records['case.$id']!.containsKey('pendingPlanName'),
          isFalse,
        );
        expect(store.records['plan-name.$id']!['name'], 'Retained name');
        expect(
          store.records.keys.where((key) => key.startsWith('case.')),
          hasLength(1),
        );
        expect(transport.requests, isEmpty);
      },
    );
  }

  test('a slow older read cannot overwrite a successful rename', () async {
    await app.coordinator.createDraft(name: 'Old');
    final id = app.coordinator.draft!.caseId;
    store.heldNameKey = 'plan-name.$id';
    store.readGate = Completer<Map<String, Object?>?>();
    final loading = app.coordinator.loadPlanName(id);
    final rejected = expectLater(
      loading,
      throwsA(http.failure('STALE_RESPONSE')),
    );
    await store.enteredRead.future;
    await app.coordinator.savePlanName(id, 'New');
    store.readGate!.complete(PlanName(caseId: id, name: 'Old').toJson());
    await rejected;
    expect(app.coordinator.planNameFor(id), 'New');
  });

  test(
    'name writes serialize and a held save blocks selection changes',
    () async {
      await app.coordinator.createDraft(name: 'Old');
      final id = app.coordinator.draft!.caseId;
      store.writeGate = Completer<void>();
      final first = app.coordinator.savePlanName(id, 'First');
      await store.enteredWrite.future;
      expect(app.coordinator.busy, true);
      await expectLater(app.coordinator.createDraft(), throwsStateError);
      final second = app.coordinator.savePlanName(id, 'Second');
      expect(app.coordinator.planNameFor(id), 'Old');
      store.writeGate!.complete();
      await first;
      await second;
      expect(app.coordinator.planNameFor(id), 'Second');
      expect(store.records['plan-name.$id']!['name'], 'Second');
    },
  );

  test('account invalidation hides names and rejects delayed reads', () async {
    await app.coordinator.createDraft(name: 'Private name');
    final id = app.coordinator.draft!.caseId;
    store.heldNameKey = 'plan-name.$id';
    store.readGate = Completer<Map<String, Object?>?>();
    final loading = app.coordinator.loadPlanName(id);
    final rejected = expectLater(
      loading,
      throwsA(http.failure('STALE_RESPONSE')),
    );
    await store.enteredRead.future;
    await app.session.signOut();
    expect(app.coordinator.planNameFor(id), isNull);
    store.readGate!.complete(
      PlanName(caseId: id, name: 'Private name').toJson(),
    );
    await rejected;
    await expectLater(
      app.coordinator.savePlanName(id, 'Wrong account'),
      throwsA(http.failure('STALE_RESPONSE')),
    );
    expect(app.coordinator.planNameFor(id), isNull);
  });

  test(
    'cleanup removes exact name records and invalidates an in-flight load',
    () async {
      await app.coordinator.createDraft(name: 'Target');
      final target = app.coordinator.draft!.caseId;
      await app.coordinator.createDraft(name: 'Selected');
      final selected = app.coordinator.draft!.caseId;
      store.heldNameKey = 'plan-name.$target';
      store.readGate = Completer<Map<String, Object?>?>();
      final loading = app.coordinator.loadPlanName(target);
      final rejected = expectLater(
        loading,
        throwsA(http.failure('STALE_RESPONSE')),
      );
      await store.enteredRead.future;
      await app.coordinator.clearCaseLocally(target);
      store.readGate!.complete(
        PlanName(caseId: target, name: 'Target').toJson(),
      );
      await rejected;
      expect(app.coordinator.planNameFor(target), isNull);
      expect(app.coordinator.planNameFor(selected), 'Selected');
      expect(store.records.containsKey('plan-name.$target'), false);
      expect(store.records.containsKey('plan-name.$selected'), true);
    },
  );

  test(
    'name loads use bounded direct reads and reject mismatched records',
    () async {
      await app.coordinator.createDraft(name: 'Bounded');
      final id = app.coordinator.draft!.caseId;
      store.rejectKeys = true;
      expect(await app.coordinator.loadPlanName(id), 'Bounded');
      store.records['plan-name.$id'] = PlanName(
        caseId: 'another',
        name: 'Wrong',
      ).toJson();
      await expectLater(
        app.coordinator.loadPlanName(id),
        throwsFormatException,
      );
      expect(app.coordinator.planNameFor(id), 'Bounded');
    },
  );

  test(
    'exact dotted-ID cleanup preserves neighbours and ambiguous compound ownership fails closed',
    () async {
      store.records['case.a'] = _record('a');
      store.records['case.a.b'] = _record('a.b');
      await app.coordinator.savePlanName('a', 'A');
      await app.coordinator.savePlanName('a.b', 'B');
      store.records['form.a.b.program'] = {'fictional': true};
      final retained = jsonEncode(store.records);
      await expectLater(
        app.coordinator.clearCaseLocally('a'),
        throwsStateError,
      );
      expect(jsonEncode(store.records), retained);
      store.records.remove('form.a.b.program');
      await app.coordinator.clearCaseLocally('a');
      expect(store.records.containsKey('plan-name.a'), false);
      expect(store.records['plan-name.a.b']!['name'], 'B');
      expect(app.coordinator.planNameFor('a.b'), 'B');
    },
  );

  test(
    'parallel background and foreground name reads do not cancel one another',
    () async {
      await app.coordinator.createDraft(name: 'Shared result');
      final id = app.coordinator.draft!.caseId;
      store.heldNameKey = 'plan-name.$id';
      store.readGate = Completer<Map<String, Object?>?>();
      final first = app.coordinator.loadPlanName(id);
      await store.enteredRead.future;
      final second = app.coordinator.loadPlanName(id);
      await Future<void>.delayed(Duration.zero);
      store.readGate!.complete(
        PlanName(caseId: id, name: 'Shared result').toJson(),
      );
      expect(await first, 'Shared result');
      expect(await second, 'Shared result');
      expect(app.coordinator.planNameFor(id), 'Shared result');
    },
  );

  test(
    'a name read captures its mutation epoch before the target-record await',
    () async {
      await app.coordinator.createDraft(name: 'Before');
      final id = app.coordinator.draft!.caseId;
      final oldCase = await store.readJson('case.$id');
      store.heldNameKey = 'case.$id';
      store.holdReadOnce = true;
      store.readGate = Completer<Map<String, Object?>?>();
      final first = app.coordinator.loadPlanName(id);
      final rejected = expectLater(
        first,
        throwsA(http.failure('STALE_RESPONSE')),
      );
      await store.enteredRead.future;
      await app.coordinator.savePlanName(id, 'After');
      store.readGate!.complete(oldCase);
      await rejected;
      expect(app.coordinator.planNameFor(id), 'After');
    },
  );

  test(
    'a corrupted optional name cannot block valid case restore or resume',
    () async {
      await app.coordinator.createDraft(name: 'Good');
      final id = app.coordinator.draft!.caseId;
      await app.coordinator.save();
      store.records['plan-name.$id'] = {'schemaVersion': 'unknown'};
      final corrupt = jsonEncode(store.records['plan-name.$id']);
      restart();
      await app.coordinator.restoreLocal(id);
      expect(app.coordinator.draft!.caseId, id);
      expect(app.coordinator.planNameFor(id), isNull);
      expect(
        app.coordinator.notice,
        contains('custom name could not be loaded'),
      );
      await app.coordinator.resume(
        CaseSummary.fromJson({'caseId': id, 'caseRevision': 1}),
      );
      expect(app.coordinator.draft!.caseId, id);
      expect(app.coordinator.snapshot!.revision, 1);
      expect(jsonEncode(store.records['plan-name.$id']), corrupt);
      await expectLater(
        app.coordinator.loadPlanName(id),
        throwsFormatException,
      );
    },
  );

  test(
    'a malformed initial-name journal is not mistaken for an optional alias',
    () async {
      store.records['case.pending'] = {
        ..._record('pending'),
        'pendingPlanName': {'schemaVersion': 'unknown'},
      };
      await expectLater(
        app.coordinator.restoreLocal('pending'),
        throwsFormatException,
      );
      expect(app.coordinator.draft, isNull);
      expect(store.records['case.pending']!['pendingPlanName'], {
        'schemaVersion': 'unknown',
      });
    },
  );
}
