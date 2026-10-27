import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import 'package:safe_at_home/shared/services/token_availability.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'real GoTrue terminal refresh removes the retained owner and epoch',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final failures = <String>[];
      server.listen((request) async {
        try {
          if (++requests > 2 ||
              request.method != 'POST' ||
              request.uri.path != '/auth/v1/token') {
            throw const FormatException();
          }
          var length = 0;
          await for (final part in request) {
            length += part.length;
            if (length > 4096) throw const FormatException();
          }
          request.response.headers.contentType = ContentType.json;
          if (requests == 1 &&
              request.uri.queryParameters['grant_type'] == 'password') {
            request.response.write(
              jsonEncode({
                'access_token': 'fictional-original-token',
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
              }),
            );
          } else if (requests == 2 &&
              request.uri.queryParameters['grant_type'] == 'refresh_token') {
            request.response.statusCode = 400;
            request.response.write(
              '{"code":"refresh_token_not_found","msg":"Fictional refresh token is no longer valid"}',
            );
          } else {
            throw const FormatException();
          }
        } catch (_) {
          failures.add('Unexpected fictional provider request.');
          request.response.statusCode = 400;
        } finally {
          await request.response.close();
        }
      });
      final client = SupabaseClient(
        'http://127.0.0.1:${server.port}',
        'fictional-publishable-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final session = SupabaseSessionService(
        client,
        callback: Uri.parse('safeathome://auth/callback'),
        emailDeliveryEnabled: false,
        reauthenticationClient: () => throw StateError('Unused verifier.'),
      );
      addTearDown(() async {
        session.dispose();
        await client.dispose();
        await server.close(force: true);
      });
      await session.signIn('fictional@example.invalid', 'fictional-password');
      await Future<void>.delayed(Duration.zero);
      expect(session.userId, 'fictional-owner');
      final epoch = session.epoch;
      client.auth.currentSession!.expiresAt =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
      await expectLater(
        session.accessToken(),
        throwsA(
          allOf(
            isA<AuthApiException>(),
            isNot(isA<RetryableTokenUnavailableException>()),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.auth.currentSession, isNull);
      expect(session.userId, isNull);
      expect(session.epoch, greaterThan(epoch));
      expect(await session.accessToken(), isNull);
      expect(requests, 2);
      expect(failures, isEmpty);
    },
  );
}
