import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/shared/presentation/startup_error_screen.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/case_evidence_api_client_test.dart' as wire;
import 'case_coordinator_test.dart' show FakeTransport;
import 'session_reauthentication_test.dart'
    show ControlledAuth, ControlledClient, fictionalSession;

late String _namespace;
String get _sessionKey => '$_namespace.session';
const _verifierKey = 'supabase.auth.token-code-verifier';
String get _storedVerifier => '$_namespace.pkce.$_verifierKey';
const _receiptKey = 'sah.deletion.receipt.fictional';

class _SecureFiles {
  final values = <String, String>{};
  final rejectedDeletes = <String>{};
  final deletes = <String>[];
  Completer<void>? sessionDeleteGate;

  Future<Object?> handle(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final key = args['key'] as String;
    switch (call.method) {
      case 'read':
        return values[key];
      case 'write':
        values[key] = args['value'] as String;
        return null;
      case 'delete':
        deletes.add(key);
        if (key == _sessionKey) await sessionDeleteGate?.future;
        if (rejectedDeletes.contains(key)) {
          throw PlatformException(code: 'FICTIONAL_PRIVATE_KEYCHAIN_FAILURE');
        }
        values.remove(key);
        return null;
      default:
        throw StateError('Unexpected secure-storage fixture operation.');
    }
  }
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 3)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) return;
  }
  fail('The expected private-cleanup state did not settle.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const mediaChannel = MethodChannel('safe_at_home/private_media');
  late Directory root;
  late _SecureFiles secure;
  var rejectPrepare = true;
  var rejectTransientCleanup = false, transientClears = 0, prepares = 0;
  Completer<void>? transientRecoveryGate;
  late LiveAppConfig config;
  var scenario = 0;

  setUp(() async {
    final authHost = 'fictional-${++scenario}.supabase.co';
    _namespace = 'sah.auth.$authHost';
    config = LiveAppConfig(
      apiOrigin: Uri.parse('https://fictional.example'),
      supabaseUrl: Uri.parse('https://$authHost'),
      publishableKey: 'fictional-publishable-key',
    );
    root = await Directory.systemTemp.createTemp('sah-secure-cleanup-');
    secure = _SecureFiles();
    rejectPrepare = true;
    rejectTransientCleanup = false;
    transientClears = 0;
    prepares = 0;
    transientRecoveryGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, secure.handle);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaChannel, (call) async {
          if (call.method == 'privateRootDirectory') return root.path;
          if (call.method == 'preparePrivateDirectory') {
            prepares++;
            if (rejectPrepare) {
              throw PlatformException(code: 'FICTIONAL_PRIVATE_FILES_LOCKED');
            }
          }
          if (call.method == 'clearTemporaryMedia') {
            transientClears++;
            if (transientClears == 4) await transientRecoveryGate?.future;
            if (rejectTransientCleanup) {
              throw PlatformException(code: 'FICTIONAL_PRIVATE_MEDIA_FAILURE');
            }
          }
          return null;
        });
    secure.values[_sessionKey] = jsonEncode(
      fictionalSession('fictional-owner', 'fictional-token').toJson(),
    );
    secure.values[_receiptKey] = 'fictional-retained-deletion-receipt';
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaChannel, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> host(WidgetTester tester, SessionService session) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      LiveSessionHost(
        config: config,
        session: session,
        transport: FakeTransport((request) async {
          expect(request.endpoint.path, '/v2/list-cases');
          return wire.jsonResponse({
            'schemaVersion': '2',
            'cases': [],
            'nextAfterCaseId': null,
          });
        }),
      ),
    );
    await _until(
      tester,
      () => find
          .byType(rejectPrepare ? StartupErrorScreen : CaseHomeScreen)
          .evaluate()
          .isNotEmpty,
    );
  }

  testWidgets(
    'actual SDK PKCE failure after owner invalidation retains a guarded retry',
    (tester) async {
      final pkce = SecurePkceStorage(DeviceSecretStore(), _namespace);
      await pkce.setItem(key: _verifierKey, value: 'fictional-verifier');
      final client = (await tester.runAsync(
        () async => SupabaseClient(
          config.supabaseUrl.toString(),
          config.publishableKey,
          authOptions: AuthClientOptions(
            autoRefreshToken: false,
            authFlowType: AuthFlowType.pkce,
            pkceAsyncStorage: pkce,
          ),
        ),
      ))!;
      await client.auth.setInitialSession(secure.values[_sessionKey]!);
      var signedOutEvents = 0;
      final events = client.auth.onAuthStateChange.listen((change) {
        if (change.event == AuthChangeEvent.signedOut) signedOutEvents++;
      });
      final session = SupabaseSessionService(
        client,
        callback: config.callback,
        emailDeliveryEnabled: true,
        reauthenticationClient: () => throw StateError('Unused verifier.'),
      );
      final retained = File('${root.path}/retained-fictional.enc')
        ..writeAsBytesSync([91, 42, 8, 19]);
      secure.rejectedDeletes.addAll([_sessionKey, _storedVerifier]);
      await host(tester, session);
      final exit = tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('startup-sign-out')),
          )
          .onPressed!;
      exit();
      final queuedLogin = expectLater(
        session.signIn('replacement@example.invalid', 'fictional-password'),
        throwsStateError,
      );
      await _until(
        tester,
        () => session.cleanupRequired && !session.cleaningUp,
      );
      await queuedLogin;
      expect(client.auth.currentSession, isNull);
      expect(session.userId, isNull);
      expect(signedOutEvents, 0);
      expect(secure.deletes, containsAll([_sessionKey, _storedVerifier]));
      expect(secure.values[_sessionKey], isNotNull);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.text('Finish private cleanup'), findsOneWidget);
      expect(find.textContaining('FICTIONAL_PRIVATE'), findsNothing);
      expect(await session.accessToken(), isNull);
      expect(retained.readAsBytesSync(), [91, 42, 8, 19]);
      expect(secure.values[_receiptKey], 'fictional-retained-deletion-receipt');
      await expectLater(
        session.requestRecovery('replacement@example.invalid'),
        throwsStateError,
      );
      final retry = tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('startup-retry-cleanup')),
          )
          .onPressed!;
      retry();
      await _until(tester, () => !session.cleaningUp);
      expect(session.cleanupRequired, true);
      expect(find.byType(LoginScreen), findsNothing);
      secure.rejectedDeletes.clear();
      retry();
      await _until(
        tester,
        () => find.byType(LoginScreen).evaluate().isNotEmpty,
      );
      expect(session.cleanupRequired, false);
      expect(secure.values.containsKey(_sessionKey), false);
      expect(secure.values.containsKey(_storedVerifier), false);
      expect(retained.readAsBytesSync(), [91, 42, 8, 19]);
      secure.values[_sessionKey] = 'fictional-new-session';
      retry();
      await tester.pump();
      expect(secure.values[_sessionKey], 'fictional-new-session');
      expect(secure.values[_receiptKey], 'fictional-retained-deletion-receipt');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await events.cancel();
        await client.dispose();
      });
    },
  );

  testWidgets(
    'normal sign-out failure blocks login until its exact local cleanup finishes',
    (tester) async {
      rejectPrepare = false;
      final auth = ControlledAuth(
        session: fictionalSession('fictional-owner', 'fictional-token'),
      );
      final client = (await tester.runAsync(
        () async => ControlledClient(auth),
      ))!;
      final session = SupabaseSessionService(
        client,
        callback: config.callback,
        emailDeliveryEnabled: true,
        reauthenticationClient: () => throw StateError('Unused verifier.'),
      );
      await host(tester, session);
      final services = tester
          .widget<CaseHomeScreen>(find.byType(CaseHomeScreen))
          .services;
      var saved = false;
      final writing = services.store
          .writeJson('case.original', {'fictional': true})
          .then((_) => saved = true);
      await _until(tester, () => saved);
      await writing;
      secure.rejectedDeletes.add(_sessionKey);
      rejectTransientCleanup = true;
      final failed = expectLater(
        services.signOut(),
        throwsA(isA<PlatformException>()),
      );
      await _until(
        tester,
        () => session.cleanupRequired && !session.cleaningUp,
      );
      await failed;
      await _until(tester, () => transientClears == 2);
      expect(session.userId, isNull);
      expect(find.byType(LoginScreen), findsNothing);
      expect(secure.values.containsKey(_sessionKey), true);
      expect(await tester.runAsync(services.store.directory.exists), false);
      expect(
        secure.values.keys.any((key) => key.startsWith('sah.v1.account.')),
        false,
      );
      expect(secure.values[_receiptKey], 'fictional-retained-deletion-receipt');
      final revision = session.cleanupRevision;
      secure.rejectedDeletes.clear();
      rejectTransientCleanup = false;
      transientRecoveryGate = Completer<void>();
      secure.sessionDeleteGate = Completer<void>();
      final retry = session.retryAccountCleanup(expectedRevision: revision);
      auth.pending = Completer<AuthResponse>();
      final login = session.signIn(
        'replacement@example.invalid',
        'fictional-password',
      );
      await tester.pump();
      expect(session.cleaningUp, true);
      expect(auth.passwordCalls, 0);
      secure.sessionDeleteGate!.complete();
      await _until(tester, () => auth.passwordCalls == 1);
      await retry;
      auth.pending!.complete(
        AuthResponse(
          session: fictionalSession('replacement', 'fresh-fictional-token'),
        ),
      );
      await login;
      await _until(tester, () => transientClears == 4);
      expect(prepares, 1);
      expect(find.byType(CaseHomeScreen), findsNothing);
      transientRecoveryGate!.complete();
      await _until(
        tester,
        () => find.byType(CaseHomeScreen).evaluate().isNotEmpty,
      );
      expect(prepares, 2);
      expect(
        tester
            .widget<CaseHomeScreen>(find.byType(CaseHomeScreen))
            .services
            .store
            .accountId,
        'replacement',
      );
      secure.values[_sessionKey] = 'fresh-fictional-persisted-session';
      await expectLater(
        session.retryAccountCleanup(expectedRevision: revision),
        throwsStateError,
      );
      expect(secure.values[_sessionKey], 'fresh-fictional-persisted-session');
      expect(session.cleanupRequired, false);
      expect(secure.values[_receiptKey], 'fictional-retained-deletion-receipt');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.dispose);
      auth.dispose();
    },
  );
}
