import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/home_safety/home_safety_session.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'home_safety_support.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'saved scan room associations recover exactly once and do not override owner reassignment',
    () async {
      final h = await safetyHarness();
      var s = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await s.initialize();
      await s.edit(addRoom('first'));
      await s.edit(addRoom('second'));
      await s.save();
      const id = 'e1b5a17d-3f77-4c5b-b806-526fbe222213';
      h.server.snapshot = CaseSnapshot.fromJson({
        ...h.server.snapshot.toJson(),
        'revision': h.server.snapshot.revision + 1,
        'findings': [
          {
            'id': id,
            'room': 'other',
            'observation': 'Fictional room scan concern',
            'reviewState': 'confirmed',
            'evidenceIds': <String>[],
            'measurements': <Object>[],
          },
        ],
      });
      await h.store.writeBytes(
        'assessment:${s.caseId}:draft',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'caseId': s.caseId,
              'scanImports': {'suggestion': id},
              'scanImportRooms': {'suggestion': 'first'},
            }),
          ),
        ),
      );
      await s.refresh();
      expect(await s.recoverScanRoomLinks(), 1);
      expect(await s.recoverScanRoomLinks(), 0);
      s.dispose();
      s = HomeSafetySession(services: h.services, catalog: h.server.catalog);
      await s.initialize();
      expect(s.document.findingRooms.single.roomId, 'first');
      expect(await s.recoverScanRoomLinks(), 0);
      await s.save();
      await s.edit({
        'type': 'assign_finding',
        'roomId': 'second',
        'findingId': id,
      });
      await s.save();
      expect(await s.recoverScanRoomLinks(), 0);
      expect(s.document.findingRooms.single.roomId, 'second');
      s.dispose();
      h.services.dispose();
      h.auth.dispose();
    },
  );

  test(
    'addressed progress is explicit, restart-safe and invalidated by changed answers or findings',
    () async {
      final h = await safetyHarness();
      var s = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await s.initialize();
      await s.edit(addRoom('first'));
      await s.edit(addRoom('second'));
      await s.edit(answer('first', 'yes'));
      SafetyConcernProgress progress() => roomConcernProgress(
        s.document,
        s.snapshot,
        s.catalog,
        s.document.rooms.first,
        s.operations,
      );
      expect(progress().concerns, 1);
      expect(progress().addressed, 0);
      final review = <String, Object?>{
        'type': 'review_concern',
        'roomId': 'first',
        'questionId': 'bedroom.path',
        'findingId': 'new-concern',
        'observation': 'Fictional dark route',
        'state': 'needs_review',
      };
      await s.edit(review);
      var link = s.document.link('first', 'bedroom.path')!;
      await expectLater(s.setAddressed(link, true), throwsFormatException);
      await s.edit({...review, 'state': 'confirmed'});
      final caseRevision = s.snapshot.revision;
      link = s.document.link('first', 'bedroom.path')!;
      await s.setAddressed(link, true);
      expect(s.snapshot.revision, caseRevision);
      expect(progress().addressed, 1);
      s.dispose();
      h.server.offline = true;
      s = HomeSafetySession(services: h.services, catalog: h.server.catalog);
      await s.initialize();
      expect(progress().addressed, 1);
      await s.setAddressed(link, false);
      expect(progress().addressed, 0);
      await s.setAddressed(link, true);
      await s.edit(answer('first', 'no'));
      expect(progress().addressed, 0);
      await expectLater(s.setAddressed(link, true), throwsFormatException);
      await s.edit({...review, 'state': 'dismissed'});
      expect(progress().concerns, 0);
      await s.edit(answer('first', 'yes'));
      expect(progress().concerns, 1);
      await s.edit({...review, 'state': 'confirmed'});
      expect(progress().addressed, 0);
      link = s.document.link('first', 'bedroom.path')!;
      await s.setAddressed(link, true);
      await s.edit({
        ...review,
        'state': 'confirmed',
        'observation': 'Fictional corrected observation',
      });
      expect(progress().addressed, 0);
      expect(
        roomConcernProgress(
          s.document,
          s.snapshot,
          s.catalog,
          s.document.rooms.last,
          s.operations,
        ).concerns,
        0,
      );
      h.server.offline = false;
      await s.save();
      expect(s.hasPending, false);
      expect(
        s.baseline.history
            .where((e) => (e['operation'] as Map)['type'] == 'set_addressed')
            .length,
        4,
      );
      s.dispose();
    },
  );
  test(
    'Node-produced shared fixture preserves separate rooms, source links, unknown answers and exact receipts',
    () async {
      final catalog = await HomeSafetyCatalog.load();
      final fixture =
          jsonDecode(
                await File(
                  'contracts/v3/fixtures/home-safety.json',
                ).readAsString(),
              )
              as Map;
      final state = HomeSafetyState.fromJson(fixture['state'], catalog);
      expect(state.document.rooms.map((r) => r.id), [
        'fictional-bedroom-one',
        'fictional-bedroom-two',
      ]);
      expect(state.document.answers.map((a) => a.value), ['not_sure', 'yes']);
      expect(state.snapshot.findings.last.reviewState, 'needs_review');
      expect(
        catalog.questions.where((q) => q.concernWhen == 'no').map((q) => q.id),
        containsAll(['stairs.lighting', 'stairs.rails', 'kitchen.stool']),
      );
      for (final raw in fixture['requests'] as List) {
        expect(state.acknowledges(SafetyMutation.fromJson(raw, catalog)), true);
      }
      expect(catalog.forRoom(state.document.rooms.first).length, 6);
      final corrupted = detached(state.toJson());
      (corrupted['safety'] as Map)['caseId'] = 'another-case';
      expect(
        () => HomeSafetyState.fromJson(corrupted, catalog),
        throwsFormatException,
      );
    },
  );
  test(
    'offline rooms and unknown/skipped answers resume without silently uploading',
    () async {
      final h = await safetyHarness();
      var s = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await s.initialize();
      await s.edit(addRoom('first', name: 'Fictional upstairs'));
      await s.edit(addRoom('second', name: 'Fictional downstairs'));
      await s.edit(answer('first', 'not_sure'));
      await s.edit(answer('second', 'not_applicable'));
      s.dispose();
      h.server.offline = true;
      s = HomeSafetySession(services: h.services, catalog: h.server.catalog);
      await s.initialize();
      expect(s.offline, true);
      expect(s.document.rooms.length, 2);
      expect(s.document.answers.map((a) => a.value), [
        'not_sure',
        'not_applicable',
      ]);
      expect(h.server.saves, 0);
      h.server.offline = false;
      await s.save();
      expect(h.server.saves, 4);
      expect(s.hasPending, false);
      expect(h.services.coordinator.currentCase().revision, 1);
      expect(h.store.records[s.localKey]!['pending'], isEmpty);
      s.dispose();
    },
  );
  test(
    'lost save response is recovered from exact history without repeating the mutation',
    () async {
      final h = await safetyHarness();
      var s = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await s.initialize();
      await s.edit(addRoom('first'));
      h.server.loseNextSave = true;
      await expectLater(
        s.save(),
        throwsA(
          isA<MatchingApiException>().having(
            (e) => e.code,
            'code',
            'HOME_SAFETY_SAVE_UNCERTAIN',
          ),
        ),
      );
      expect(s.needsReconcile, true);
      expect(s.pending.length, 1);
      s.dispose();
      s = HomeSafetySession(services: h.services, catalog: h.server.catalog);
      await s.initialize();
      expect(s.hasPending, false);
      expect(s.document.rooms.length, 1);
      expect(h.server.saves, 1);
      s.dispose();
    },
  );
  test(
    'a competing answer is never silently overwritten; explicit rebase retains both rooms',
    () async {
      final h = await safetyHarness(),
          s = HomeSafetySession(
            services: h.services,
            catalog: h.server.catalog,
          );
      await s.initialize();
      await s.edit(addRoom('first'));
      await s.save();
      await s.edit(answer('first', 'yes'));
      h.server.apply(
        SafetyMutation.fromJson({
          'schemaVersion': '3',
          'caseId': s.caseId,
          'expectedCaseRevision': 1,
          'expectedSafetyRevision': 1,
          'mutationId': 'fictional-other-device',
          'operation': answer('first', 'no'),
        }, s.catalog),
      );
      await s.save();
      expect(s.conflict, isNotNull);
      expect(s.document.answer('first', 'bedroom.path')!.value, 'yes');
      expect(h.server.document.answer('first', 'bedroom.path')!.value, 'no');
      await s.resolve(keepDevice: true);
      expect(s.hasPending, true);
      expect(h.server.document.answer('first', 'bedroom.path')!.value, 'no');
      await s.save();
      expect(h.server.document.answer('first', 'bedroom.path')!.value, 'yes');
      s.dispose();
    },
  );
  test(
    'failed local writes and malformed journals cannot replace retained work',
    () async {
      final h = await safetyHarness(),
          s = HomeSafetySession(
            services: h.services,
            catalog: h.server.catalog,
          );
      await s.initialize();
      final before = detached(h.store.records[s.localKey]!);
      h.store.fail = true;
      await expectLater(s.edit(addRoom('not-saved')), throwsStateError);
      expect(s.document.rooms, isEmpty);
      expect(s.pending, isEmpty);
      expect(h.store.records[s.localKey], before);
      s.dispose();
      h.store.fail = false;
      h
          .store
          .records['home-safety.${h.services.coordinator.currentCase().caseId}']!['pending'] = [
        {'ownerId': 'forged'},
      ];
      final bad = detached(
        h
            .store
            .records['home-safety.${h.services.coordinator.currentCase().caseId}']!,
      );
      final reopened = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await expectLater(reopened.initialize(), throwsFormatException);
      expect(h.store.records[reopened.localKey], bad);
      reopened.dispose();
    },
  );
  test(
    'late reads after sign-out cannot adopt a snapshot or overwrite a device journal',
    () async {
      final h = await safetyHarness(),
          s = HomeSafetySession(
            services: h.services,
            catalog: h.server.catalog,
          );
      await s.initialize();
      final before = detached(h.store.records[s.localKey]!);
      final gate = Completer<void>(), entered = Completer<void>();
      h.server.beforeRead = () {
        entered.complete();
        return gate.future;
      };
      final read = s.refresh();
      final assertion = expectLater(
        read,
        throwsA(
          isA<MatchingApiException>().having(
            (e) => e.code,
            'code',
            'STALE_RESPONSE',
          ),
        ),
      );
      await entered.future;
      await h.auth.signOut();
      gate.complete();
      await assertion;
      expect(h.store.records[s.localKey], before);
      s.dispose();
    },
  );
  test('removing the local case clears its private room journal', () async {
    final h = await safetyHarness();
    final s = HomeSafetySession(
      services: h.services,
      catalog: h.server.catalog,
    );
    await s.initialize();
    await s.edit(addRoom('fictional-room'));
    expect(h.store.records.containsKey(s.localKey), true);
    s.dispose();
    await h.services.coordinator.clearCaseLocally(h.server.snapshot.caseId);
    expect(h.store.records.containsKey(s.localKey), false);
  });
  test(
    'a new server change during conflict review requires another explicit review',
    () async {
      final h = await safetyHarness();
      final s = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await s.initialize();
      await s.edit(addRoom('first'));
      await s.save();
      await s.edit(answer('first', 'yes'));
      void otherAnswer(String value, String id) => h.server.apply(
        SafetyMutation.fromJson({
          'schemaVersion': '3',
          'caseId': s.caseId,
          'expectedCaseRevision': 1,
          'expectedSafetyRevision': h.server.history.length,
          'mutationId': id,
          'operation': answer('first', value),
        }, s.catalog),
      );
      otherAnswer('no', 'fictional-other-1');
      await s.save();
      expect(s.conflict!.revision, 2);
      otherAnswer('not_sure', 'fictional-other-2');
      await s.resolve(keepDevice: true);
      expect(s.conflict!.revision, 3);
      expect(s.pending.single.safetyRevision, 1);
      expect(
        h.server.document.answer('first', 'bedroom.path')!.value,
        'not_sure',
      );
      await s.resolve(keepDevice: true);
      expect(s.conflict, isNull);
      expect(s.pending.single.safetyRevision, 3);
      s.dispose();
    },
  );
}
