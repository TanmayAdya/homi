import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:safe_at_home/shared/services/session_service.dart';

import 'local_private_store_test.dart' show MemorySecrets;

class _LoopbackHttp extends HttpOverrides {}

class _DelayedSecrets extends MemorySecrets {
  _DelayedSecrets(this.sessionKey);
  final String sessionKey;
  final recoveryProbe = Completer<void>();
  final releaseProbe = Completer<void>();
  final recoveryRead = Completer<void>();
  final releaseRead = Completer<void>();
  int sessionReads = 0;

  @override
  Future<String?> read(String key) async {
    final captured = await super.read(key);
    if (key == sessionKey) {
      sessionReads++;
      if (sessionReads == 3) {
        recoveryProbe.complete();
        await releaseProbe.future;
      } else if (sessionReads == 4) {
        recoveryRead.complete();
        await releaseRead.future;
      }
    }
    return captured;
  }

  void release() {
    if (!releaseProbe.isCompleted) releaseProbe.complete();
    if (!releaseRead.isCompleted) releaseRead.complete();
  }
}

class _ObservedPkceStorage extends SecurePkceStorage {
  _ObservedPkceStorage(super.secrets, super.namespace);
  final removalRequested = Completer<void>();

  @override
  Future<void> removeItem({required String key}) {
    if (!removalRequested.isCompleted) removalRequested.complete();
    return super.removeItem(key: key);
  }
}

String _encoded(Object value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

Map<String, Object?> _session(String owner, String marker) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final token =
      '${_encoded({'alg': 'none', 'typ': 'JWT'})}.'
      '${_encoded({'sub': owner, 'iat': now, 'exp': now + 3600, 'fixture': marker})}.'
      'fictional-signature';
  return {
    'access_token': token,
    'refresh_token': 'fictional-refresh-$marker',
    'expires_in': 3600,
    'token_type': 'bearer',
    'user': {
      'id': owner,
      'aud': 'authenticated',
      'email': '$owner@example.invalid',
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
      'created_at': '2026-01-01T00:00:00Z',
    },
  };
}

Future<void> _drainEvents() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final sameOwner in [false, true]) {
    test(
      'PKCE adoption follows delayed boot recovery (${sameOwner ? 'same' : 'different'} owner)',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final old = _session('fictional-original', 'cached');
        final recovered = _session(
          sameOwner ? 'fictional-original' : 'fictional-recovered',
          'callback',
        );
        final namespace = 'fictional-bootstrap-$sameOwner';
        final secrets = _DelayedSecrets('$namespace.session');
        secrets.values['$namespace.session'] = jsonEncode(old);
        final storage = SecureSessionStorage(secrets, namespace);
        final pkce = _ObservedPkceStorage(secrets, namespace);
        final verifier = 'fictional-verifier-${'x' * 48}';
        await pkce.setItem(
          key: 'supabase.auth.token-code-verifier',
          value: '$verifier/passwordRecovery',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final unexpectedRequests = <String>[];
        var requests = 0;
        server.listen((request) async {
          try {
            if (++requests > 1 ||
                request.method != 'POST' ||
                request.uri.path != '/auth/v1/token' ||
                request.uri.queryParameters['grant_type'] != 'pkce') {
              throw const FormatException('Unexpected fixture request.');
            }
            final bytes = <int>[];
            await for (final chunk in request) {
              if (bytes.length + chunk.length > 8192) {
                throw const FormatException('Fixture body too large.');
              }
              bytes.addAll(chunk);
            }
            final body = jsonDecode(utf8.decode(bytes)) as Map;
            if (body['auth_code'] != 'fictional-code' ||
                body['code_verifier'] != verifier) {
              throw const FormatException('Unexpected fictional exchange.');
            }
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(recovered));
          } catch (_) {
            unexpectedRequests.add('Unexpected fictional provider request.');
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"msg":"Invalid fixture request"}');
          } finally {
            await request.response.close();
          }
        });
        Supabase? supabase;
        SupabaseSessionService? service;
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
          await secrets.recoveryProbe.future;
          final client = supabase.client;
          service = SupabaseSessionService(
            client,
            callback: Uri.parse('safeathome://auth/callback'),
            emailDeliveryEnabled: true,
            reauthenticationClient: () => throw StateError(
              'This test must not request reauthentication.',
            ),
          );
          expect(service.userId, 'fictional-original');
          var callbackCompleted = false;
          final callback = service
              .handleCallback(
                Uri.parse('safeathome://auth/callback?code=fictional-code'),
              )
              .then((_) => callbackCompleted = true);
          await _drainEvents();

          secrets.releaseProbe.complete();
          await secrets.recoveryRead.future;
          await pkce.removalRequested.future;
          await _drainEvents();
          expect(requests, 1);
          expect(unexpectedRequests, isEmpty);
          expect(callbackCompleted, false);
          expect(client.auth.currentSession?.accessToken, old['access_token']);

          secrets.releaseRead.complete();
          await callback;
          await _drainEvents();
          expect(service.callbackNotice, isNull);
          expect(service.recoveryRequired, true);
          expect(
            client.auth.currentSession?.accessToken,
            recovered['access_token'],
          );
          expect(await service.accessToken(), recovered['access_token']);
          expect(
            (jsonDecode((await storage.accessToken())!) as Map)['access_token'],
            recovered['access_token'],
          );
          expect(secrets.sessionReads, greaterThanOrEqualTo(4));
          expect(
            secrets.values.keys.any((key) => key.contains('.pkce.')),
            false,
          );
        } finally {
          secrets.release();
          await _drainEvents();
          service?.dispose();
          await supabase?.dispose();
          await server.close(force: true);
        }
      }, _LoopbackHttp()),
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }
}
