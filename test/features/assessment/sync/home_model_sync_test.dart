import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/home_model_sync.dart';
import 'package:safe_at_home/shared/models/home_model_sync.dart';
import 'package:safe_at_home/shared/services/scan_model_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../../app/case_coordinator_test.dart' show FakeTransport;
import '../../../services/case_evidence_api_client_test.dart' as http;
import 'scan_model_sync_test.dart' show SyncStore;

const homeSyncCase = '11111111-0000-4000-8000-000000000001';
final homeFixtures =
    (jsonDecode(
              File(
                'contracts/v3/fixtures/home-model-sync.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map<String, dynamic>>();
HomeModelBundle portableHome([int i = 0]) => HomeModelBundle.decode(
  homeFixtures[i]['request']['bundleJson'] as String,
  homeSyncCase,
);

class HomeSyncServer {
  int revision = 0;
  String? json;
  bool loseNext = false;
  Completer<void>? readGate;
  final writes = <Map<String, Object?>>[], receipts = <String, String>{};
  Map<String, Object?> state([String? ack]) => {
    'schemaVersion': '3',
    'caseId': homeSyncCase,
    'caseRevision': 1,
    'modelRevision': revision,
    'bundleJson': json,
    'bundleSha256': json == null
        ? null
        : sha256.convert(utf8.encode(json!)).toString(),
    'updatedAt': revision == 0 ? null : '2026-10-25T18:00:00.000Z',
    'updatedBy': revision == 0 ? null : 'alice',
    'acknowledgedMutationId': ack,
  };
  void set(String? value) {
    json = value;
    revision++;
  }

  Future<MatchingHttpResponse> handle(MatchingHttpRequest request) async {
    final body = http.requestJson(request);
    expect(request.maxResponseBytes, homeSyncMaxBytes);
    if (request.endpoint.path.endsWith('read-home-model')) {
      await readGate?.future;
      return http.jsonResponse(state());
    }
    expect(request.endpoint.path, '/v3/save-home-model');
    writes.add(body);
    final id = body['mutationId'] as String;
    if (receipts[id] == null) {
      if (body['expectedModelRevision'] != revision) {
        return http.jsonResponse({
          'schemaVersion': '3',
          'error': {'code': 'SCAN_MODEL_CONFLICT', 'message': 'Conflict'},
        }, status: 409);
      }
      receipts[id] = jsonEncode(body);
      set(body['bundleJson'] as String?);
    } else {
      expect(jsonEncode(body), receipts[id]);
    }
    if (loseNext) {
      loseNext = false;
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    return http.jsonResponse(state(id));
  }

  ScanModelApiClient api() => ScanModelApiClient(
    baseUri: Uri.parse('https://fictional.example'),
    tokenProvider: () async => 'fictional-token',
    transport: FakeTransport(handle),
  );
}

class HomeDevice {
  HomeDevice(this.server, {SyncStore? store, bool Function()? current})
    : store = store ?? SyncStore() {
    sync = HomeModelSync(
      api: server.api(),
      store: this.store,
      caseId: homeSyncCase,
      storageKey: 'assessment:$homeSyncCase:whole-home',
      isCurrent: current ?? () => true,
      caseRevision: () => 1,
      localBundle: () => bundle,
      applyBundle: (value) async {
        bundle = value;
      },
    );
  }
  final HomeSyncServer server;
  final SyncStore store;
  HomeModelBundle? bundle;
  late final HomeModelSync sync;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('portable fixtures preserve fingerprints for every native mode', () {
    for (var i = 0; i < homeFixtures.length; i++) {
      final b = portableHome(i);
      expect(
        HomeModelBundle.decode(
          b.encode(),
          homeSyncCase,
        ).model.toJson(homeSyncCase),
        b.model.toJson(homeSyncCase),
      );
      expect(b.model.resolve(b.sources, b.roomTypes.keys.toSet()).length, 2);
    }
  });
  test(
    'second device explicitly restores complete account snapshot with no extra write',
    () async {
      final server = HomeSyncServer(), first = HomeDevice(HomeSyncServer());
      final a = HomeDevice(server)..bundle = portableHome();
      await a.sync.initialize();
      await a.sync.refresh();
      await a.sync.upload();
      final b = HomeDevice(server);
      await b.sync.initialize();
      await b.sync.refresh();
      expect(b.bundle, isNull);
      await b.sync.restore();
      expect(b.bundle!.encode(), a.bundle!.encode());
      expect(server.writes.length, 1);
      first.sync.dispose();
      a.sync.dispose();
      b.sync.dispose();
    },
  );
  test(
    'lost successful response survives restart and exact retry cannot overwrite newer account model',
    () async {
      final server = HomeSyncServer()..loseNext = true,
          store = SyncStore(),
          a = HomeDevice(server, store: store)..bundle = portableHome();
      await a.sync.initialize();
      await a.sync.refresh();
      await expectLater(a.sync.upload(), throwsA(isA<MatchingApiException>()));
      final sent = Map.of(a.sync.pending!);
      a.sync.dispose();
      server.set(null);
      final b = HomeDevice(server, store: store)..bundle = portableHome();
      await b.sync.initialize();
      expect(b.sync.pending, sent);
      await b.sync.retry();
      expect(server.writes[0], server.writes[1]);
      expect(server.json, isNull);
      expect(b.bundle, isNotNull);
      expect(b.sync.remote!.modelRevision, 2);
      expect(b.sync.pending, isNull);
      b.sync.dispose();
    },
  );
  test(
    'concurrent account replacement requires explicit consent; stale restore preserves device',
    () async {
      final s = HomeSyncServer()..set(portableHome().encode()),
          d = HomeDevice(s)..bundle = portableHome(1);
      await d.sync.initialize();
      await d.sync.refresh();
      expect(d.sync.accountChanged, isTrue);
      await expectLater(d.sync.upload(), throwsA(isA<MatchingApiException>()));
      s.set(null);
      final before = d.bundle;
      await expectLater(d.sync.restore(), throwsA(isA<MatchingApiException>()));
      expect(d.bundle, same(before));
      d.sync.dispose();
    },
  );
  test(
    'account switch rejects delayed responses and disk failure prevents transmission',
    () async {
      var current = true;
      final s = HomeSyncServer()..readGate = Completer<void>(),
          d = HomeDevice(s, current: () => current)..bundle = portableHome();
      await d.sync.initialize();
      final read = d.sync.refresh();
      current = false;
      s.readGate!.complete();
      await expectLater(read, throwsA(isA<MatchingApiException>()));
      expect(d.sync.remote, isNull);
      d.sync.dispose();
      final store = SyncStore()..failPending = true,
          a = HomeDevice(s, store: store)..bundle = portableHome();
      await a.sync.initialize();
      await a.sync.refresh();
      await expectLater(a.sync.upload(), throwsStateError);
      expect(s.writes, isEmpty);
      a.sync.dispose();
    },
  );
  test('bad bundle scope and source fingerprint are rejected', () {
    final raw = jsonDecode(portableHome().encode()) as Map;
    raw['caseId'] = 'wrong';
    expect(
      () => HomeModelBundle.decode(jsonEncode(raw), homeSyncCase),
      throwsFormatException,
    );
    raw['caseId'] = homeSyncCase;
    final sources = raw['sources'] as Map;
    sources['room-2'] = sources['room-1'];
    expect(
      () => HomeModelBundle.decode(jsonEncode(raw), homeSyncCase),
      throwsFormatException,
    );
  });
}
