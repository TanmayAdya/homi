import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_private_store_test.dart' show MemorySecrets;
import 'session_reauthentication_test.dart' show fictionalSession;

class _LoopbackHttp extends HttpOverrides {}

class _DelayedRecoverySecrets extends MemorySecrets {
  _DelayedRecoverySecrets(this.namespace, this.heldRead);
  final String namespace;
  final int heldRead;
  final recoveryRead = Completer<void>();
  final release = Completer<void>();
  var reads = 0;

  @override
  Future<String?> read(String key) async {
    final captured = await super.read(key);
    if (key == '$namespace.session' && ++reads == heldRead) {
      recoveryRead.complete();
      await release.future;
    }
    return captured;
  }
}

class _ObservedPkce extends SecurePkceStorage {
  _ObservedPkce(super.secrets, super.namespace);
  final removal = Completer<void>();

  @override
  Future<void> removeItem({required String key}) {
    if (!removal.isCompleted) removal.complete();
    return super.removeItem(key: key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final expired in [false, true]) {
    for (final heldRead in [3, 4]) {
      test(
        'logout rejects ${expired ? 'expired' : 'valid'} background SDK recovery at read $heldRead and permits a fresh login',
        () => HttpOverrides.runWithHttpOverrides(() async {
          final namespace = 'fictional-signout-order-$expired-$heldRead';
          final secrets = _DelayedRecoverySecrets(namespace, heldRead);
          final original = fictionalSession(
            'fictional-original',
            'fictional-token',
          );
          if (expired) {
            original.expiresAt =
                DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
          }
          secrets.values['$namespace.session'] = jsonEncode(original.toJson());
          final storage = SecureSessionStorage(secrets, namespace);
          final pkce = _ObservedPkce(secrets, namespace);
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          var requests = 0;
          final unexpected = <String>[];
          server.listen((request) async {
            requests++;
            if (requests == 1 &&
                request.method == 'POST' &&
                request.uri.path == '/auth/v1/logout') {
              request.response.statusCode = 204;
            } else if (requests == 2 &&
                request.method == 'POST' &&
                request.uri.path == '/auth/v1/token' &&
                request.uri.queryParameters['grant_type'] == 'password') {
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode(
                  fictionalSession(
                    'fictional-fresh',
                    'fictional-fresh-token',
                  ).toJson(),
                ),
              );
            } else {
              unexpected.add('Unexpected fictional provider request.');
              request.response.statusCode = 400;
            }
            await request.response.close();
          });
          Supabase? supabase;
          SupabaseSessionService? service;
          Future<void>? activeLogout;
          try {
            supabase = await Supabase.initialize(
              url: 'http://127.0.0.1:${server.port}',
              publishableKey: 'fictional-publishable-key',
              debug: false,
              authOptions: FlutterAuthClientOptions(
                autoRefreshToken: false,
                detectSessionInUri: false,
                localStorage: storage,
                pkceAsyncStorage: pkce,
              ),
            );
            await secrets.recoveryRead.future;
            service = SupabaseSessionService(
              supabase.client,
              callback: Uri.parse('safeathome://auth/callback'),
              emailDeliveryEnabled: true,
              persistedSessionStorage: storage,
              reauthenticationClient: () =>
                  throw StateError('Unused verifier.'),
            );
            expect(service.userId, 'fictional-original');
            final logout = activeLogout = service.signOutAndClear(() async {
              await storage.removePersistedSession();
              await pkce.clear();
            });
            await pkce.removal.future;
            expect(supabase.client.auth.currentSession, isNull);
            expect(service.cleaningUp, true);
            expect(await service.accessToken(), isNull);
            secrets.release.complete();
            await logout;
            for (var i = 0; i < 10; i++) {
              await Future<void>.delayed(Duration.zero);
            }
            expect(unexpected, isEmpty);
            expect(requests, 1);
            expect(service.userId, isNull);
            expect(supabase.client.auth.currentSession, isNull);
            expect(await service.accessToken(), isNull);
            expect(secrets.values.containsKey('$namespace.session'), false);
            expect(await storage.accessToken(), isNull);
            expect(secrets.reads, heldRead);

            await service.signIn('fresh@example.invalid', 'fictional-password');
            for (var i = 0; i < 10; i++) {
              await Future<void>.delayed(Duration.zero);
            }
            expect(service.userId, 'fictional-fresh');
            expect(await service.accessToken(), 'fictional-fresh-token');
            expect(requests, 2);
            expect(unexpected, isEmpty);
            final freshAdapter = SecureSessionStorage(secrets, namespace);
            final persisted = await freshAdapter.accessToken();
            expect(persisted, isNotNull);
            expect(
              (jsonDecode(persisted!) as Map)['user']['id'],
              'fictional-fresh',
            );
            expect(await storage.accessToken(), isNull);
            await pkce.setItem(
              key: 'fresh-verifier',
              value: 'fictional-new-verifier',
            );
            expect(
              await pkce.getItem(key: 'fresh-verifier'),
              'fictional-new-verifier',
            );
            await freshAdapter.removePersistedSession();
            await pkce.clear();
            expect(secrets.values, isEmpty);
          } finally {
            if (!secrets.release.isCompleted) secrets.release.complete();
            if (activeLogout != null) {
              await activeLogout.catchError((Object _) {});
            }
            service?.dispose();
            await supabase?.dispose();
            await server.close(force: true);
          }
        }, _LoopbackHttp()),
        timeout: const Timeout(Duration(seconds: 20)),
      );
    }
  }
}
