import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/shared/models/account_plan_name.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/plan_name_sync.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../case_discovery_api_client_test.dart'
    show FakeTransport, jsonResponse, requestJson;
import 'live_workflows_test.dart' show MemoryPrivateStore;
import 'session_reauthentication_test.dart'
    show ControlledAuth, ControlledClient, fictionalSession;

const _namespace = 'sah.auth.fictional.supabase.co';

class _Auth extends ControlledAuth {
  _Auth()
    : super(session: fictionalSession('fictional-owner', 'original-token'));
  int logoutCalls = 0;

  @override
  Future<void> signOut({SignOutScope scope = SignOutScope.local}) async {
    logoutCalls++;
    await super.signOut(scope: scope);
  }
}

class _Store extends MemoryPrivateStore {
  String? gatedPrefix;
  Completer<void>? writeGate;
  final writeEntered = Completer<void>();
  Completer<void>? clearGate;
  final clearEntered = Completer<void>();
  int clearCalls = 0;

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (writeGate != null && key.startsWith(gatedPrefix!)) {
      final gate = writeGate!;
      writeGate = null;
      writeEntered.complete();
      await gate.future;
    }
    await super.writeJson(key, value);
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    clearEntered.complete();
    await clearGate?.future;
    records.clear();
  }
}

class _NamesServer {
  final names = <String, AccountPlanName>{};
  bool offline = false;

