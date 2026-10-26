import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/whole_home_session.dart';
import 'package:safe_at_home/features/assessment/domain/scan/whole_home_model.dart';
import 'package:safe_at_home/shared/models/home_model_sync.dart';
import '../../../app/local_private_store_test.dart' show MemorySecrets;
import 'whole_home_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late HomeTestStore store;
  final sessions = <WholeHomeSession>[];
  WholeHomeSession session() {
    final s = WholeHomeSession(
      store: store,
      caseId: homeCaseId,
      isCurrent: () => true,
      currentRooms: () => homeRooms,
      adapter: HomeTestCapture(),
    );
    sessions.add(s);
    return s;
  }

  HomeModelBundle bundle() {
    final one = homeScene(), two = homeScene();
    return HomeModelBundle(
      caseId: homeCaseId,
      model: WholeHomeModel(
        referenceRoomId: homeRooms[0].id,
        method: 'reviewed_alignment',
        rooms: [
          HomeRoomPlacement(
            roomId: homeRooms[0].id,
            fingerprint: one.fingerprint,
            pose: RoomPose(),
            reviewed: true,
          ),
          HomeRoomPlacement(
            roomId: homeRooms[1].id,
            fingerprint: two.fingerprint,
            parentId: homeRooms[0].id,
            parentFingerprint: one.fingerprint,
            pose: RoomPose(x: 4),
            reviewed: true,
          ),
        ],
      ),
      sources: {homeRooms[0].id: one, homeRooms[1].id: two},
      roomTypes: {homeRooms[0].id: 'bathroom', homeRooms[1].id: 'bathroom'},
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sah-home-restore-');
    store = HomeTestStore(
      directory: dir,
      accountId: 'fictional-account',
      secrets: MemorySecrets(),
    );
  });
  tearDown(() async {
    for (final s in sessions) {
      s.dispose();
    }
    sessions.clear();
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'fresh-device restore atomically survives restart without inventing separate room reviews',
    () async {
      final s = session(), b = bundle();
      await s.initialize();
      await s.restoreBundle(b);
      expect(s.connected().length, 2);
      for (final r in homeRooms) {
        expect(
          await store.readBytes(
            BathroomScanSession.storageKey(homeCaseId, room: r),
          ),
          isNull,
        );
      }
      final reopened = session();
      await reopened.initialize();
      expect(reopened.bundle()!.encode(), b.encode());
      expect(reopened.connected().last.pose.x, 4);
    },
  );
  test(
    'conflicting local room scans survive failed restore and cannot be silently attached',
    () async {
      final b = bundle(), s = session(), different = homeScene();
      await seedHomeRoom(store, homeRooms.first, different);
      await s.initialize();
      await expectLater(
        s.restoreBundle(b),
        throwsA(isA<HomeModelSourceChanged>()),
      );
      expect(s.model, isNull);
      expect(
        (await BathroomScanSession.readSaved(
          store,
          homeCaseId,
          room: homeRooms.first,
        ))!.scene!.fingerprint,
        different.fingerprint,
      );
    },
  );
  test(
    'failed atomic save retains previous assembly and its source snapshots',
    () async {
      final s = session(), before = bundle();
      await s.initialize();
      await s.restoreBundle(before);
      store.failKey = s.key;
      await expectLater(
        s.restoreBundle(bundle()),
        throwsA(isA<FileSystemException>()),
      );
      store.failKey = null;
      final reopened = session();
      await reopened.initialize();
      expect(reopened.bundle()!.encode(), before.encode());
    },
  );
  test(
    'new independent room scan invalidates the restored assembly on reopen',
    () async {
      final s = session();
      await s.initialize();
      await s.restoreBundle(bundle());
      await seedHomeRoom(store, homeRooms.first, homeScene());
      final reopened = session();
      await reopened.initialize();
      expect(reopened.connected(), isEmpty);
      expect(reopened.model, isNotNull);
    },
  );
  test(
    'room deletion purges cloud-restored geometry and pending upload; deletion fence refuses old restore',
    () async {
      final s = session(), b = bundle();
      await s.initialize();
      await s.restoreBundle(b);
      await store.writeBytes(
        '${s.key}:upload',
        Uint8List.fromList(utf8.encode(jsonEncode({'bundleJson': b.encode()}))),
      );
      await WholeHomeSession.purgeForRoomDeletion(
        store,
        homeCaseId,
        homeRooms.first.id,
        isCurrent: () => true,
      );
      expect(await store.readBytes(s.key), isNull);
      expect(await store.readBytes('${s.key}:upload'), isNull);
      await expectLater(s.restoreBundle(b), throwsA(isA<ScanScopeExpired>()));
    },
  );
}
