import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/case_coordinator.dart';
import 'package:safe_at_home/shared/services/case_discovery_api_client.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import '../services/case_evidence_api_client_test.dart' as http;
import 'local_private_store_test.dart' show MemorySecrets;

class FakeSession extends SessionService {
  String? owner = 'fictional-owner';
  int generation = 0;
  @override
  String? get userId => owner;
  @override
  int get epoch => generation;
  @override
  bool get recoveryRequired => false;
  @override
  Future<String?> accessToken() async => 'fictional-token';
  @override
  Future<void> signIn(String email, String password) async {}
  @override
  Future<void> reauthenticate(String password) async {}
  @override
  Future<void> requestRecovery(String email) async {}
  @override
  Future<void> updatePassword(String password) async {}
  @override
  Future<void> signOut() async {
    owner = null;
    generation++;
    notifyListeners();
  }
}

class FakeTransport implements MatchingTransport {
  FakeTransport(this.handler);
  final Future<MatchingHttpResponse> Function(MatchingHttpRequest) handler;
  final requests = <MatchingHttpRequest>[];
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    requests.add(request);
    return MatchingExchange(response: handler(request), cancel: () {});
  }
}

void main() {
  late Directory dir;
  late FakeSession session;
  late LocalPrivateStore store;
  CaseCoordinator? coordinator;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sah-case-test-');
    session = FakeSession();
    store = LocalPrivateStore(
      directory: dir,
      accountId: session.userId!,
      secrets: MemorySecrets(),
    );
  });
  tearDown(() async {
    coordinator?.dispose();
    session.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  CaseCoordinator make(FakeTransport transport) =>
      coordinator = CaseCoordinator(
        session: session,
        store: store,
        cases: http.clientFor(transport),
        discovery: CaseDiscoveryApiClient(
          listCasesEndpoint: Uri.parse('https://example.org/v1/list-cases'),
          caseEndpoint: Uri.parse('https://example.org/v1/read-case'),
          tokenProvider: session.accessToken,
          transport: transport,
        ),
      );
  test(
    'create assigns server revision and local restart restores exact case',
    () async {
      final c = make(
        FakeTransport(
          (request) async =>
              http.jsonResponse({...http.requestJson(request), 'revision': 1}),
        ),
      );
      await c.createDraft();
      final id = c.draft!.caseId;
      expect(c.snapshot, isNull);
      await c.save();
      expect(c.snapshot!.revision, 1);
      expect(c.hasUnsavedChanges, false);
      await c.restoreLocal(id);
      expect(c.draft!.caseId, id);
      expect(c.snapshot!.revision, 1);
    },
  );
  test(
    'uncertain successful create is reconciled without another write',
    () async {
      Map<String, Object?>? server;
      final transport = FakeTransport((request) async {
        if (request.endpoint.path == '/v1/create-case') {
          server = {...http.requestJson(request), 'revision': 1};
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return http.jsonResponse(server);
      });
      final c = make(transport);
      await c.createDraft();
      await expectLater(c.save(), throwsA(isA<MatchingApiException>()));
      expect(c.uncertain, true);
      await expectLater(c.save(), throwsStateError);
      await c.reconcile();
      expect(c.uncertain, false);
      expect(c.conflict, false);
      expect(c.snapshot!.revision, 1);
      expect(
        transport.requests
            .where((r) => r.endpoint.path == '/v1/create-case')
            .length,
        1,
      );
    },
  );
  test(
    'account switch rejects a late save and does not adopt its snapshot',
    () async {
      final ready = Completer<void>();
      final reply = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((request) {
        ready.complete();
        return reply.future;
      });
      final c = make(transport);
      await c.createDraft();
      final draft = c.draft!;
      final saving = c.save();
      final error = expectLater(saving, throwsA(isA<MatchingApiException>()));
      await ready.future;
      await session.signOut();
      reply.complete(http.jsonResponse(draft.atRevision(1).toJson()));
      await error;
      expect(c.snapshot, isNull);
    },
  );
  test(
    'editing during a lost save preserves local content for comparison',
    () async {
      final ready = Completer<void>();
      final reply = Completer<MatchingHttpResponse>();
      Map<String, Object?>? server;
      final c = make(
        FakeTransport((request) {
          if (request.endpoint.path == '/v1/create-case') {
            server = {...http.requestJson(request), 'revision': 1};
            ready.complete();
            return reply.future;
          }
          return Future.value(http.jsonResponse(server));
        }),
      );
      await c.createDraft();
      final save = c.save();
      final failed = expectLater(save, throwsA(isA<MatchingApiException>()));
      await ready.future;
      final json = c.draft!.toJson();
      json['profile'] = {
        ...c.draft!.profile.toJson(),
        'city': 'Changed fictional city',
      };
      await c.updateDraft(CaseDraft.fromJson(json));
      reply.complete(http.jsonResponse(server));
      await failed;
      await c.reconcile();
      expect(c.conflict, true);
      expect(c.draft!.profile.city, 'Changed fictional city');
      expect(c.snapshot!.profile.city, isNull);
    },
  );
  test(
    'queued mutations execute in order and failed operation does not poison queue',
    () async {
      final c = make(FakeTransport((_) async => throw StateError('unused')));
      await c.createDraft();
      final order = <int>[];
      final gate = Completer<void>();
      final first = c.serialize(() async {
        order.add(1);
        await gate.future;
        throw StateError('fictional');
      });
      final failure = expectLater(first, throwsStateError);
      final second = c.serialize(() async {
        order.add(2);
      });
      await Future<void>.delayed(Duration.zero);
      expect(order, [1]);
      gate.complete();
      await failure;
      await second;
      expect(order, [1, 2]);
    },
  );
}