  Future<MatchingHttpResponse> call(MatchingHttpRequest request) async {
    if (offline) {
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    final body = requestJson(request);
    final id = body['caseId'] as String;
    final current = names[id] ?? AccountPlanName.initial(id);
    switch (request.endpoint.path) {
      case '/v2/read-plan-name':
        return jsonResponse(current.toJson());
      case '/v2/save-plan-name':
        final mutation = PlanNameSaveRequest.fromJson(body);
        expect(mutation.expectedNameRevision, current.nameRevision);
        final next = AccountPlanName(
          caseId: id,
          name: mutation.name,
          nameRevision: current.nameRevision + 1,
          lastMutationId: mutation.mutationId,
        );
        names[id] = next;
        return jsonResponse(next.toJson());
      default:
        throw StateError(
          'Unexpected fictional route: ${request.endpoint.path}',
        );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const media = MethodChannel('safe_at_home/private_media');
  late Directory directory;
  late _Auth auth;
  late ControlledClient client;
  late SupabaseSessionService session;
  late _Store store;
  late _NamesServer server;
  late FakeTransport transport;
  late AppServices app;
  var nativeCalls = 0;

  Future<void> drain() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> expectAccountPreserved() async {
    expect(auth.logoutCalls, 0);
    expect(store.clearCalls, 0);
    expect(nativeCalls, 0);
    expect(session.userId, 'fictional-owner');
    expect(session.cleaningUp, false);
    expect(session.cleanupRequired, false);
    expect(await session.accessToken(), 'original-token');
    expect(
      await SecureSessionStorage(DeviceSecretStore(), _namespace).accessToken(),
      'original-persisted-token',
    );
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      '$_namespace.session': 'original-persisted-token',
    });
    directory = await Directory.systemTemp.createTemp('sah-name-signout-');
    nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(media, (call) async {
          if (call.method == 'clearTemporaryMedia') nativeCalls++;
          if (call.method == 'privateRootDirectory') return directory.path;
          return null;
        });
    auth = _Auth();
    client = ControlledClient(auth);
    session = SupabaseSessionService(
      client,
      callback: Uri.parse('safeathome://auth/callback'),
      emailDeliveryEnabled: false,
      reauthenticationClient: () => ControlledAuth(),
    );
    store = _Store();
    server = _NamesServer();
    transport = FakeTransport(server.call);
    app = AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://fictional.example'),
        supabaseUrl: Uri.parse('https://fictional.supabase.co'),
        publishableKey: 'fictional',
      ),
      session: session,
      store: store,
      transport: transport,
    );
  });

  tearDown(() async {
    app.dispose();
    session.dispose();
    await client.dispose();
    auth.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(media, null);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'pending name aborts AppServices cleanup without losing auth or work',
    () async {
      await app.coordinator.createDraft();
      final id = app.coordinator.draft!.caseId;
      server.offline = true;
      await app.coordinator.savePlanName(id, 'Offline home');
      expect(app.coordinator.nameSync!.pendingFor(id), true);
      final before = jsonDecode(jsonEncode(store.records));
      final requestCount = transport.requests.length;

      final rejected = expectLater(app.signOut(), throwsStateError);
      expect(session.cleaningUp, true);
      expect(await session.accessToken(), isNull);
      await rejected;

      await expectAccountPreserved();
      expect(store.records, before);
      expect(app.coordinator.nameSync!.nameFor(id), 'Offline home');
      expect(app.coordinator.nameSync!.pendingFor(id), true);
      expect(transport.requests, hasLength(requestCount));
      server.offline = false;
      await app.coordinator.nameSync!.refresh(id);
      expect(app.coordinator.nameSync!.pendingFor(id), false);
      await app.signOut();
      expect(store.records, isEmpty);
      expect(auth.logoutCalls, 1);
    },
  );

  test(
    'synced name allows logout and holds new sign-in until cleanup ends',
    () async {
      await app.coordinator.createDraft();
      final id = app.coordinator.draft!.caseId;
      await app.coordinator.savePlanName(id, 'Account home');
      expect(app.coordinator.nameSync!.pendingFor(id), false);
      expect(server.names[id]!.name, 'Account home');
      final requestCount = transport.requests.length;
      store.clearGate = Completer<void>();
      auth.pending = Completer<AuthResponse>();

      final signingOut = app.signOut();
      expect(session.cleaningUp, true);
      final signingIn = session.signIn(
        'fictional-owner@example.invalid',
        'fictional',
      );
      await store.clearEntered.future.timeout(const Duration(seconds: 3));
      await drain();
      expect(auth.logoutCalls, 1);
      expect(auth.passwordCalls, 0);
      expect(store.records, isNotEmpty);
      expect(nativeCalls, 0);
      store.clearGate!.complete();
      await signingOut;
      expect(store.records, isEmpty);
      expect(nativeCalls, 1);
      expect(transport.requests, hasLength(requestCount));
      expect(
        await SecureSessionStorage(
          DeviceSecretStore(),
          _namespace,
        ).accessToken(),
        isNull,
      );

      auth.pending!.complete(
        AuthResponse(session: fictionalSession('fictional-owner', 'new-token')),
      );
      await signingIn;
      expect(session.userId, 'fictional-owner');
      expect(await session.accessToken(), 'new-token');
      expect(session.cleaningUp, false);
      expect(store.clearCalls, 1);
      expect(server.names[id]!.name, 'Account home');
    },
  );

  test(
    'in-flight named creation aborts sign-out before local work is erased',
    () async {
      final gate = Completer<void>();
      store.gatedPrefix = 'case.';
      store.writeGate = gate;
      final creating = app.coordinator.createDraft(name: 'New home');
      await store.writeEntered.future.timeout(const Duration(seconds: 3));
      final id = app.coordinator.draft!.caseId;
      expect(app.coordinator.localWritePending, true);

      await expectLater(app.signOut(), throwsStateError);
      await expectAccountPreserved();
      gate.complete();
      await creating;

      expect(app.coordinator.localWritePending, false);
      expect(store.records['case.$id'], isNotNull);
      final reopenedNames = PlanNameSync(
        store: store,
        api: app.planNames,
        isCurrent: () => session.userId == store.accountId,
        changed: () {},
      );
      expect(await reopenedNames.load(id), 'New home');
      expect(reopenedNames.pendingFor(id), true);
      expect(app.coordinator.planNameFor(id), 'New home');
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'sign-out drains an in-flight rename and preserves its pending journal',
    () async {
      await app.coordinator.createDraft();
      final id = app.coordinator.draft!.caseId;
      final gate = Completer<void>();
      store.gatedPrefix = 'plan-name-sync.';
      store.writeGate = gate;
      final renaming = app.coordinator.savePlanName(id, 'Name being saved');
      await store.writeEntered.future.timeout(const Duration(seconds: 3));

      final rejected = expectLater(app.signOut(), throwsStateError);
      expect(session.cleaningUp, true);
      await drain();
      expect(store.clearCalls, 0);
      await expectLater(
        app.coordinator.createDraft(name: 'Too late'),
        throwsStateError,
      );
      await expectLater(
        app.coordinator.savePlanName(id, 'Too late'),
        throwsStateError,
      );
      gate.complete();
      await renaming;
      await rejected;

      await expectAccountPreserved();
      expect(app.coordinator.nameSync!.nameFor(id), 'Name being saved');
      expect(app.coordinator.nameSync!.pendingFor(id), true);
      final saved = store.records[PlanNameSync.storageKey(id)]!;
      expect((saved['pending'] as Map)['name'], 'Name being saved');
      expect(store.records['case.$id'], isNotNull);
      expect(app.coordinator.draft!.caseId, id);
      expect(transport.requests, isEmpty);
    },
  );
}
