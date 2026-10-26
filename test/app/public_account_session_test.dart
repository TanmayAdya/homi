import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:safe_at_home/shared/services/session_service.dart';

import 'local_private_store_test.dart' show MemorySecrets;

class _Provider {
  _Provider(this.server);
  final HttpServer server;
  final routes = <String>[];
  final failures = <String>[];
  final codes = <String, String>{};
  bool autoConfirm = false, failEmail = false;
  Completer<void>? emailRelease;
  final emailEntered = Completer<void>();
  int emails = 0, updates = 0, exchanges = 0;
  String get origin => 'http://127.0.0.1:${server.port}';
  Map<String, Object?> get user => {
    'id': 'fictional-public-owner',
    'email': 'fictional@example.invalid',
    'aud': 'authenticated',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'created_at': '2026-10-25T00:00:00Z',
  };
  Map<String, Object?> get session => {
    'access_token': 'fictional-public-token',
    'refresh_token': 'fictional-refresh-token',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': user,
  };

  void start() => server.listen((request) async {
    try {
      routes.add(request.uri.path);
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      Object result;
      switch (request.uri.path) {
        case '/auth/v1/signup':
        case '/auth/v1/resend':
        case '/auth/v1/recover':
          expect(request.method, 'POST');
          expect(body['email'], 'fictional@example.invalid');
          expect(body['code_challenge_method'], 's256');
          expect(
            request.uri.queryParameters['redirect_to'],
            'safeathome://auth/callback',
          );
          if (request.uri.path.endsWith('resend')) {
            expect(body['type'], 'signup');
          }
          codes['fictional-code-${++emails}'] =
              body['code_challenge'] as String;
          if (!emailEntered.isCompleted) emailEntered.complete();
          await emailRelease?.future;
          if (failEmail) {
            request.response.statusCode = 503;
            result = {'msg': 'private-provider-error'};
          } else {
            result = request.uri.path.endsWith('signup')
                ? autoConfirm
                      ? session
                      : user
                : <String, Object?>{};
          }
        case '/auth/v1/token':
          exchanges++;
          expect(request.uri.queryParameters['grant_type'], 'pkce');
          final verifier = body['code_verifier'] as String;
          final challenge = base64Url
              .encode(sha256.convert(ascii.encode(verifier)).bytes)
              .replaceAll('=', '');
          if (codes[body['auth_code']] != challenge) {
            request.response.statusCode = 400;
            result = {'msg': 'Expired fictional link'};
          } else {
            codes.remove(body['auth_code']);
            result = session;
          }
        case '/auth/v1/user':
          expect(request.method, 'PUT');
          expect(body['password'], 'fictional-new-password-42');
          updates++;
          result = user;
        case '/auth/v1/logout':
          result = <String, Object?>{};
        default:
          throw StateError('Unexpected fictional provider route.');
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
    } catch (_) {
      failures.add('Unexpected fictional provider request.');
      request.response.statusCode = 400;
      request.response.write('{"msg":"Fixture failure"}');
    } finally {
      await request.response.close();
    }
  });
}

Future<void> _events() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Provider provider;
  late SupabaseClient client;
  late SupabaseSessionService service;
  late SecurePkceStorage pkce;
  late MemorySecrets secrets;

