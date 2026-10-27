import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/whole_home_capture_adapter.dart';
import 'package:safe_at_home/features/assessment/application/whole_home_session.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/domain/local_place_rooms.dart';
import 'package:safe_at_home/features/assessment/domain/scan/whole_home_model.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import '../domain/scan/scan_test_fixtures.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import '../../../app/local_private_store_test.dart' show MemorySecrets;
import 'whole_home_test_support.dart';

void main() {
  late Directory directory;
  late MemorySecrets secrets;
  late HomeTestStore store;
  late HomeTestCapture capture;
  late List<RoomInstance> rooms;
  var current = true;
  final sessions = <WholeHomeSession>[];
  WholeHomeSession make([LocalPrivateStore? storage]) {
    final s = WholeHomeSession(
      store: storage ?? store,
      caseId: homeCaseId,
      isCurrent: () => current,
      currentRooms: () => rooms,
      adapter: capture,
    );
    sessions.add(s);
    return s;
  }

  Future<WholeHomeSession> aligned() async {
    final s = make();
    await s.initialize();
    await s.setReference('bath-one');
    await s.place('bath-two', 'bath-one', RoomPose(x: 4, y: 1, yaw: 90));
    return s;
  }

  final names = {for (final r in homeRooms) r.id: r.name!};
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sah-fictional-home-');
    secrets = MemorySecrets();
    store = HomeTestStore(
      directory: directory,
      accountId: 'fictional-account',
      secrets: secrets,
    );
    capture = HomeTestCapture();
    current = true;
    rooms = List.of(homeRooms);
    for (final room in rooms) {
      await seedHomeRoom(store, room, homeScene());
    }
  });
  tearDown(() async {
    for (final s in sessions) {
      s.dispose();
    }
    sessions.clear();
    await store.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'first interrupted connected capture does not claim saved models exist',
    () async {
      for (final room in rooms) {
        await store.delete(
          BathroomScanSession.storageKey(homeCaseId, room: room),
        );
      }
      final s = make();
      await store.writeJson(s.intentKey, {
        'version': 1,
        'captureId': 'fictional-capture',
      });
      await s.initialize();
      expect(s.model, isNull);
      expect(s.scans, isEmpty);
      expect(
        s.notice,
        'The connected capture was interrupted. Start a new capture when ready.',
      );
      expect(await store.readJson(s.intentKey), isNull);
    },
  );

  test(
    'card status reads do not clear interrupted capture intent or include archived rooms',
    () async {
      final s = await aligned();
      await store.writeJson(s.intentKey, {
        'version': 1,
        'captureId': 'fictional-capture',
      });
      final before = await store.readBytes(s.intentKey);
      final connected = await WholeHomeSession.readSavedConnectedRoomIds(
        store: store,
        caseId: homeCaseId,
        rooms: rooms,
        isCurrent: () => current,
      );
      expect(connected, {'bath-one', 'bath-two'});
      expect(await store.readBytes(s.intentKey), before);
      final active = await WholeHomeSession.readSavedConnectedRoomIds(
        store: store,
        caseId: homeCaseId,
        rooms: rooms.where((r) => r.id != 'bath-two').toList(),
        isCurrent: () => current,
      );
      expect(active, {'bath-one'});
      current = false;
      await expectLater(
        WholeHomeSession.readSavedConnectedRoomIds(
          store: store,
          caseId: homeCaseId,
          rooms: rooms,
          isCurrent: () => current,
        ),
        throwsA(isA<ScanScopeExpired>()),
      );
    },
  );

  test(
    'device place layouts restore separately from structured layouts and other cases',
    () async {
      final structured = await aligned();
      final original = await store.readBytes(structured.key);
      for (final room in LocalPlaceRooms.all.take(2)) {
        await seedHomeRoom(store, room, homeScene());
      }
      WholeHomeSession local(String caseId) {
        final value = WholeHomeSession(
          store: store,
          caseId: caseId,
          isCurrent: () => current,
          currentRooms: () => LocalPlaceRooms.all,
          adapter: capture,
          localPlaces: true,
        );
        sessions.add(value);
        return value;
      }

      final value = local(homeCaseId);
      await value.initialize();
      expect(value.model, isNull);
      await value.setReference(LocalPlaceRooms.all.first.id);
      await value.place(
        LocalPlaceRooms.all[1].id,
        LocalPlaceRooms.all.first.id,
        RoomPose(x: 3),
      );
      expect(value.key, LocalPlaceRooms.homeKey(homeCaseId));
      expect(value.key, isNot(structured.key));
      expect(await store.readBytes(structured.key), original);
      final reopened = local(homeCaseId);
      await reopened.initialize();
      expect(reopened.connected(), hasLength(2));
      final other = local('11111111-0000-4000-8000-000000000001');
      await other.initialize();
      expect(other.model, isNull);
      expect(other.scans, isEmpty);
      current = false;
      await expectLater(
        value.setReference(LocalPlaceRooms.all.first.id),
        throwsA(isA<ScanScopeExpired>()),
      );
    },
  );

  test(
    'account private-store clearing removes place scans and connected layouts',
    () async {
      final room = LocalPlaceRooms.all.first;
      await seedHomeRoom(store, room, homeScene());
      final value = WholeHomeSession(
        store: store,
        caseId: homeCaseId,
        isCurrent: () => current,
        currentRooms: () => LocalPlaceRooms.all,
        adapter: capture,
        localPlaces: true,
      );
      sessions.add(value);
      await value.initialize();
      await value.setReference(room.id);
      await store.clear();
      final reopened = LocalPrivateStore(
        directory: directory,
        accountId: 'fictional-account',
        secrets: secrets,
      );
      expect(await reopened.readBytes(value.key), isNull);
      expect(
        await reopened.readBytes(
          BathroomScanSession.storageKey(homeCaseId, room: room),
        ),
        isNull,
      );
      await reopened.close();
    },
  );

  test(
    'ARCore capture proposal requires review, persists its method, and fences changed baselines',
    () async {
      final s = await aligned();
      BathroomScanScene scene(String id) => BathroomScanScene.fromJson({
        ...scanSceneJson(
          source: 'arcore',
          elements: [
            scanElementJson(
              kind: 'unknown',
              nativeCategory: 'vertical',
              dimensions: [2, 0, 3],
              confidence: 'unknown',
            ),
          ],
        ),
        'scanId': id,
      });
      capture.onStart = (id, rooms) async => HomeCaptureResult({
        for (final r in rooms) r.token: scene(r.token),
      }, scene(id));
      await s.capture(['bath-one', 'bath-two'], names);
      expect(s.proposal!.method, 'arcore_shared_frame');
      expect(s.connected(s.proposal), isEmpty);
      expect(s.model!.method, 'reviewed_alignment');
      final resumed = make();
      await resumed.initialize();
      await resumed.acceptCapture();
      expect(resumed.connected(), hasLength(2));
      expect(
        resumed.model!.captures.values.every(
          (v) => v.source == ScanSource.arcore,
        ),
        isTrue,
      );
      await seedHomeRoom(store, rooms[1], homeScene());
      await resumed.initialize();
      expect(resumed.connected(), hasLength(1));
    },
  );
  test(
    'reviewed alignment survives encrypted store/controller reopen without rewriting room scans',
    () async {
      final original = await store.readBytes(
        BathroomScanSession.storageKey(homeCaseId, room: rooms.first),
      );
      final s = await aligned();
      final reopenedStore = LocalPrivateStore(
        directory: directory,
        accountId: store.accountId,
        secrets: secrets,
      );
      final reopened = make(reopenedStore);
      await reopened.initialize();
      expect(reopened.connected().map((r) => r.roomId), [
        'bath-one',
        'bath-two',
      ]);
      expect(reopened.model!.globalPose('bath-two').x, 4);
      expect(
        await store.readBytes(
          BathroomScanSession.storageKey(homeCaseId, room: rooms.first),
        ),
        original,
      );
      expect(reopened.model!.toJson(homeCaseId), s.model!.toJson(homeCaseId));
      final disk = await directory
          .list()
          .where((f) => f is File)
          .cast<File>()
          .first;
      expect(await disk.readAsString(), isNot(contains('bath-one')));
      await reopenedStore.close();
    },
  );
  test(
    'failed save preserves previous durable model and allows retry',
    () async {
      final s = await aligned();
      final previous = s.model!.toJson(homeCaseId);
      store.failKey = s.key;
      await expectLater(
        s.place('bath-two', 'bath-one', RoomPose(x: 8)),
        throwsA(isA<FileSystemException>()),
      );
      expect(s.model!.toJson(homeCaseId), previous);
      final reopened = make();
      await reopened.initialize();
      expect(reopened.model!.toJson(homeCaseId), previous);
      store.failKey = null;
      await s.place('bath-two', 'bath-one', RoomPose(x: 8));
      expect(s.model!.globalPose('bath-two').x, 8);
    },
  );
  test(
    'source replacement between opening and saving cannot reuse old placement review',
    () async {
      final s = await aligned();
      final original = s.model;
      await seedHomeRoom(store, rooms[1], homeScene());
      await expectLater(
        s.place('bath-two', 'bath-one', RoomPose(x: 6)),
        throwsA(isA<HomeModelSourceChanged>()),
      );
      expect(s.model, same(original));
      await s.initialize();
      expect(s.connected().map((r) => r.roomId), ['bath-one']);
      await s.place('bath-two', 'bath-one', RoomPose(x: 6));
      await seedHomeRoom(store, rooms.first, homeScene());
      await s.initialize();
      expect(s.connected(), isEmpty);
    },
  );
  test(
    'native proposal survives restart separately, requires acceptance, and preserves originals',
    () async {
      final s = await aligned();
      final original = s.model!.toJson(homeCaseId);
      final scan = await store.readBytes(
        BathroomScanSession.storageKey(homeCaseId, room: rooms[1]),
      );
      await s.capture(['bath-one', 'bath-two'], names);
      expect(s.model!.toJson(homeCaseId), original);
      expect(s.proposal!.rooms.every((r) => !r.reviewed), isTrue);
      expect(s.connected(s.proposal), isEmpty);
      final resumed = make();
      await resumed.initialize();
      expect(resumed.proposal, isNotNull);
      expect(resumed.model!.toJson(homeCaseId), original);
      await resumed.acceptCapture();
      expect(resumed.model!.method, 'roomplan_shared_frame');
      expect(resumed.connected(), hasLength(2));
      expect(resumed.proposal, isNull);
      expect(await store.readBytes(resumed.draftKey), isNull);
      expect(
        await store.readBytes(
          BathroomScanSession.storageKey(homeCaseId, room: rooms[1]),
        ),
        scan,
      );
    },
  );
  test(
    'changed baseline blocks accepting an earlier native proposal',
    () async {
      final s = await aligned();
      await s.capture(['bath-one', 'bath-two'], names);
      await seedHomeRoom(store, rooms[1], homeScene());
      await expectLater(
        s.acceptCapture(),
        throwsA(isA<HomeModelSourceChanged>()),
      );
      expect(s.model!.method, 'reviewed_alignment');
      expect(s.proposal, isNotNull);
    },
  );
  test('native failure and interrupted capture retain saved layout', () async {
    final s = await aligned();
    final original = s.model;
    capture.onStart = (_, _) =>
        Future.error(StateError('Fictional tracking failure'));
    await expectLater(
      s.capture(['bath-one', 'bath-two'], names),
      throwsStateError,
    );
    expect(s.model, same(original));
    expect(s.proposal, isNull);
    await store.writeJson(s.intentKey, {
      'version': 1,
      'captureId': 'interrupted',
    });
    final resumed = make();
    await resumed.initialize();
    expect(resumed.notice, contains('interrupted'));
    expect(resumed.model, isNotNull);
    expect(await store.readJson(s.intentKey), isNull);
  });
  test('cancelling during intent write never opens native camera', () async {
    final s = await aligned();
    store.blockKey = s.intentKey;
    store.entered = Completer();
    store.release = Completer();
    final pending = s.capture(['bath-one', 'bath-two'], names);
    final checked = expectLater(pending, throwsA(isA<ScanScopeExpired>()));
    await store.entered!.future;
    await s.cancelCapture();
    store.release!.complete();
    await checked;
    expect(capture.starts, isEmpty);
    expect(capture.cancellations, hasLength(1));
    expect(await store.readJson(s.intentKey), isNull);
  });
  test(
    'scope and room archive cancel native capture and fence its late result',
    () async {
      final s = await aligned();
      final started = Completer<void>();
      final result = Completer<HomeCaptureResult>();
      late String id;
      late List<HomeCaptureRoom> tokens;
      capture.onStart = (v, r) {
        id = v;
        tokens = r;
        started.complete();
        return result.future;
      };
      final checked = expectLater(
        s.capture(['bath-one', 'bath-two'], names),
        throwsA(isA<ScanScopeExpired>()),
      );
      await started.future;
      rooms = [
        rooms.first,
        RoomInstance(
          id: rooms[1].id,
          type: rooms[1].type,
          name: rooms[1].name,
          archived: true,
        ),
      ];
      await s.cancelIfScopeChanged();
      result.complete(capture.result(id, tokens));
      await checked;
      expect(capture.cancellations, [id]);
      expect(s.proposal, isNull);
      expect(s.connected().map((r) => r.roomId), ['bath-one']);
      current = false;
      await expectLater(
        s.setReference('bath-one'),
        throwsA(isA<ScanScopeExpired>()),
      );
    },
  );
  test(
    'acknowledged deletion purges containing assemblies, preserves unrelated original scans',
    () async {
      final s = await aligned();
      await s.capture(['bath-one', 'bath-two'], names);
      final other = await store.readBytes(
        BathroomScanSession.storageKey(homeCaseId, room: rooms[2]),
      );
      await WholeHomeSession.purgeForRoomDeletion(
        store,
        homeCaseId,
        'kitchen',
        isCurrent: () => current,
      );
      expect(await store.readBytes(s.key), isNotNull);
      await WholeHomeSession.purgeForRoomDeletion(
        store,
        homeCaseId,
        'bath-two',
        isCurrent: () => current,
      );
      expect(await store.readBytes(s.key), isNull);
      expect(await store.readBytes(s.draftKey), isNull);
      expect(
        await store.readBytes(
          BathroomScanSession.storageKey(homeCaseId, room: rooms[2]),
        ),
        other,
      );
      final resumed = make();
      await resumed.initialize();
      await resumed.setReference('bath-one');
      await expectLater(
        resumed.place('bath-two', 'bath-one', RoomPose()),
        throwsA(isA<ScanScopeExpired>()),
      );
    },
  );
  test(
    'deletion tombstone prevents an in-flight native result from resurrecting geometry',
    () async {
      final s = await aligned();
      final started = Completer<void>();
      final result = Completer<HomeCaptureResult>();
      late String id;
      late List<HomeCaptureRoom> tokens;
      capture.onStart = (v, r) {
        id = v;
        tokens = r;
        started.complete();
        return result.future;
      };
      final checked = expectLater(
        s.capture(['bath-one', 'bath-two'], names),
        throwsA(isA<ScanScopeExpired>()),
      );
      await started.future;
      await WholeHomeSession.purgeForRoomDeletion(
        store,
        homeCaseId,
        'bath-two',
        isCurrent: () => true,
      );
      result.complete(capture.result(id, tokens));
      await checked;
      expect(await store.readBytes(s.key), isNull);
      expect(await store.readBytes(s.draftKey), isNull);
    },
  );
}
