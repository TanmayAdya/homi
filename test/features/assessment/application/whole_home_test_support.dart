import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/whole_home_capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import '../domain/scan/scan_test_fixtures.dart';

const homeCaseId = '744fda0d-9d30-4a92-a430-8afca68e35d4';
final homeRooms = [
  RoomInstance(
    id: 'bath-one',
    type: AssessmentLocation.bathroom,
    name: 'First bathroom',
  ),
  RoomInstance(
    id: 'bath-two',
    type: AssessmentLocation.bathroom,
    name: 'Second bathroom',
  ),
  RoomInstance(
    id: 'kitchen',
    type: AssessmentLocation.kitchen,
    name: 'Kitchen',
  ),
];
BathroomScanScene homeScene([String? id]) => BathroomScanScene.fromJson({
  ...scanSceneJson(),
  'scanId': id ?? newUuidV4(),
});
Future<void> seedHomeRoom(
  LocalPrivateStore store,
  RoomInstance room,
  BathroomScanScene scene,
) => store.writeBytes(
  BathroomScanSession.storageKey(homeCaseId, room: room),
  Uint8List.fromList(
    utf8.encode(
      jsonEncode(
        BathroomScanReview(scene: scene).toJson(homeCaseId, room: room),
      ),
    ),
  ),
);

class HomeTestStore extends LocalPrivateStore {
  HomeTestStore({
    required super.directory,
    required super.accountId,
    required super.secrets,
  });
  String? failKey, blockKey;
  Completer<void>? entered, release;
  @override
  Future<void> writeBytes(String key, Uint8List bytes) async {
    if (key == failKey) {
      throw const FileSystemException('Fictional full device');
    }
    if (key == blockKey) {
      blockKey = null;
      entered!.complete();
      await release!.future;
    }
    await super.writeBytes(key, bytes);
  }
}

class HomeTestCapture implements WholeHomeCaptureAdapter {
  bool available = true;
  final starts = <String>[], cancellations = <String>[];
  Future<HomeCaptureResult> Function(String, List<HomeCaptureRoom>)? onStart;
  @override
  Future<bool> supported() async => available;
  @override
  Future<HomeCaptureResult> start(
    String id,
    List<HomeCaptureRoom> rooms,
  ) async {
    starts.add(id);
    return onStart == null ? result(id, rooms) : onStart!(id, rooms);
  }

  HomeCaptureResult result(String id, List<HomeCaptureRoom> rooms) =>
      HomeCaptureResult({
        for (final room in rooms) room.token: homeScene(room.token),
      }, homeScene(id));
  @override
  Future<void> cancel(String id) async {
    cancellations.add(id);
  }
}