  Future<void> open({
    bool signup = true,
    bool email = true,
    Duration cooldown = Duration.zero,
  }) async {
    secrets = MemorySecrets();
    pkce = SecurePkceStorage(secrets, 'fictional-public-signup');
    provider = _Provider(await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
      ..start();
    client = SupabaseClient(
      provider.origin,
      'fictional-publishable',
      authOptions: AuthClientOptions(
        autoRefreshToken: false,
        authFlowType: AuthFlowType.pkce,
        pkceAsyncStorage: pkce,
      ),
    );
    service = SupabaseSessionService(
      client,
      callback: Uri.parse('safeathome://auth/callback'),
      emailDeliveryEnabled: email,
      publicSignupEnabled: signup,
      emailRequestCooldown: cooldown,
      registrationClient: () => GoTrueClient(
        url: '${provider.origin}/auth/v1',
        headers: {'apikey': 'fictional-publishable'},
        autoRefreshToken: false,
        flowType: AuthFlowType.pkce,
        asyncStorage: pkce,
      ),
      reauthenticationClient: () => throw StateError('Not used'),
    );
    addTearDown(() async {
      if (provider.emailRelease case final release? when !release.isCompleted) {
        release.complete();
      }
      service.dispose();
      await client.dispose();
      await provider.server.close(force: true);
      expect(provider.failures, isEmpty);
    });
  }

  test(
    'signup remains signed out until real SDK exchanges matching PKCE code',
    () async {
      await open();
      await service.createAccount(
        ' fictional@example.invalid ',
        'fictional-password-42',
      );
      await _events();
      expect(service.userId, isNull);
      expect(client.auth.currentSession, isNull);
      expect(await service.accessToken(), isNull);
      expect(secrets.values.keys.any((key) => key.contains('.pkce.')), true);
      await service.handleCallback(
        Uri.parse('safeathome://auth/callback?code=fictional-code-1'),
      );
      await _events();
      expect(service.userId, 'fictional-public-owner');
      expect(service.recoveryRequired, false);
      expect(secrets.values, isEmpty);
      expect(provider.exchanges, 1);
    },
  );

  test(
    'resend replaces verifier, rejects old link and accepts newest confirmation',
    () async {
      await open();
      await service.createAccount(
        'fictional@example.invalid',
        'fictional-password-42',
      );
      await service.resendConfirmation('fictional@example.invalid');
      await service.handleCallback(
        Uri.parse('safeathome://auth/callback?code=fictional-code-1'),
      );
      expect(service.userId, isNull);
      expect(service.callbackNotice, isNotNull);
      await service.handleCallback(
        Uri.parse('safeathome://auth/callback?code=fictional-code-2'),
      );
      await _events();
      expect(service.userId, 'fictional-public-owner');
      expect(service.callbackNotice, isNull);
    },
  );

  test(
    'recovery opens password entry and only valid update completes it',
    () async {
      await open();
      await service.requestRecovery('fictional@example.invalid');
      await service.handleCallback(
        Uri.parse('safeathome://auth/callback?code=fictional-code-1'),
      );
      await _events();
      expect(service.recoveryRequired, true);
      await expectLater(service.updatePassword('short'), throwsStateError);
      expect(provider.updates, 0);
      await service.updatePassword('fictional-new-password-42');
      expect(provider.updates, 1);
      expect(service.recoveryRequired, false);
    },
  );

  test(
    'unexpected autoconfirm session never reaches persistent app client',
    () async {
      await open();
      provider.autoConfirm = true;
      await expectLater(
        service.createAccount(
          'fictional@example.invalid',
          'fictional-password-42',
        ),
        throwsStateError,
      );
      await _events();
      expect(service.userId, isNull);
      expect(client.auth.currentSession, isNull);
      expect(await service.accessToken(), isNull);
    },
  );

  test(
    'disabled signup/email and malformed input never reach provider',
    () async {
      await open(signup: false, email: false);
      await expectLater(
        service.createAccount(
          'fictional@example.invalid',
          'fictional-password-42',
        ),
        throwsStateError,
      );
      await expectLater(
        service.resendConfirmation('fictional@example.invalid'),
        throwsStateError,
      );
      await expectLater(
        service.requestRecovery('fictional@example.invalid'),
        throwsStateError,
      );
      expect(provider.routes, isEmpty);
    },
  );

  test(
    'validation rejects bad email and short signup password before network',
    () async {
      await open();
      await expectLater(
        service.createAccount('invalid', 'fictional-password-42'),
        throwsFormatException,
      );
      await expectLater(
        service.createAccount('fictional@example.invalid', 'short'),
        throwsFormatException,
      );
      await expectLater(
        service.resendConfirmation('invalid'),
        throwsFormatException,
      );
      expect(provider.routes, isEmpty);
    },
  );

  test('signup, resend and recovery share one email cooldown', () async {
    await open(cooldown: const Duration(seconds: 60));
    await service.createAccount(
      'fictional@example.invalid',
      'fictional-password-42',
    );
    await expectLater(
      service.resendConfirmation('fictional@example.invalid'),
      throwsA(isA<AuthEmailCooldownException>()),
    );
    await expectLater(
      service.requestRecovery('fictional@example.invalid'),
      throwsA(isA<AuthEmailCooldownException>()),
    );
    expect(provider.emails, 1);
  });

  test('uncertain failed email request is paced before retry', () async {
    await open(cooldown: const Duration(seconds: 60));
    provider.failEmail = true;
    await expectLater(
      service.createAccount(
        'fictional@example.invalid',
        'fictional-password-42',
      ),
      throwsA(isA<AuthException>()),
    );
    await expectLater(
      service.resendConfirmation('fictional@example.invalid'),
      throwsA(isA<AuthEmailCooldownException>()),
    );
    expect(provider.emails, 1);
    expect(service.userId, isNull);
  });

  test(
    'cleanup waits for in-flight signup and invalidates its old callback',
    () async {
      await open();
      provider.emailRelease = Completer<void>();
      final signup = service.createAccount(
        'fictional@example.invalid',
        'fictional-password-42',
      );
      await provider.emailEntered.future;
      var cleared = false;
      final logout = service.signOutAndClear(() async {
        await pkce.clear();
        cleared = true;
      });
      expect(service.cleaningUp, true);
      expect(cleared, false);
      provider.emailRelease!.complete();
      await signup;
      await logout;
      await service.handleCallback(
        Uri.parse('safeathome://auth/callback?code=fictional-code-1'),
      );
      await _events();
      expect(cleared, true);
      expect(provider.exchanges, 0);
      expect(service.userId, isNull);
      expect(secrets.values, isEmpty);
    },
  );
}
