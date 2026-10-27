import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

class DelayedCleanupStore extends MemoryPrivateStore {
  final entered = Completer<void>(), release = Completer<void>();
  bool failCleanup = false;
  @override
  Future<List<String>> keys() async {
    entered.complete();
    await release.future;
    if (failCleanup) throw StateError('Fictional storage failure');
    return super.keys();
  }
}

void main() {
  test(
    'case cleanup blocks reopening until every owned record is removed',
    () async {
      final store = DelayedCleanupStore();
      final app = services(
        store,
        FakeTransport((_) async => throw StateError('No network')),
      );
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      final original = app.coordinator.draft!.caseId;
      store.records['assessment:$original:photo:fictional'] = {
        'pixels': 'encrypted fixture',
      };
      store.records['form.$original.scfhp-eaa'] = {'value': 'fictional'};
      store.records['case.other-case'] = {'untouched': true};
      final clearing = app.coordinator.clearSelected();
      await store.entered.future;
      expect(app.coordinator.busy, true);
      expect(app.coordinator.draft, isNull);
      await expectLater(
        app.coordinator.restoreLocal(original),
        throwsStateError,
      );
      await expectLater(app.coordinator.createDraft(), throwsStateError);
      var queuedRan = false;
      final queued = app.coordinator.serialize(() async {
        queuedRan = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(queuedRan, false);
      store.release.complete();
      await clearing;
      await queued;
      expect(queuedRan, true);
      expect(app.coordinator.busy, false);
      expect(app.coordinator.draft, isNull);
      expect(store.records, {
        'case.other-case': {'untouched': true},
      });
    },
  );

  test(
    'a failed cleanup releases busy state without pretending it completed',
    () async {
      final store = DelayedCleanupStore()..failCleanup = true;
      final app = services(
        store,
        FakeTransport((_) async => throw StateError('No network')),
      );
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      final original = app.coordinator.draft!.caseId;
      final clearing = app.coordinator.clearSelected();
      final failure = expectLater(clearing, throwsStateError);
      await store.entered.future;
      store.release.complete();
      await failure;
      expect(app.coordinator.busy, false);
      expect(store.records.containsKey('case.$original'), true);
    },
  );
}
