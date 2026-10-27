import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';
import 'package:safe_at_home/features/local_help/referral_task_import.dart';

import 'referral_test_support.dart';

class _OriginalDirectory implements ReferralDirectory {
  @override
  final providers = [...officialReferrals, ...localProviderCatalog.take(4)];
  @override
  ReferralProvider? provider(String id) =>
      providers.where((p) => p.id == id).firstOrNull;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'catalog expansion and app restart preserve old and new contacts, imports and shared task IDs',
    () async {
      var h = await ReferralHarness.create();
      addTearDown(() => h.dispose());
      final originalRepo = LocalHelpRepository(
        h.app.coordinator,
        directory: _OriginalDirectory(),
      );
      HelpFollowUp followUp(ReferralProvider p) => HelpFollowUp(
        id: 'fictional-${p.id}',
        providerId: p.id,
        title: 'Fictional follow-up ${p.id}',
        responsible: 'Fictional resident',
        dueDate: '2026-11-01',
        createdAt: '2026-10-24T00:00:00.000Z',
      );
      for (final p in localProviderCatalog.take(4)) {
        await originalRepo.saveContact(p.id, 'Fictional original note ${p.id}');
        await originalRepo.saveTask(followUp(p));
      }
      final before = (await originalRepo.load()).toJson();
      final expandedRepo = LocalHelpRepository(h.app.coordinator);
      expect((await expandedRepo.load()).toJson(), before);
      for (final p in localProviderCatalog.skip(4)) {
        await expandedRepo.saveContact(p.id, 'Fictional new note ${p.id}');
        await expandedRepo.saveTask(followUp(p));
      }
      final saved = await expandedRepo.load();
      expect(saved.contacts, hasLength(localProviderCatalog.length));
      final sharedIds = <String, String>{};
      final importer = ReferralTaskImport(h.app, expandedRepo);
      for (final source in saved.tasks) {
        final task = await importer.import(
          source,
          keepDueDate: true,
          confirmedContactNote: saved.contacts
              .singleWhere((c) => c.providerId == source.providerId)
              .note,
        );
        sharedIds[source.providerId] = task.id;
        expect(task.programId, isNull);
        expect(task.dueOn, source.dueDate);
      }
      final store = h.store, server = h.server;
      h.dispose();
      h = await ReferralHarness.create(store: store, server: server);
      final resumed = LocalHelpRepository(h.app.coordinator);
      final after = await resumed.load();
      expect(after.toJson(), saved.toJson());
      final progress = await h.app.progress!.refresh(resumed.caseId);
      expect(progress.tasks, hasLength(localProviderCatalog.length));
      for (final source in after.tasks) {
        final task = progress.tasks.singleWhere(
          (t) => t.referralId == source.providerId,
        );
        expect(task.id, sharedIds[source.providerId]);
        expect(resumed.directory.provider(task.referralId!)?.name, isNotEmpty);
        expect(
          (task.referral!['imported'] as Map)['original'],
          source.toJson(),
        );
        await ReferralTaskImport(
          h.app,
          resumed,
        ).import(source, keepDueDate: true);
      }
      expect(server.tasks, hasLength(localProviderCatalog.length));
      expect(server.mutations, hasLength(localProviderCatalog.length));
      expect(h.device.requests, 0);
      expect(h.device.scheduled, isEmpty);
    },
  );
}
