import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/home_safety/home_safety_session.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart'
    show SafetyMutation;
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/room_lifecycle.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'home_safety_support.dart';

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 100,
    );
  }
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pump();
}

Future<void> idle(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    final state = tester.state<HomeSafetyScreenState>(
      find.byType(HomeSafetyScreen),
    );
    if (!state.working && state.session?.busy == false) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Room operation did not finish.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'archiving preserves local scans; only acknowledged deletion cleans its exact keys, including after lost acknowledgement and restart',
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
      final first = BathroomScanSession.storageKey(
            s.caseId,
            room: s.document.rooms.first,
          ),
          second = BathroomScanSession.storageKey(
            s.caseId,
            room: s.document.rooms.last,
          );
      for (final key in [first, '$first:sync', '$first:upload', second]) {
        h.store.bytes[key] = Uint8List.fromList([1, 2, 3]);
      }
      h.store.bytes['assessment:${s.caseId}:whole-home'] = Uint8List.fromList([
        9,
      ]);
      h.store.bytes['assessment:${s.caseId}:whole-home:draft'] =
          Uint8List.fromList([9]);
      await h.store.writeJson('device-reminders', {'fictional': 'retained'});
      await s.edit(answer('first', 'not_sure'));
      await s.save();
      final snapshot = s.snapshot.toJson();
      await s.edit({'type': 'archive_room', 'roomId': 'first'});
      await s.save();
      expect(s.document.activeRooms.map((r) => r.id), ['second']);
      expect(s.document.archivedRooms.single.id, 'first');
      expect(h.store.bytes[first], isNotNull);
      await expectLater(s.edit(answer('first', 'yes')), throwsFormatException);
      await s.edit({'type': 'restore_room', 'roomId': 'first'});
      await s.save();
      expect(s.document.activeRooms.length, 2);
      expect(s.document.answer('first', 'bedroom.path')!.value, 'not_sure');
      await s.edit({'type': 'archive_room', 'roomId': 'first'});
      await s.save();
      await s.edit({
        'type': 'delete_room',
        'roomId': 'first',
        'expectedModelRevision': 0,
      });
      expect(h.store.bytes[first], isNotNull);
      h.server.loseNextSave = true;
      await expectLater(s.save(), throwsA(isA<MatchingApiException>()));
      expect(h.store.bytes[first], isNotNull);
      s.dispose();
      s = HomeSafetySession(services: h.services, catalog: h.server.catalog);
      await s.initialize();
      expect(s.hasPending, false);
      expect(s.document.rooms.single.id, 'second');
      for (final key in [first, '$first:sync', '$first:upload']) {
        expect(h.store.bytes[key], isNull);
      }
      expect(h.store.bytes[second], isNotNull);
      expect(h.store.bytes['assessment:${s.caseId}:whole-home'], isNull);
      expect(h.store.bytes['assessment:${s.caseId}:whole-home:draft'], isNull);
      expect(h.store.records['device-reminders'], {'fictional': 'retained'});
      expect(s.snapshot.toJson(), snapshot);
      await expectLater(s.edit(addRoom('first')), throwsStateError);
      s.dispose();
      h.services.dispose();
      h.auth.dispose();
    },
  );
  test(
    'a rejected or discarded deletion retains the device model and all linked findings',
    () async {
      final h = await safetyHarness();
      final s = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await s.initialize();
      await s.edit(addRoom('first'));
      await s.save();
      final key = BathroomScanSession.storageKey(
        s.caseId,
        room: s.document.rooms.single,
      );
      h.store.bytes[key] = Uint8List.fromList([7]);
      await expectLater(
        s.edit({
          'type': 'delete_room',
          'roomId': 'first',
          'expectedModelRevision': 0,
        }),
        throwsFormatException,
      );
      expect(h.store.bytes[key], [7]);
      expect(s.document.rooms.length, 1);
      s.dispose();
      h.services.dispose();
      h.auth.dispose();
    },
  );
  test(
    'a conflicting room deletion cannot be rebased without a fresh confirmation',
    () async {
      final h = await safetyHarness();
      final s = HomeSafetySession(
        services: h.services,
        catalog: h.server.catalog,
      );
      await s.initialize();
      await s.edit(addRoom('first'));
      await s.edit(addRoom('second'));
      await s.save();
      final key = BathroomScanSession.storageKey(
        s.caseId,
        room: s.document.rooms.first,
      );
      h.store.bytes[key] = Uint8List.fromList([1]);
      await s.edit({'type': 'archive_room', 'roomId': 'first'});
      await s.save();
      await s.edit({
        'type': 'delete_room',
        'roomId': 'first',
        'expectedModelRevision': 0,
      });
      h.server.apply(
        SafetyMutation.fromJson({
          'schemaVersion': '3',
          'caseId': s.caseId,
          'expectedCaseRevision': 1,
          'expectedSafetyRevision': h.server.history.length,
          'mutationId': 'concurrent-rename',
          'operation': {
            'type': 'rename_room',
            'roomId': 'second',
            'name': 'Fictional updated room',
          },
        }, h.server.catalog),
      );
      await s.refresh();
      expect(s.conflict, isNotNull);
      expect(s.pendingRoomDeletion, true);
      await expectLater(s.resolve(keepDevice: true), throwsStateError);
      expect(h.store.bytes[key], isNotNull);
      expect(s.pendingRoomDeletion, true);
      await s.resolve(keepDevice: false);
      expect(s.pendingRoomDeletion, false);
      expect(s.document.archivedRooms.single.id, 'first');
      expect(h.store.bytes[key], isNotNull);
      s.dispose();
      h.services.dispose();
      h.auth.dispose();
    },
  );
  testWidgets(
    'archive, cancellation, restore and permanent-delete controls remain reachable with large text',
    (tester) async {
      final h = (await tester.runAsync(() async {
        final h = await safetyHarness();
        final seed = HomeSafetySession(
          services: h.services,
          catalog: h.server.catalog,
        );
        await seed.initialize();
        await seed.edit(addRoom('first', name: 'Fictional room'));
        await seed.save();
        seed.dispose();
        return h;
      }))!;
      tester.view.physicalSize = const Size(320, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(
              ctx,
            ).copyWith(textScaler: const TextScaler.linear(2.5)),
            child: child!,
          ),
          home: HomeSafetyScreen(
            services: h.services,
            catalog: h.server.catalog,
            workspaceMode: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('room-first')));
      await tester.tap(find.byKey(const ValueKey('room-first')));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('room-menu-first')));
      await tester.tap(find.byKey(const ValueKey('room-menu-first')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('archive-room-first')));
      await tester.pump(const Duration(milliseconds: 350));
      await reveal(tester, find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.server.document.rooms.single.archived, false);
      await reveal(tester, find.byKey(const ValueKey('room-menu-first')));
      await tester.tap(find.byKey(const ValueKey('room-menu-first')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('archive-room-first')));
      await tester.pump(const Duration(milliseconds: 350));
      final confirm = find.widgetWithText(FilledButton, 'Archive room');
      await reveal(tester, confirm);
      await tester.tap(confirm);
      await idle(tester);
      expect(find.byKey(const ValueKey('room-first')), findsNothing);
      await reveal(tester, find.text('Archived rooms'));
      await tester.tap(find.text('Archived rooms'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('archived-room-first')));
      await tester.tap(find.byKey(const ValueKey('archived-room-first')));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('restore-room-first')));
      expect(find.byKey(const ValueKey('restore-room-first')), findsOneWidget);
      await reveal(tester, find.byKey(const ValueKey('delete-room-first')));
      await tester.tap(find.byKey(const ValueKey('delete-room-first')));
      await tester.pump(const Duration(milliseconds: 350));
      final remove = find.widgetWithText(FilledButton, 'Delete room and scans');
      await reveal(tester, remove);
      await tester.tap(remove);
      await idle(tester);
      expect(h.server.document.rooms, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      h.services.dispose();
      h.auth.dispose();
    },
  );
  test('room lifecycle copy covers each app translation', () {
    for (final entry in roomLifecycleTranslations.entries) {
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      });
      for (final lang in entry.value.keys) {
        expect(AppLocalizations.translations[entry.key]![lang], isNotEmpty);
      }
    }
  });
}
