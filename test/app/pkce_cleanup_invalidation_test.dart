import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:safe_at_home/shared/services/session_service.dart';

import 'local_private_store_test.dart' show MemorySecrets;

class _FictionalPkceProvider {
  _FictionalPkceProvider(this.server);
  final HttpServer server;
  final challenges = <String>[];
  final failures = <String>[];
  int requests = 0, exchanges = 0, logouts = 0;

  String get origin => 'http://127.0.0.1:${server.port}';

  Map<String, Object?> _session(String token) => {
    'access_token': token,
    'refresh_token': 'fictional-refresh',
    'expires_in': 3600,
    'token_type': 'bearer',
    'user': {
      'id': 'fictional-owner',
      'aud': 'authenticated',
      'email': 'fictional@example.invalid',
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
      'created_at': '2026-01-01T00:00:00Z',
    },
  };

  void start() {
    server.listen((request) async {
      try {
        if (++requests > 8 || request.method != 'POST') {
          throw const FormatException('Unexpected fixture request.');
        }
        final bytes = <int>[];
        await for (final chunk in request) {
          if (bytes.length + chunk.length > 8192) {
            throw const FormatException('Fixture request too large.');
          }
          bytes.addAll(chunk);
        }
        final body = bytes.isEmpty
            ? <String, Object?>{}
            : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        Object response;
        switch (request.uri.path) {
          case '/auth/v1/token':
            switch (request.uri.queryParameters['grant_type']) {
              case 'password':
                response = _session('fictional-original-token');
              case 'pkce':
                exchanges++;
                final verifier = body['code_verifier'] as String;
                final challenge = base64Url
                    .encode(sha256.convert(ascii.encode(verifier)).bytes)
                    .replaceAll('=', '');
                if (body['auth_code'] != 'fictional-fresh-code' ||
                    challenges.length != 2 ||
                    challenge != challenges.last) {
                  throw const FormatException('Unexpected PKCE exchange.');
                }
                response = _session('fictional-recovered-token');
              default:
                throw const FormatException('Unexpected token grant.');
            }
          case '/auth/v1/recover':
            if (body['code_challenge_method'] != 's256' ||
                body['code_challenge'] is! String ||
                request.uri.queryParameters['redirect_to'] !=
                    'safeathome://auth/callback') {
              throw const FormatException('Invalid fixture recovery flow.');
            }
            challenges.add(body['code_challenge'] as String);
            response = <String, Object?>{};
          case '/auth/v1/logout':
            if (request.uri.queryParameters['scope'] != 'local') {
              throw const FormatException('Unexpected logout scope.');
            }
            logouts++;
            response = <String, Object?>{};
          default:
            throw const FormatException('Unexpected fixture route.');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
      } catch (_) {
        failures.add('Fictional provider rejected an unexpected request.');
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"msg":"Fictional provider rejected request"}');
      } finally {
        await request.response.close();
      }
    });
  }
}

Future<void> _deliverAuthEvents() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'explicit logout invalidates a queued old PKCE link; a fresh flow works',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final provider = _FictionalPkceProvider(server)..start();
      final secrets = MemorySecrets();
      final pkce = SecurePkceStorage(secrets, 'fictional-pkce-invalidation');
      final client = SupabaseClient(
        provider.origin,
        'fictional-publishable-key',
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          authFlowType: AuthFlowType.pkce,
          pkceAsyncStorage: pkce,
        ),
      );
      final session = SupabaseSessionService(
        client,
        callback: Uri.parse('safeathome://auth/callback'),
        emailDeliveryEnabled: true,
        reauthenticationClient: () =>
            throw StateError('This test must not request reauthentication.'),
      );
      final cleanupEntered = Completer<void>();
      final cleanupRelease = Completer<void>();
      addTearDown(() async {
        if (!cleanupRelease.isCompleted) cleanupRelease.complete();
        await session.waitForAccountCleanup();
        session.dispose();
        await client.dispose();
        await server.close(force: true);
      });

      await session.signIn('fictional@example.invalid', 'fictional-password');
      await _deliverAuthEvents();
      expect(session.userId, 'fictional-owner');
      await session.requestRecovery('fictional@example.invalid');
      expect(provider.challenges, hasLength(1));
      expect(secrets.values.keys.any((key) => key.contains('.pkce.')), true);

      final logout = session.signOutAndClear(() async {
        await pkce.clear();
        cleanupEntered.complete();
        await cleanupRelease.future;
      });
      await cleanupEntered.future;
      expect(client.auth.currentSession, isNull);
      expect(secrets.values, isEmpty);
      final oldLink = session.handleCallback(
        Uri.parse('safeathome://auth/callback?code=fictional-old-code'),
      );
      await _deliverAuthEvents();
      expect(session.cleaningUp, true);
      expect(provider.exchanges, 0);
      cleanupRelease.complete();
      await logout;
      await oldLink;
      await _deliverAuthEvents();

      expect(provider.exchanges, 0);
      expect(session.userId, isNull);
      expect(client.auth.currentSession, isNull);
      expect(await session.accessToken(), isNull);
      expect(session.recoveryRequired, false);
      expect(session.callbackNotice, contains('fresh recovery link'));
      expect(session.callbackNotice, isNot(contains('fictional-old-code')));
      expect(session.callbackNotice, isNot(contains('verifier')));

      await session.requestRecovery('fictional@example.invalid');
      expect(provider.challenges, hasLength(2));
      expect(provider.challenges.last, isNot(provider.challenges.first));
      await session.handleCallback(
        Uri.parse('safeathome://auth/callback?code=fictional-fresh-code'),
      );
      await _deliverAuthEvents();
      expect(provider.exchanges, 1);
      expect(provider.logouts, 1);
      expect(provider.requests, 5);
      expect(provider.failures, isEmpty);
      expect(session.userId, 'fictional-owner');
      expect(session.recoveryRequired, true);
      expect(session.callbackNotice, isNull);
      expect(await session.accessToken(), 'fictional-recovered-token');
      expect(secrets.values, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
