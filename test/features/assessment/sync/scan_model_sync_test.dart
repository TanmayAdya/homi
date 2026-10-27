import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/scan_model_sync.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_review.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/shared/models/scan_model_sync.dart';
import 'package:safe_at_home/shared/services/scan_model_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:crypto/crypto.dart';
import '../../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../../../app/case_coordinator_test.dart' show FakeTransport;
import '../../../services/case_evidence_api_client_test.dart' as http;

final scanSyncFixtures =
    (jsonDecode(
              File(
                'contracts/v3/fixtures/scan-model-sync.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map<String, dynamic>>();
const syncCaseId = '11111111-0000-4000-8000-000000000001';
BathroomScanReview fixtureReview([int index = 0]) =>
    BathroomScanReview.fromJson(
      jsonDecode(scanSyncFixtures[index]['request']['reviewJson'] as String),
      syncCaseId,
      room: index == 0 ? null : fixtureRoom(index),
    );
RoomInstance fixtureRoom(int i) => RoomInstance(
  id: 'room-$i',
  type: AssessmentLocation.bedroom,
  name: 'Fictional room $i',
);

class SyncStore extends MemoryPrivateStore {
  bool failPending = false, failMetadata = false;
  final binary = <String, Uint8List>{};
  @override
  Future<Uint8List?> readBytes(String key) async =>
      binary[key] == null ? null : Uint8List.fromList(binary[key]!);
  @override
  Future<void> delete(String key) async {
    binary.remove(key);
    await super.delete(key);
  }

  @override
  Future<void> writeBytes(String key, Uint8List bytes) async {
    if (failPending && key.endsWith(':upload')) {
      throw StateError('Fictional full disk');
    }
    binary[key] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (failMetadata && key.endsWith(':sync')) {
      throw StateError('Fictional full disk');
    }
    await super.writeJson(key, value);
  }
}

class SyncServer {
  final values = <String, Map<String, Object?>>{};
  final receipts = <String, String>{};
  final writes = <Map<String, Object?>>[];
  bool loseNext = false;
  int reads = 0;
  Completer<void>? readGate;
  String _key(Object? roomId) => jsonEncode(roomId);
  Map<String, Object?> state(Object? roomId) => values.putIfAbsent(
    _key(roomId),
    () => {
      'schemaVersion': '3',
      'caseId': syncCaseId,
      'roomId': roomId,
      'caseRevision': 1,
      'modelRevision': 0,
      'reviewJson': null,
      'reviewSha256': null,
      'updatedAt': null,
      'updatedBy': null,
      'acknowledgedMutationId': null,
    },
  );
  void set(String? reviewJson, {Object? roomId}) {
    final old = state(roomId);
    values[_key(roomId)] = {
      ...old,
      'modelRevision': (old['modelRevision'] as int) + 1,
      'reviewJson': reviewJson,
      'reviewSha256': reviewJson == null
          ? null
          : sha256.convert(utf8.encode(reviewJson)).toString(),
      'updatedAt': '2026-10-24T18:00:00.000Z',
      'updatedBy': 'fictional-owner',
      'acknowledgedMutationId': null,
    };
  }

  Future<MatchingHttpResponse> handle(MatchingHttpRequest request) async {
    final body = http.requestJson(request), roomId = body['roomId'];
    if (request.endpoint.path.endsWith('read-scan-model')) {
      reads++;
      await readGate?.future;
      return http.jsonResponse(state(roomId));
    }
    writes.add(Map<String, Object?>.from(body));
    final prior = receipts[body['mutationId']];
    if (prior == null) {
      if (body['expectedModelRevision'] != state(roomId)['modelRevision']) {
        return http.jsonResponse({
          'schemaVersion': '3',
          'error': {
            'code': 'SCAN_MODEL_CONFLICT',
            'message': 'Fictional conflict',
          },
        }, status: 409);
      }
      receipts[body['mutationId'] as String] = jsonEncode(body);
      set(body['reviewJson'] as String?, roomId: roomId);
    } else {
      expect(jsonEncode(body), prior);
    }
    if (loseNext) {
      loseNext = false;
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    return http.jsonResponse({
      ...state(roomId),
      'acknowledgedMutationId': body['mutationId'],
    });
  }

  ScanModelApiClient api() => ScanModelApiClient(
    baseUri: Uri.parse('https://fictional.example'),
    tokenProvider: () async => 'fictional-token',
    transport: FakeTransport(handle),
  );
}

class SyncDevice {
  SyncDevice(
    this.server, {
    SyncStore? store,
    this.room,
    bool Function()? current,
  }) : store = store ?? SyncStore() {
    sync = ScanModelSync(
      api: server.api(),
      store: this.store,
      caseId: syncCaseId,
      room: room,
      storageKey: 'assessment:$syncCaseId:${room?.id ?? 'legacy'}',
      isCurrent: current ?? () => true,
      caseRevision: () => 1,
      localReview: () => review,
      applyReview: (value) async {
        await this.store.writeBytes(
          'model',
          Uint8List.fromList(
            utf8.encode(jsonEncode(value.toJson(syncCaseId, room: room))),
          ),
        );
        review = value;
      },
    );
  }
  final SyncServer server;
  final SyncStore store;
  final RoomInstance? room;
  BathroomScanReview review = BathroomScanReview();
  late final ScanModelSync sync;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'all shared fixtures retain native fingerprints, labels, review and camera estimates',
    () {
      for (var i = 0; i < scanSyncFixtures.length; i++) {
        final f = scanSyncFixtures[i],
            before = fixtureReview(i),
            state = ScanModelState.fromJson(
              f['response'],
              caseId: syncCaseId,
              room: i == 0 ? null : fixtureRoom(i),
            );
        expect(state.review!.scene!.fingerprint, before.scene!.fingerprint);
        expect(state.review!.reviewed, before.reviewed);
        expect(state.review!.labels, before.labels);
        expect(state.review!.scene!.measurements.length, i == 2 ? 1 : 0);
      }
    },
  );
  test(
    'a fresh second phone checks and explicitly restores without creating findings or sending writes',
    () async {
      final server = SyncServer(),
          first = SyncDevice(server)..review = fixtureReview();
      await first.sync.initialize();
      expect(server.writes, isEmpty);
      await first.sync.refresh();
      await first.sync.upload();
      final other = SyncDevice(server);
      await other.sync.initialize();
      await other.sync.refresh();
      expect(other.review.scene, isNull);
      expect(server.writes.length, 1);
      await other.sync.restore();
      expect(other.review.scene!.fingerprint, first.review.scene!.fingerprint);
      expect(other.sync.baseRevision, 1);
      expect(other.store.binary['model'], isNotNull);
      expect(server.writes.length, 1);
    },
  );
  test(
    'lost acknowledgement and restart retry the same encrypted request exactly once',
    () async {
      final server = SyncServer()..loseNext = true,
          store = SyncStore(),
          first = SyncDevice(server, store: store)..review = fixtureReview();
      await first.sync.initialize();
      await first.sync.refresh();
      await expectLater(
        first.sync.upload(),
        throwsA(isA<MatchingApiException>()),
      );
      expect(first.sync.pending, isNotNull);
      expect(server.state(null)['modelRevision'], 1);
      final restarted = SyncDevice(server, store: store)..review = first.review;
      await restarted.sync.initialize();
      expect(restarted.sync.pending, isNotNull);
      await restarted.sync.retry();
      expect(restarted.sync.pending, isNull);
      expect(server.writes[0], server.writes[1]);
      expect(server.state(null)['modelRevision'], 1);
    },
  );
  test(
    'newer remote model cannot overwrite local work without explicit replacement or restore',
    () async {
      final server = SyncServer(),
          first = SyncDevice(server)..review = fixtureReview();
      await first.sync.initialize();
      await first.sync.refresh();
      server.set(scanSyncFixtures[0]['request']['reviewJson'] as String);
      await expectLater(
        first.sync.upload(),
        throwsA(isA<MatchingApiException>()),
      );
      expect(first.sync.pending, isNotNull);
      expect(server.state(null)['modelRevision'], 1);
      await first.sync.discardRecovery();
      first.review = first.review.copyWith(reviewed: {});
      await first.sync.refresh();
      expect(first.sync.accountChanged, true);
      await expectLater(
        first.sync.upload(),
        throwsA(
          isA<MatchingApiException>().having(
            (e) => e.code,
            'code',
            'SCAN_MODEL_CONFLICT',
          ),
        ),
      );
      await first.sync.upload(replaceAccount: true);
      expect(server.state(null)['modelRevision'], 2);
    },
  );
  test(
    'account changes during restore retain the original local model',
    () async {
      final server = SyncServer(),
          device = SyncDevice(server)..review = fixtureReview();
      server.set(scanSyncFixtures[0]['request']['reviewJson'] as String);
      await device.sync.initialize();
      await device.sync.refresh();
      server.set(null);
      final fingerprint = device.review.scene!.fingerprint;
      await expectLater(
        device.sync.restore(),
        throwsA(isA<MatchingApiException>()),
      );
      expect(device.review.scene!.fingerprint, fingerprint);
      expect(device.sync.remote!.review, isNull);
    },
  );
  test(
    'failed journal write never sends; failed metadata acknowledgement retains exact retry',
    () async {
      final server = SyncServer(),
          store = SyncStore()..failPending = true,
          device = SyncDevice(server, store: store)..review = fixtureReview();
      await device.sync.initialize();
      await device.sync.refresh();
      await expectLater(device.sync.upload(), throwsStateError);
      expect(server.writes, isEmpty);
      store.failPending = false;
      store.failMetadata = true;
      await expectLater(device.sync.upload(), throwsStateError);
      expect(device.sync.pending, isNotNull);
      store.failMetadata = false;
      await device.sync.retry();
      expect(server.state(null)['modelRevision'], 1);
      expect(device.sync.pending, isNull);
    },
  );
  test(
    'room slots and local journals remain independent and account removal retains local geometry',
    () async {
      final server = SyncServer(),
          a = SyncDevice(server, room: fixtureRoom(1))
            ..review = fixtureReview(1),
          b = SyncDevice(server, room: fixtureRoom(2))
            ..review = fixtureReview(2);
      await a.sync.initialize();
      await b.sync.initialize();
      await a.sync.refresh();
      await b.sync.refresh();
      await a.sync.upload();
      await b.sync.upload();
      expect(
        server.state('room-1')['reviewJson'],
        isNot(server.state('room-2')['reviewJson']),
      );
      await a.sync.upload(removeAccount: true);
      expect(a.review.scene, isNotNull);
      expect(server.state('room-1')['reviewJson'], isNull);
      expect(server.state('room-2')['reviewJson'], isNotNull);
    },
  );
  test(
    'a response after account switch cannot replace device geometry',
    () async {
      var current = true;
      final server = SyncServer(),
          device = SyncDevice(server, current: () => current)
            ..review = fixtureReview();
      await device.sync.initialize();
      server.readGate = Completer<void>();
      final request = device.sync.refresh();
      await Future<void>.delayed(Duration.zero);
      current = false;
      server.readGate!.complete();
      await expectLater(
        request,
        throwsA(
          isA<MatchingApiException>().having(
            (e) => e.code,
            'code',
            'STALE_RESPONSE',
          ),
        ),
      );
      expect(device.sync.remote, isNull);
      expect(device.review.scene, isNotNull);
    },
  );
  test(
    'checking identical account content adopts its revision for later local edits',
    () async {
      final server = SyncServer()
        ..set(scanSyncFixtures[0]['request']['reviewJson'] as String);
      final device = SyncDevice(server)..review = fixtureReview();
      await device.sync.initialize();
      await device.sync.refresh();
      expect(device.sync.baseRevision, 1);
      expect(server.writes, isEmpty);
      device.review = device.review.copyWith(reviewed: {});
      expect(device.sync.accountChanged, false);
      await device.sync.upload();
      expect(server.writes.single['expectedModelRevision'], 1);
      expect(server.state(null)['modelRevision'], 2);
    },
  );
  test(
    'corrupt recovery blocks uploads while retaining device model and requires explicit reset',
    () async {
      final server = SyncServer(), store = SyncStore();
      final device = SyncDevice(server, store: store)..review = fixtureReview();
      final key = 'assessment:$syncCaseId:legacy:upload';
      store.binary[key] = Uint8List.fromList(utf8.encode('invalid'));
      await device.sync.initialize();
      expect(device.sync.corrupt, true);
      await device.sync.refresh();
      await expectLater(device.sync.upload(), throwsStateError);
      expect(store.binary[key], isNotNull);
      expect(device.review.scene, isNotNull);
      expect(server.writes, isEmpty);
      await device.sync.discardRecovery();
      expect(store.binary[key], isNull);
      expect(device.review.scene, isNotNull);
      expect(device.sync.remote, isNull);
    },
  );
  test(
    'an acknowledged retry does not adopt an unrelated newer account model as its base',
    () async {
      final server = SyncServer()..loseNext = true;
      final device = SyncDevice(server)..review = fixtureReview();
      await device.sync.initialize();
      await device.sync.refresh();
      await expectLater(
        device.sync.upload(),
        throwsA(isA<MatchingApiException>()),
      );
      server.set(null);
      await device.sync.retry();
      expect(device.sync.pending, isNull);
      expect(device.sync.baseRevision, 1);
      expect(device.sync.remote!.modelRevision, 2);
      expect(device.sync.accountChanged, true);
      expect(device.review.scene, isNotNull);
      await expectLater(
        device.sync.upload(),
        throwsA(isA<MatchingApiException>()),
      );
    },
  );
  test(
    'bad checksum and cross-room model responses are rejected before restore',
    () {
      final response = Map<String, dynamic>.from(
        scanSyncFixtures[0]['response'] as Map,
      );
      response['reviewSha256'] = '0' * 64;
      expect(
        () => ScanModelState.fromJson(response, caseId: syncCaseId),
        throwsFormatException,
      );
      expect(
        () => ScanModelState.fromJson(
          scanSyncFixtures[1]['response'],
          caseId: syncCaseId,
          room: fixtureRoom(2),
        ),
        throwsFormatException,
      );
    },
  );
}
