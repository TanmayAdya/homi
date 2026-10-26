import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/referral_task_import.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'referral_test_support.dart';

HelpFollowUp source(String id, {bool completed = false, String? findingId}) =>
    HelpFollowUp(
      id: id,
      providerId: 'referral-211-national',
      title: 'Fictional ramp follow-up {count}',
      responsible: 'Fictional helper',
      dueDate: '2026-01-02',
      createdAt: '2026-01-01T00:00:00.000Z',
      completedAt: completed ? '2026-01-02T00:00:00.000Z' : null,
      findingId: findingId,
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'explicit import keeps the original, notes and completion while confirming dates independently',
    () async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final local = LocalHelpRepository(h.app.coordinator),
          original = source(
            'one',
            completed: true,
            findingId: 'removed-concern',
          );
      await local.saveContact(original.providerId, 'Resident note {count}');
      await local.saveTask(original);
      final before = h.store.records[local.key];
      final importer = ReferralTaskImport(h.app, local);
      final task = await importer.import(
        original,
        keepDueDate: false,
        confirmedContactNote: 'Resident note {count}',
      );
      expect(task.state, 'completed');
      expect(task.dueOn, isNull);
      expect(task.data['findingId'], isNull);
      final provenance = task.referral!['imported'] as Map;
      expect(provenance['original'], original.toJson());
      expect(provenance['contactNote'], 'Resident note {count}');
      expect(h.store.records[local.key], before);
      expect(h.server.tasks.length, 1);
      expect((await importer.receipts()).containsKey(original.id), true);
      await importer.import(original, keepDueDate: true);
      expect(h.server.tasks.length, 1);
      expect(h.device.requests, 0);
      expect(h.device.scheduled, isEmpty);
      final next = source('two');
      await local.saveTask(next);
      final second = await importer.import(next, keepDueDate: true);
      expect(second.dueOn, next.dueDate);
      expect(second.state, 'pending');
      expect(h.server.tasks.length, 2);
    },
  );
  test(
    'contact notes require explicit preview and changed notes require renewed confirmation',
    () async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final local = LocalHelpRepository(h.app.coordinator),
          first = source('one');
      await local.saveTask(first);
      await local.saveContact(first.providerId, 'Private contact note');
      final importer = ReferralTaskImport(h.app, local);
      final task = await importer.import(first, keepDueDate: false);
      expect((task.referral!['imported'] as Map)['contactNote'], '');
      final second = source('two');
      await local.saveTask(second);
      await expectLater(
        importer.import(
          second,
          keepDueDate: false,
          confirmedContactNote: 'Outdated note',
        ),
        throwsStateError,
      );
      expect(h.server.tasks.length, 1);
      expect((await local.load()).contacts.single.note, 'Private contact note');
    },
  );

  test(
    'a current finding reference is retained independently of benefit-program identity',
    () async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final snapshot = CaseSnapshot.fromJson({
        ...h.app.coordinator.currentCase().toJson(),
        'findings': [
          {
            'id': 'fictional-current-concern',
            'room': 'bathroom',
            'observation': 'Fictional resident concern',
            'reviewState': 'confirmed',
            'evidenceIds': <String>[],
            'measurements': <Object>[],
          },
        ],
      });
      h.server.snapshot = snapshot;
      await h.app.coordinator.adoptRemoteSnapshot(snapshot);
      final local = LocalHelpRepository(h.app.coordinator),
          original = source(
            'known-concern',
            findingId: 'fictional-current-concern',
          );
      await local.saveTask(original);
      final task = await ReferralTaskImport(
        h.app,
        local,
      ).import(original, keepDueDate: false);
      expect(task.data['findingId'], 'fictional-current-concern');
      expect(task.programId, isNull);
      expect(task.referralId, original.providerId);
    },
  );

  test(
    'restart after lost response retries the exact journal and records one receipt',
    () async {
      var h = await ReferralHarness.create();
      final local = LocalHelpRepository(h.app.coordinator),
          original = source('one');
      await local.saveTask(original);
      h.server.loseSave = true;
      await expectLater(
        ReferralTaskImport(h.app, local).import(original, keepDueDate: true),
        throwsA(isA<MatchingApiException>()),
      );
      final journal = h.store.records['progress-pending.${local.caseId}'];
      expect(journal, isNotNull);
      expect(h.server.tasks.length, 1);
      expect(h.store.records[local.key], isNotNull);
      final server = h.server, store = h.store;
      h.dispose();
      h = await ReferralHarness.create(store: store, server: server);
      addTearDown(h.dispose);
      final resumedLocal = LocalHelpRepository(h.app.coordinator),
          importer = ReferralTaskImport(h.app, resumedLocal);
      expect(h.app.progress!.pending[local.caseId], journal);
      await importer.import(original, keepDueDate: false);
      expect(h.server.tasks.length, 1);
      expect(h.server.mutations.length, 1);
      expect(h.app.progress!.pending, isEmpty);
      expect((await importer.receipts()).length, 1);
      expect(h.store.records[local.key], isNotNull);
      expect(h.device.requests, 0);
    },
  );
  test(
    'receipt disk failure recovers from server provenance and another device does not duplicate',
    () async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final local = LocalHelpRepository(h.app.coordinator),
          original = source('one');
      await local.saveTask(original);
      h.store.failReceipt = true;
      await expectLater(
        ReferralTaskImport(h.app, local).import(original, keepDueDate: true),
        throwsStateError,
      );
      expect(h.server.tasks.length, 1);
      expect(h.app.progress!.pending, isEmpty);
      h.store.failReceipt = false;
      await ReferralTaskImport(
        h.app,
        local,
      ).import(original, keepDueDate: true);
      final otherStore = ReferralStore();
      await otherStore.writeJson(
        'case.${local.caseId}',
        h.store.records['case.${local.caseId}']!,
      );
      await otherStore.writeJson(local.key, h.store.records[local.key]!);
      final other = await ReferralHarness.create(
        store: otherStore,
        server: h.server,
      );
      addTearDown(other.dispose);
      await ReferralTaskImport(
        other.app,
        LocalHelpRepository(other.app.coordinator),
      ).import(original, keepDueDate: true);
      expect(h.server.tasks.length, 1);
      expect(h.server.mutations.length, 1);
    },
  );
  test(
    'offline, quota, stale source and account changes retain original local information',
    () async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final local = LocalHelpRepository(h.app.coordinator),
          original = source('one');
      await local.saveTask(original);
      final importer = ReferralTaskImport(h.app, local);
      h.server.offline = true;
      await expectLater(
        importer.import(original, keepDueDate: false),
        throwsA(isA<MatchingApiException>()),
      );
      expect(h.server.tasks, isEmpty);
      h.server.offline = false;
      h.server.limit = true;
      await expectLater(
        importer.import(original, keepDueDate: false),
        throwsA(
          isA<MatchingApiException>().having(
            (e) => e.code,
            'code',
            'PROGRESS_LIMIT',
          ),
        ),
      );
      expect(h.server.tasks, isEmpty);
      expect(h.store.records[local.key], isNotNull);
      h.server.limit = false;
      await h.app.progress!.discard(local.caseId);
      await local.saveTask(
        HelpFollowUp.fromJson({
          ...original.toJson(),
          'title': 'Changed source',
        }),
      );
      await expectLater(
        importer.import(original, keepDueDate: false),
        throwsStateError,
      );
      await local.saveTask(original);
      h.server.beforeRead = () => h.app.session.signOut();
      await expectLater(
        importer.import(original, keepDueDate: false),
        throwsA(anyOf(isA<MatchingApiException>(), isA<StateError>())),
      );
      expect(h.server.tasks, isEmpty);
      expect(h.store.records[local.key], isNotNull);
    },
  );
  test(
    'switching plans rejects a stale importer and deletion removes receipts only for that plan',
    () async {
      final h = await ReferralHarness.create();
      addTearDown(h.dispose);
      final local = LocalHelpRepository(h.app.coordinator),
          original = source('one');
      await local.saveTask(original);
      await ReferralTaskImport(
        h.app,
        local,
      ).import(original, keepDueDate: false);
      final originalCase = local.caseId;
      await h.app.coordinator.createDraft();
      await expectLater(
        ReferralTaskImport(h.app, local).import(original, keepDueDate: false),
        throwsStateError,
      );
      await h.app.coordinator.restoreLocal(originalCase);
      h.store.records['referral-import.other-plan'] = {'retained': true};
      await h.app.coordinator.clearSelected();
      expect(
        h.store.records.containsKey('referral-import.$originalCase'),
        false,
      );
      expect(h.store.records['referral-import.other-plan'], {'retained': true});
    },
  );
}
