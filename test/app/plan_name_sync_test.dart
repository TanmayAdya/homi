import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/account_plan_name.dart';
import 'package:safe_at_home/shared/models/plan_name.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/plan_name_sync.dart';
import 'package:safe_at_home/shared/services/plan_names_api_client.dart';

import '../case_discovery_api_client_test.dart'
    show FakeTransport, failure, jsonResponse, requestJson;
import 'live_workflows_test.dart' show MemoryPrivateStore;

const _id = 'fictional-home-plan';

class _SyncStore extends MemoryPrivateStore {
  bool failWrites = false;
  Completer<void>? writeGate;
  final enteredWrite = Completer<void>();

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (failWrites && key.startsWith('plan-name-sync.')) {
      throw StateError('Fictional private write failure');
    }
    if (writeGate != null && key.startsWith('plan-name-sync.')) {
      final gate = writeGate!;
      writeGate = null;
      if (!enteredWrite.isCompleted) enteredWrite.complete();
      await gate.future;
    }
    await super.writeJson(key, value);
  }
}

class _Server {
  AccountPlanName state = AccountPlanName.initial(_id);
  bool offline = false, loseNextSaveReply = false, failNextSave = false;
  final saves = <PlanNameSaveRequest>[];
  Completer<void>? readGate;

  Future<MatchingHttpResponse> call(MatchingHttpRequest request) async {
    if (offline) {
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    final body = requestJson(request);
    expect(body['caseId'], _id);
    switch (request.endpoint.path) {
      case '/v2/read-plan-name':
        await readGate?.future;
        return jsonResponse(state.toJson());
      case '/v2/save-plan-name':
        final mutation = PlanNameSaveRequest.fromJson(body);
        saves.add(mutation);
        if (failNextSave) {
          failNextSave = false;
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        final exact =
            mutation.mutationId == state.lastMutationId &&
            mutation.expectedNameRevision == state.nameRevision - 1 &&
            mutation.name == state.name;
        if (!exact) {
          if (mutation.expectedNameRevision != state.nameRevision ||
              mutation.mutationId == state.lastMutationId) {
            return jsonResponse({
              'schemaVersion': '2',
              'error': {
                'code': 'PLAN_NAME_CONFLICT',
                'message': 'Fictional conflict',
              },
            }, status: 409);
          }
          state = AccountPlanName(
            caseId: _id,
            name: mutation.name,
            nameRevision: state.nameRevision + 1,
            lastMutationId: mutation.mutationId,
          );
        }
        if (loseNextSaveReply) {
          loseNextSaveReply = false;
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return jsonResponse(state.toJson());
      default:
        throw StateError('Unexpected fictional metadata route');
    }
  }
}

class _Device {
  _Device(_Server server, {_SyncStore? savedStore}) {
    store = savedStore ?? _SyncStore();
    transport = FakeTransport(server.call);
    sync = PlanNameSync(
      store: store,
      api: PlanNamesApiClient(
        baseUri: Uri.parse('https://fictional.example'),
        tokenProvider: () async => 'fictional-token',
        transport: transport,
      ),
      isCurrent: () => owner == store.accountId && epoch == 0,
      changed: () => changes++,
    );
  }

  late final _SyncStore store;
  late final FakeTransport transport;
  late final PlanNameSync sync;
  String owner = 'fictional-owner';
  int epoch = 0, changes = 0;
}

Map<String, Object?> _envelope({
  String id = _id,
  Object? confirmed,
  Object? pending,
}) => {'version': 1, 'caseId': id, 'confirmed': confirmed, 'pending': pending};

void main() {
  test(
    'a fresh second device restores the account name without importing a phone alias',
    () async {
      final server = _Server();
      final first = _Device(server);
      await first.sync.save(_id, 'Cedar home');
      expect(first.sync.pendingFor(_id), false);
      expect(first.sync.statusFor(_id), 'Name saved to your account');
      final second = _Device(server);
      expect(second.store.records, isEmpty);
      await second.sync.refresh(_id);
      expect(second.sync.nameFor(_id), 'Cedar home');
      expect(second.sync.remoteFor(_id)!.nameRevision, 1);
      expect(second.sync.pendingFor(_id), false);
      expect(server.saves, hasLength(1));
      final restarted = _Device(server, savedStore: second.store);
      expect(await restarted.sync.load(_id), 'Cedar home');
      expect(restarted.transport.requests, isEmpty);
    },
  );

  test(
    'legacy alias imports once only into a never-named remote revision',
    () async {
      final server = _Server();
      final device = _Device(server);
      device.store.records[PlanName.storageKey(_id)] = PlanName(
        caseId: _id,
        name: 'Legacy home',
      ).toJson();
      await device.sync.load(_id);
      expect(device.sync.pendingFor(_id), true);
      await device.sync.refresh(_id);
      expect(server.state.name, 'Legacy home');
      expect(server.state.nameRevision, 1);
      expect(device.sync.pendingFor(_id), false);
      expect(device.store.records.containsKey(PlanName.storageKey(_id)), false);
      await device.sync.refresh(_id);
      expect(server.saves, hasLength(1));
    },
  );

  test(
    'initial-name recovery survives an earlier revision-zero list cache',
    () async {
      final server = _Server();
      final device = _Device(server);
      await device.sync.accept(server.state);
      expect(device.sync.nameFor(_id), isNull);
      await device.sync.retainInitial(_id, 'Recovered initial name');
      expect(device.sync.nameFor(_id), 'Recovered initial name');
      expect(device.sync.pendingFor(_id), true);
      expect(device.sync.hasConflict(_id), false);
      expect(device.transport.requests, isEmpty);

      final restarted = _Device(server, savedStore: device.store);
      expect(await restarted.sync.load(_id), 'Recovered initial name');
      await restarted.sync.refresh(_id);
      expect(server.state.name, 'Recovered initial name');
      expect(server.state.nameRevision, 1);
      expect(restarted.sync.pendingFor(_id), false);
      expect(server.saves, hasLength(1));
    },
  );

  test(
    'initial-name recovery preserves a known nonzero account reset as a conflict',
    () async {
      final server = _Server()
        ..state = AccountPlanName(
          caseId: _id,
          name: null,
          nameRevision: 2,
          lastMutationId: 'other-device-reset',
        );
      final device = _Device(server);
      await device.sync.accept(server.state);
      await device.sync.retainInitial(_id, 'Recovered initial name');
      expect(device.sync.nameFor(_id), 'Recovered initial name');
      expect(device.sync.remoteFor(_id)!.name, isNull);
      expect(device.sync.remoteFor(_id)!.nameRevision, 2);
      expect(device.sync.hasConflict(_id), true);
      await device.sync.refresh(_id);
      expect(server.saves, isEmpty);
      expect(server.state.name, isNull);

      final restarted = _Device(server, savedStore: device.store);
      expect(await restarted.sync.load(_id), 'Recovered initial name');
      expect(restarted.sync.hasConflict(_id), true);
      expect(restarted.sync.pendingFor(_id), true);
    },
  );

  test(
    'nonzero remote reset is a conflict, never permission to re-import an old alias',
    () async {
      final server = _Server()
        ..state = AccountPlanName(
          caseId: _id,
          name: null,
          nameRevision: 3,
          lastMutationId: 'reset',
        );
      final device = _Device(server);
      device.store.records[PlanName.storageKey(_id)] = PlanName(
        caseId: _id,
        name: 'Old phone alias',
      ).toJson();
      await device.sync.refresh(_id);
      expect(device.sync.nameFor(_id), 'Old phone alias');
      expect(device.sync.remoteFor(_id)!.name, isNull);
      expect(device.sync.hasConflict(_id), true);
      expect(server.saves, isEmpty);
      await device.sync.resolve(
        _id,
        keepLocal: false,
        reviewedRemote: device.sync.remoteFor(_id)!,
      );
      expect(device.sync.nameFor(_id), isNull);
      expect(device.sync.pendingFor(_id), false);
      expect(device.sync.hasConflict(_id), false);
      expect(server.saves, isEmpty);
    },
  );

  test(
    'identical remote alias can be adopted without another mutation',
    () async {
      final server = _Server()
        ..state = AccountPlanName(
          caseId: _id,
          name: 'Same home',
          nameRevision: 2,
          lastMutationId: 'prior',
        );
      final device = _Device(server);
      device.store.records[PlanName.storageKey(_id)] = PlanName(
        caseId: _id,
        name: 'Same home',
      ).toJson();
      await device.sync.refresh(_id);
      expect(device.sync.pendingFor(_id), false);
      expect(device.sync.remoteFor(_id)!.nameRevision, 2);
      expect(server.saves, isEmpty);
    },
  );

  test(
    'offline rename survives restart and retries the exact journaled mutation',
    () async {
      final server = _Server();
      final first = _Device(server);
      await first.sync.refresh(_id);
      server.failNextSave = true;
      await first.sync.save(_id, 'Waiting home');
      expect(first.sync.pendingFor(_id), true);
      final original = server.saves.single.toJson();
      final restarted = _Device(server, savedStore: first.store);
      expect(await restarted.sync.load(_id), 'Waiting home');
      expect(restarted.sync.pendingFor(_id), true);
      await restarted.sync.refresh(_id);
      expect(server.saves, hasLength(2));
      expect(server.saves.last.toJson(), original);
      expect(restarted.sync.nameFor(_id), 'Waiting home');
      expect(restarted.sync.pendingFor(_id), false);
      expect(server.state.nameRevision, 1);
    },
  );

  test(
    'lost successful reply is resolved by mutation identity without a second write',
    () async {
      final server = _Server()..loseNextSaveReply = true;
      final first = _Device(server);
      await first.sync.save(_id, 'Saved despite lost reply');
      expect(server.state.name, 'Saved despite lost reply');
      expect(first.sync.pendingFor(_id), true);
      final restarted = _Device(server, savedStore: first.store);
      await restarted.sync.refresh(_id);
      expect(restarted.sync.pendingFor(_id), false);
      expect(restarted.sync.nameFor(_id), 'Saved despite lost reply');
      expect(server.saves, hasLength(1));
    },
  );

  test(
    'two-device conflict preserves both names until explicit local resolution',
    () async {
      final server = _Server();
      final first = _Device(server);
      final second = _Device(server);
      await first.sync.save(_id, 'Original home');
      await second.sync.refresh(_id);
      server.offline = true;
      await first.sync.save(_id, 'Phone edit');
      server.offline = false;
      await second.sync.save(_id, 'Tablet edit');
      await first.sync.refresh(_id);
      expect(first.sync.hasConflict(_id), true);
      expect(first.sync.nameFor(_id), 'Phone edit');
      expect(first.sync.remoteFor(_id)!.name, 'Tablet edit');
      expect(server.saves, hasLength(2));
      final reviewed = first.sync.remoteFor(_id)!;
      await first.sync.resolve(_id, keepLocal: true, reviewedRemote: reviewed);
      expect(server.state.name, 'Phone edit');
      expect(server.state.nameRevision, 3);
      expect(first.sync.hasConflict(_id), false);
      expect(first.sync.pendingFor(_id), false);
      await second.sync.refresh(_id);
      expect(second.sync.nameFor(_id), 'Phone edit');
    },
  );

  test(
    'same text with a different mutation does not acknowledge an uncertain write',
    () async {
      final server = _Server();
      final device = _Device(server);
      await device.sync.refresh(_id);
      server.failNextSave = true;
      await device.sync.save(_id, 'Same desired text');
      server.state = AccountPlanName(
        caseId: _id,
        name: 'Same desired text',
        nameRevision: 1,
        lastMutationId: 'another-device',
      );
      await device.sync.refresh(_id);
      expect(device.sync.pendingFor(_id), true);
      expect(device.sync.hasConflict(_id), true);
      expect(server.saves, hasLength(1));
    },
  );

  test('resolution cannot reuse a review from a different plan', () async {
    final server = _Server()
      ..state = AccountPlanName(
        caseId: _id,
        name: 'Remote home',
        nameRevision: 1,
        lastMutationId: 'remote',
      );
    final device = _Device(server);
    device.store.records[PlanName.storageKey(_id)] = PlanName(
      caseId: _id,
      name: 'Local home',
    ).toJson();
    await device.sync.refresh(_id);
    final otherReview = AccountPlanName(
      caseId: 'another-plan',
      name: 'Remote home',
      nameRevision: 1,
      lastMutationId: 'remote',
    );
    await expectLater(
      device.sync.resolve(_id, keepLocal: false, reviewedRemote: otherReview),
      throwsStateError,
    );
    expect(device.sync.pendingFor(_id), true);
    expect(device.sync.nameFor(_id), 'Local home');
    expect(server.saves, isEmpty);
  });

  test('a changed remote after review still requires reconciliation', () async {
    final server = _Server()
      ..state = AccountPlanName(
        caseId: _id,
        name: 'Reviewed remote',
        nameRevision: 1,
        lastMutationId: 'remote',
      );
    final device = _Device(server);
    device.store.records[PlanName.storageKey(_id)] = PlanName(
      caseId: _id,
      name: 'Phone edit',
    ).toJson();
    await device.sync.refresh(_id);
    final reviewed = device.sync.remoteFor(_id)!;
    server.state = AccountPlanName(
      caseId: _id,
      name: 'Newer remote',
      nameRevision: 2,
      lastMutationId: 'newer',
    );
    await device.sync.resolve(_id, keepLocal: true, reviewedRemote: reviewed);
    expect(device.sync.hasConflict(_id), true);
    expect(device.sync.nameFor(_id), 'Phone edit');
    expect(device.sync.remoteFor(_id)!.name, 'Newer remote');
    expect(server.saves, isEmpty);
  });

  test(
    'sign-out barrier blocks unsynced names while preserving encrypted work',
    () async {
      final server = _Server()..offline = true;
      final device = _Device(server);
      await device.sync.save(_id, 'Offline name');
      await expectLater(
        device.sync.requireSyncedBeforeSignOut(),
        throwsStateError,
      );
      expect(device.sync.pendingFor(_id), true);
      expect(
        device.store.records.containsKey(PlanNameSync.storageKey(_id)),
        true,
      );
      server.offline = false;
      await device.sync.requireSyncedBeforeSignOut();
      expect(server.state.name, 'Offline name');
      expect(device.sync.pendingFor(_id), false);
    },
  );

  test(
    'sign-out barrier finds legacy aliases and interrupted initial-name journals',
    () async {
      final server = _Server()..offline = true;
      final device = _Device(server);
      device.store.records[PlanName.storageKey(_id)] = PlanName(
        caseId: _id,
        name: 'Legacy name',
      ).toJson();
      await expectLater(
        device.sync.requireSyncedBeforeSignOut(),
        throwsStateError,
      );
      expect(device.store.records.containsKey(PlanName.storageKey(_id)), true);
      final second = _Device(server);
      second.store.records['case.$_id'] = {
        'pendingPlanName': PlanName(caseId: _id, name: 'Initial name').toJson(),
      };
      await expectLater(
        second.sync.requireSyncedBeforeSignOut(),
        throwsStateError,
      );
      expect(second.transport.requests, isEmpty);
    },
  );

  test(
    'sign-out cannot pass while the first encrypted name write is pending',
    () async {
      final server = _Server()..offline = true;
      final device = _Device(server);
      final gate = Completer<void>();
      device.store.writeGate = gate;
      final saving = device.sync.save(_id, 'First pending name');
      await device.store.enteredWrite.future;
      var permitted = false;
      Object? barrierError;
      final barrier = device.sync.requireSyncedBeforeSignOut().then<void>(
        (_) {
          permitted = true;
        },
        onError: (Object error) {
          barrierError = error;
        },
      );
      await Future<void>.delayed(Duration.zero);
      final passedBeforeDurable = permitted;
      gate.complete();
      await saving;
      await barrier;
      expect(passedBeforeDurable, false);
      expect(permitted, false);
      expect(barrierError, isStateError);
      expect(device.sync.pendingFor(_id), true);
      expect(
        device.store.records.containsKey(PlanNameSync.storageKey(_id)),
        true,
      );
    },
  );

  test(
    'sign-out reservation blocks new operations through account cleanup',
    () async {
      final server = _Server();
      final device = _Device(server);
      await device.sync.save(_id, 'Confirmed name');
      final enteredCleanup = Completer<void>();
      final cleanupGate = Completer<void>();
      final signingOut = device.sync.withSignOut(() async {
        enteredCleanup.complete();
        await cleanupGate.future;
        device.epoch++;
      });
      await enteredCleanup.future;
      final sentBefore = device.transport.requests.length;
      await expectLater(device.sync.save(_id, 'Too late'), throwsStateError);
      await expectLater(device.sync.refresh(_id), throwsStateError);
      await expectLater(device.sync.accept(server.state), throwsStateError);
      await expectLater(device.sync.load(_id), throwsStateError);
      await expectLater(device.sync.withSignOut(() async {}), throwsStateError);
      expect(device.transport.requests, hasLength(sentBefore));
      expect(device.sync.nameFor(_id), 'Confirmed name');
      cleanupGate.complete();
      await signingOut;
      expect(device.sync.nameFor(_id), isNull);
      await expectLater(
        device.sync.save(_id, 'Wrong account'),
        throwsA(failure('STALE_RESPONSE')),
      );
    },
  );

  test(
    'failed account cleanup releases reservation without discarding names',
    () async {
      final server = _Server();
      final device = _Device(server);
      await device.sync.save(_id, 'Retained confirmed name');
      await expectLater(
        device.sync.withSignOut(() async {
          throw StateError('Fictional account cleanup failure');
        }),
        throwsStateError,
      );
      expect(device.sync.nameFor(_id), 'Retained confirmed name');
      await device.sync.save(_id, 'Can edit after failed sign-out');
      expect(server.state.name, 'Can edit after failed sign-out');
      expect(device.sync.pendingFor(_id), false);
      await device.sync.requireSyncedBeforeSignOut();
    },
  );

  test(
    'late account response cannot change another owner or notify it',
    () async {
      final server = _Server()..readGate = Completer<void>();
      final device = _Device(server);
      final pending = device.sync.refresh(_id);
      final rejected = expectLater(pending, throwsA(failure('STALE_RESPONSE')));
      await device.transport.started.future;
      final changesBefore = device.changes;
      device.owner = 'another-fictional-owner';
      device.epoch++;
      server.readGate!.complete();
      await rejected;
      expect(device.sync.nameFor(_id), isNull);
      expect(device.sync.remoteFor(_id), isNull);
      expect(device.changes, changesBefore);
      expect(device.store.records, isEmpty);
    },
  );

  test('a failed private journal write prevents a remote rename', () async {
    final server = _Server();
    final device = _Device(server);
    await device.sync.refresh(_id);
    device.store.failWrites = true;
    await expectLater(
      device.sync.save(_id, 'Unjournaled name'),
      throwsStateError,
    );
    expect(server.saves, isEmpty);
    expect(device.sync.nameFor(_id), isNull);
    expect(device.sync.pendingFor(_id), false);
  });

  test(
    'pending deletion blocks name restoration and remote mutation',
    () async {
      final server = _Server();
      final device = _Device(server);
      device.store.records['case-delete.$_id'] = {'serverDeleted': true};
      await expectLater(device.sync.refresh(_id), throwsStateError);
      await expectLater(
        device.sync.save(_id, 'Do not resurrect'),
        throwsStateError,
      );
      expect(device.transport.requests, isEmpty);
    },
  );

  test(
    'malformed journal identity and mutation bindings are rejected before I/O',
    () async {
      final initial = AccountPlanName.initial(_id).toJson();
      final request = PlanNameSaveRequest(
        caseId: _id,
        expectedNameRevision: 0,
        mutationId: 'mutation-a',
        name: 'Phone edit',
      ).toJson();
      for (final record in <Map<String, Object?>>[
        _envelope(id: 'another-plan', confirmed: initial),
        _envelope(confirmed: AccountPlanName.initial('another-plan').toJson()),
        _envelope(
          confirmed: initial,
          pending: {
            'name': 'Phone edit',
            'request': {...request, 'caseId': 'another-plan'},
          },
        ),
        _envelope(
          confirmed: initial,
          pending: {'name': 'Different edit', 'request': request},
        ),
        _envelope(
          confirmed: initial,
          pending: {
            'name': 'Phone edit',
            'request': {...request, 'expectedNameRevision': 1},
          },
        ),
        _envelope(pending: {'name': 'Phone edit', 'request': request}),
        _envelope(
          confirmed: initial,
          pending: {'name': ' name ', 'request': null},
        ),
        {..._envelope(confirmed: initial), 'extra': true},
      ]) {
        final device = _Device(_Server());
        device.store.records[PlanNameSync.storageKey(_id)] = record;
        await expectLater(device.sync.load(_id), throwsFormatException);
        expect(device.transport.requests, isEmpty);
        expect(device.store.records[PlanNameSync.storageKey(_id)], record);
      }
    },
  );

  test(
    'older trusted list pages cannot revert a completed acknowledgement',
    () async {
      final server = _Server();
      final device = _Device(server);
      await device.sync.save(_id, 'Current name');
      await device.sync.accept(AccountPlanName.initial(_id));
      expect(device.sync.nameFor(_id), 'Current name');
      expect(device.sync.remoteFor(_id)!.nameRevision, 1);
      await expectLater(
        device.sync.accept(
          AccountPlanName(
            caseId: _id,
            name: 'Wrong same revision',
            nameRevision: 1,
            lastMutationId: server.state.lastMutationId,
          ),
        ),
        throwsA(failure('UNEXPECTED_RESPONSE')),
      );
      expect(device.sync.nameFor(_id), 'Current name');
    },
  );

  test(
    'shared backend fixture parses and preserves each exact retry identity',
    () async {
      final fixture =
          jsonDecode(
                await File(
                  'contracts/v2/fixtures/plan-names.json',
                ).readAsString(),
              )
              as Map;
      final initial = AccountPlanName.fromJson(fixture['initial']);
      expect(initial.nameRevision, 0);
      for (final mutation in fixture['mutations'] as List) {
        final request = PlanNameSaveRequest.fromJson(mutation['request']);
        final result = AccountPlanName.fromJson(mutation['result']);
        expect(result.caseId, request.caseId);
        expect(result.nameRevision, request.expectedNameRevision + 1);
        expect(result.name, request.name);
        expect(result.lastMutationId, request.mutationId);
      }
    },
  );
}
