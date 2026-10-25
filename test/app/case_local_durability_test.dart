import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

class ControlledCaseStore extends MemoryPrivateStore {
  final pending = <Completer<void>>[];
  bool hold = false;
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (hold && key.startsWith('case.')) {
      final release = Completer<void>();
      pending.add(release);
      await release.future;
    }
    await super.writeJson(key, value);
  }
}

CaseDraft changeCity(CaseDraft original, String city) => CaseDraft.fromJson({
  ...original.toJson(),
  'profile': {...original.profile.toJson(), 'city': city},
});

void main() {
  test(
    'device-saved status waits for durable success and reports failures',
    () async {
      final store = ControlledCaseStore();
      final app = services(
        store,
        FakeTransport((_) async => throw StateError('No network')),
      );
      addTearDown(app.dispose);
      final c = app.coordinator;
      await c.createDraft();
      store.hold = true;
      final saving = c.updateDraft(
        changeCity(c.currentDraft(), 'Fictional first city'),
      );
      final failure = expectLater(saving, throwsStateError);
      expect(c.localWritePending, true);
      expect(c.notice, isNot(contains('Saved on this device')));
      store.pending.single.completeError(StateError('Fictional full storage'));
      await failure;
      expect(c.localWritePending, false);
      expect(c.localSaveFailed, true);
      expect(c.notice, contains('not saved on this device'));
      expect(
        (store.records['case.${c.draft!.caseId}']!['draft'] as Map)['profile'],
        isNot(containsPair('city', 'Fictional first city')),
      );
      final retry = c.updateDraft(c.currentDraft());
      expect(c.localWritePending, true);
      store.pending.last.complete();
      await retry;
      expect(c.localWritePending, false);
      expect(c.localSaveFailed, false);
      expect(c.notice, 'Saved on this device; not yet saved online.');
    },
  );

  test(
    'an older local write cannot declare newer edits saved or failed',
    () async {
      final store = ControlledCaseStore();
      final app = services(
        store,
        FakeTransport((_) async => throw StateError('No network')),
      );
      addTearDown(app.dispose);
      final c = app.coordinator;
      await c.createDraft();
      store.hold = true;
      final first = c.updateDraft(
        changeCity(c.currentDraft(), 'Fictional older'),
      );
      final firstFailure = expectLater(first, throwsStateError);
      final second = c.updateDraft(
        changeCity(c.currentDraft(), 'Fictional newer'),
      );
      store.pending.first.completeError(StateError('Earlier write failed'));
      await firstFailure;
      expect(c.localWritePending, true);
      expect(c.localSaveFailed, false);
      expect(c.notice, 'Saving changes on this device…');
      store.pending.last.complete();
      await second;
      expect(c.localWritePending, false);
      expect(c.localSaveFailed, false);
      expect(c.currentDraft().profile.city, 'Fictional newer');
      expect(c.notice, 'Saved on this device; not yet saved online.');
    },
  );

  test(
    'late local failure after explicit discard cannot mark another case failed',
    () async {
      final store = ControlledCaseStore();
      final app = services(
        store,
        FakeTransport((_) async => throw StateError('No network')),
      );
      addTearDown(app.dispose);
      final c = app.coordinator;
      await c.createDraft();
      final other = c.currentDraft().caseId;
      await c.createDraft();
      store.hold = true;
      final first = c.updateDraft(
        changeCity(c.currentDraft(), 'Fictional pending'),
      );
      final failure = expectLater(first, throwsStateError);
      await c.clearSelected();
      await c.restoreLocal(other);
      store.pending.single.completeError(StateError('Old case write failed'));
      await failure;
      expect(c.currentDraft().caseId, other);
      expect(c.localWritePending, false);
      expect(c.localSaveFailed, false);
      expect(
        c.notice,
        'Restored on this device. Check saved state before continuing.',
      );
    },
  );
}
