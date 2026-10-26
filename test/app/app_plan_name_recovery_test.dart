import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/shared/models/account_plan_name.dart';
import 'package:safe_at_home/shared/models/plan_name.dart';
import 'package:safe_at_home/shared/services/plan_name_sync.dart';

import '../case_discovery_api_client_test.dart' show jsonResponse, requestJson;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

class _FailedInitialStore extends MemoryPrivateStore {
  bool failAlias = false, failSyncJournal = false;

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if ((failAlias && key.startsWith('plan-name.')) ||
        (failSyncJournal && key.startsWith('plan-name-sync.'))) {
      throw StateError('Fictional interrupted private write');
    }
    await super.writeJson(key, value);
  }
}

void main() {
  for (final resetElsewhere in [false, true]) {
    test(
      'list before interrupted-name recovery preserves ${resetElsewhere ? 'account reset conflict' : 'initial name for sync'}',
      () async {
        final store = _FailedInitialStore()..failAlias = true;
        late AccountPlanName remote;
        final saves = <PlanNameSaveRequest>[];
        final transport = FakeTransport((request) async {
          final body = requestJson(request);
          expect(body['caseId'], remote.caseId);
          switch (request.endpoint.path) {
            case '/v2/read-plan-name':
              return jsonResponse(remote.toJson());
            case '/v2/save-plan-name':
              final mutation = PlanNameSaveRequest.fromJson(body);
              saves.add(mutation);
              expect(mutation.expectedNameRevision, remote.nameRevision);
              remote = AccountPlanName(
                caseId: remote.caseId,
                name: mutation.name,
                nameRevision: remote.nameRevision + 1,
                lastMutationId: mutation.mutationId,
              );
              return jsonResponse(remote.toJson());
            default:
              throw StateError('Unexpected fictional metadata route');
          }
        });
        AppServices app = services(store, transport);
        void restart() {
          app.dispose();
          app.session.dispose();
          app = services(store, transport);
        }

        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });

        await expectLater(
          app.coordinator.createDraft(name: 'Retained first name'),
          throwsStateError,
        );
        final id = app.coordinator.draft!.caseId;
        final initial = PlanName(
          caseId: id,
          name: 'Retained first name',
        ).toJson();
        expect(store.records['case.$id']!['pendingPlanName'], initial);
        expect(store.records.containsKey(PlanName.storageKey(id)), false);
        remote = resetElsewhere
            ? AccountPlanName(
                caseId: id,
                name: null,
                nameRevision: 2,
                lastMutationId: 'other-device-reset',
              )
            : AccountPlanName.initial(id);
        restart();

        await app.coordinator.acceptPlanNames([remote]);
        expect(app.coordinator.nameSync!.contains(id), true);
        expect(app.coordinator.planNameFor(id), isNull);
        await app.coordinator.restoreLocal(id);
        expect(app.coordinator.planNameFor(id), 'Retained first name');
        expect(app.coordinator.localSaveFailed, true);

        store.failAlias = false;
        store.failSyncJournal = true;
        await expectLater(app.coordinator.retryDeviceSave(), throwsStateError);
        expect(store.records['case.$id']!['pendingPlanName'], initial);
        expect(app.coordinator.planNameFor(id), 'Retained first name');
        expect(app.coordinator.localSaveFailed, true);
        store.failSyncJournal = false;
        await app.coordinator.retryDeviceSave();
        expect(app.coordinator.localSaveFailed, false);
        expect(
          store.records['case.$id']!.containsKey('pendingPlanName'),
          false,
        );
        expect(
          store.records[PlanNameSync.storageKey(id)]!['pending'],
          isNotNull,
        );
        expect(app.coordinator.planNameFor(id), 'Retained first name');
        expect(app.coordinator.nameSync!.pendingFor(id), true);
        expect(app.coordinator.nameSync!.hasConflict(id), resetElsewhere);
        expect(transport.requests, isEmpty);

        restart();
        await app.coordinator.restoreLocal(id);
        expect(app.coordinator.planNameFor(id), 'Retained first name');
        await app.coordinator.syncPlanName(id);
        if (resetElsewhere) {
          expect(saves, isEmpty);
          expect(remote.name, isNull);
          expect(remote.nameRevision, 2);
          expect(app.coordinator.nameSync!.hasConflict(id), true);
          expect(app.coordinator.nameSync!.pendingFor(id), true);
        } else {
          expect(saves, hasLength(1));
          expect(remote.name, 'Retained first name');
          expect(remote.nameRevision, 1);
          expect(app.coordinator.nameSync!.pendingFor(id), false);
        }
        expect(
          store.records.keys.where((key) => key.startsWith('case.')),
          hasLength(1),
        );
      },
    );
  }
}
